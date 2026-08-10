#!/usr/bin/env bash
#
# bootstrap.sh — take a freshly imaged Pi to a fully serving one.
#
#     ./bootstrap.sh mypi
#     ./bootstrap.sh mypi --swap-mb 8192
#
# Run on the Mac, after provision-disk.sh. Idempotent: re-running against a
# working system changes nothing and still reports green, which is what makes
# it safe to re-run after a failure part-way through.
#
# It wraps the tools rather than reimplementing them — remote/setup.sh,
# deploy-app.sh, backup/restore.sh, systemd/install-units.sh — and owns the
# ordering between them, which is the part that used to live in someone's head:
#
#   * the memory cgroup needs a reboot before podman limits mean anything
#   * the tunnel comes back before the apps, so their health checks are
#     answerable from outside
#   * an app is deployed and THEN restored. deploy-app.sh health-checks against
#     a database that does not exist yet, so its check is advisory until the
#     restore has run; the check that counts is at the end of this script.

set -euo pipefail

HOST="${1:?usage: $0 <host> [--swap-mb N]}"; shift
SWAP_ARGS=()
VERIFY=1
FORCE_RESTORE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --swap-mb)       SWAP_ARGS=(--swap-mb "${2:?--swap-mb needs a value}"); shift 2 ;;
    --no-verify)     VERIFY=0; shift ;;
    --force-restore) FORCE_RESTORE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   %s\n' "$*"; }
warn() { printf '   WARNING: %s\n' "$*" >&2; }
die()  { printf '\nbootstrap: %s\n' "$*" >&2; exit 1; }

wait_for_host() {
  local deadline=$(( $(date +%s) + BOOT_TIMEOUT ))
  until ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; do
    [ "$(date +%s)" -lt "$deadline" ] || die "${HOST} did not come back within ${BOOT_TIMEOUT}s"
    sleep 10
  done
}

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || die "cannot reach ${HOST} over ssh"

# --- Base system ------------------------------------------------------------
say "Base system"
ssh "$HOST" "bash -s -- ${SWAP_ARGS[*]}" < "${HERE}/remote/setup.sh"

# Asked of the kernel rather than parsed out of the log above: the controller
# either shows up in the running kernel or it does not.
if ! ssh "$HOST" 'grep -q memory /sys/fs/cgroup/cgroup.controllers'; then
  say "Rebooting for the memory cgroup"
  ssh "$HOST" 'sudo systemctl reboot' 2>/dev/null || true
  sleep 20
  wait_for_host
  ssh "$HOST" 'grep -q memory /sys/fs/cgroup/cgroup.controllers' \
    || die "the memory cgroup is still not active after a reboot; container limits would be silently ignored"
  ok "active"
fi

# --- Tunnel -----------------------------------------------------------------
# Before the apps: their health checks are reachable from outside only once
# this is up, and a broken tunnel is much easier to see now than later.
say "Tunnel"
"${HERE}/backup/restore.sh" host
ssh "$HOST" 'systemctl is-active --quiet cloudflared' \
  || die "cloudflared did not come up; the apps would be unreachable"
ok "cloudflared active"

# --- Apps -------------------------------------------------------------------
# A private repo needs a deploy key, and podsvc's key is new on a rebuilt disk,
# so the old one on GitHub is dead. deploy-app.sh generates the replacement and
# exits; rotate it here and retry once. Public repos never take this path.
rotate_deploy_key() {
  local app="$1" owner_repo pub
  command -v gh >/dev/null 2>&1 || { warn "gh not installed; add ${DEPLOY_KEY}.pub by hand"; return 1; }
  owner_repo=$(printf '%s' "$REPO" | sed 's#.*[:/]\([^/]*/[^/]*\)\.git#\1#')
  pub=$(mktemp); trap 'rm -f "$pub"' RETURN
  ssh "$HOST" "sudo cat ${DEPLOY_KEY}.pub" > "$pub" 2>/dev/null
  [ -s "$pub" ] || { warn "${app}: no public key at ${DEPLOY_KEY}.pub"; return 1; }
  for id in $(gh repo deploy-key list --repo "$owner_repo" --json id -q '.[].id' 2>/dev/null); do
    gh repo deploy-key delete "$id" --repo "$owner_repo" >/dev/null 2>&1 \
      && ok "${app}: removed stale key ${id}"
  done
  gh repo deploy-key add "$pub" --repo "$owner_repo" --title "podsvc@${HOST}" >/dev/null \
    || { warn "${app}: could not add the deploy key to ${owner_repo}"; return 1; }
  ok "${app}: deploy key registered on ${owner_repo}"
}

APPS=()
while read -r a; do APPS+=("$a"); done < <(appconf_list)
[ ${#APPS[@]} -gt 0 ] || die "no apps configured in $(appconf_dir)"

for APP in "${APPS[@]}"; do
  say "App: ${APP}"
  appconf_load "$APP"
  if ! ssh "$HOST" "sudo /opt/rpi/deploy-app.sh ${APP}" 2>&1 | tail -20; then
    case "$REPO" in
      git@*|ssh://*)
        rotate_deploy_key "$APP" || die "${APP}: deploy failed and the key could not be rotated"
        ssh "$HOST" "sudo /opt/rpi/deploy-app.sh ${APP}" 2>&1 | tail -20 \
          || warn "${APP}: deploy still reported a problem; the restore below may fix its health check"
        ;;
      *) warn "${APP}: deploy reported a problem; continuing to the restore" ;;
    esac
  fi
  # Restore only onto an empty app. This script has to be safe to re-run
  # against a healthy machine, and an unconditional restore would silently roll
  # the database back to the last backup — turning a routine re-run into data
  # loss. --force-restore is the deliberate way to overwrite live data.
  if [ "$FORCE_RESTORE" = "1" ]; then
    "${HERE}/backup/restore.sh" "$APP"
  elif [ -n "${BACKUP_DB:-}" ] \
    && ssh "$HOST" "sudo test -s ${DATA_DIR}/${BACKUP_DB}" 2>/dev/null; then
    ok "${APP}: data already present, not restoring (--force-restore to overwrite)"
  else
    "${HERE}/backup/restore.sh" "$APP"
  fi
done

# --- Units and timers -------------------------------------------------------
say "Units and timers"
ssh "$HOST" 'sudo /opt/rpi/systemd/install-units.sh' | sed 's/^/   /'
ssh "$HOST" "sudo systemctl enable --now rpi-selfupdate.timer rpi-health.timer" >/dev/null 2>&1
# Once, now: the timer is every 5 minutes, and until it fires the dashboard
# serves an empty directory.
ssh "$HOST" 'sudo systemctl start rpi-health.service' >/dev/null 2>&1 || true
for APP in "${APPS[@]}"; do
  ssh "$HOST" "sudo systemctl enable --now autodeploy@${APP}.timer" >/dev/null 2>&1 \
    && ok "autodeploy@${APP}.timer"
done
ok "rpi-selfupdate.timer, rpi-health.timer"

# --- Verify -----------------------------------------------------------------
say "Verify"
FAILED=0
for APP in "${APPS[@]}"; do
  appconf_load "$APP"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 60 "$PUBLIC_URL" || echo 000)
  case "$CODE" in
    200|302) ok "${APP}: ${CODE} ${PUBLIC_URL}" ;;
    *) warn "${APP}: ${CODE} ${PUBLIC_URL}"; FAILED=1 ;;
  esac
done

UNITS=$(ssh "$HOST" 'systemctl --failed --no-legend --plain | wc -l' | tr -d ' ')
[ "$UNITS" = "0" ] || { warn "${UNITS} failed system unit(s)"; FAILED=1; }
ssh "$HOST" 'echo "   root: $(findmnt -no SOURCE /) $(df -h / | awk "NR==2{print \$2}")"
             echo "   swap: $(free -h | awk "/^Swap:/{print \$2}")"
             echo "   logs: $(journalctl --list-boots 2>/dev/null | wc -l) boot(s) recorded"'

if [ "$VERIFY" = "1" ]; then
  say "Row counts"
  # The proof that the data came back, using the tool that already knows how to
  # check it. Advisory: a rebuild that serves correctly should not be reported
  # as failed because the Mac could not reach the Pi for a backup.
  "${HERE}/backup/pull-backups.sh" 2>&1 | grep -E ': ok —|INCOMPLETE|FAILED' | sed 's/^/   /' \
    || warn "the verification backup did not complete; run ./backup/pull-backups.sh by hand"
fi

[ "$FAILED" = "0" ] || die "finished with problems above"
say "${HOST} is serving"
