#!/usr/bin/env bash
#
# deploy-app.sh — clone or update an app, build its image, and start it under
# rootless podman + systemd.
#
#     /opt/rpi/deploy-app.sh whorl
#
# Idempotent. First run clones and starts; later runs pull, rebuild, restart.
# Application state under ~/data/<app> is never touched, so a redeploy cannot
# destroy anything that isn't in git.

set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: $0 <app>"; exit 2; }

# Run from somewhere every account can read. `sudo -u podsvc` inherits the
# caller's working directory, and podman refuses to start if it cannot chdir
# into it — which it can't, if you invoked this from the admin user's home.
cd /tmp

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"
appconf_load "$APP"

SVC_UID=$(id -u "$SERVICE_USER")

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

# XDG_RUNTIME_DIR is what makes `systemctl --user` and podman find the right
# socket; without it both fail in confusing ways.
asuser() {
  sudo -u "$SERVICE_USER" env \
    HOME="$SVC_HOME" \
    XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
    GIT_SSH_COMMAND="$GIT_SSH_COMMAND" \
    "$@"
}

# ---------------------------------------------------------------------------
say "Deploy key"
# ---------------------------------------------------------------------------
# One key per app: GitHub will not register the same public key as a deploy key
# on two repositories. Only for SSH remotes — an https:// URL in the conf means
# the repo is public and needs no credential.
case "$REPO" in
  git@*|ssh://*)
    if sudo test -f "$DEPLOY_KEY"; then
      ok "$(basename "$DEPLOY_KEY")"
    else
      asuser mkdir -p "${SVC_HOME}/.ssh"
      asuser chmod 700 "${SVC_HOME}/.ssh"
      asuser ssh-keygen -t ed25519 -N "" -f "$DEPLOY_KEY" -C "${APP}@$(hostname)" >/dev/null
      ok "generated $(basename "$DEPLOY_KEY")"
    fi
    ;;
  *)
    ok "public repo over https — no deploy key needed"
    ;;
esac

# Check access before doing anything expensive, so a missing deploy key fails
# in two seconds with the fix printed, rather than part-way through a build.
if ! asuser git ls-remote --exit-code "$REPO" HEAD >/dev/null 2>&1; then
  OWNER_REPO=$(printf '%s' "$REPO" | sed 's#.*[:/]\([^/]*/[^/]*\)\.git#\1#')
  echo
  echo "   Cannot read ${REPO}."
  case "$REPO" in
    git@*|ssh://*)
      echo "   Add this as a read-only deploy key:"
      echo "     https://github.com/${OWNER_REPO}/settings/keys/new"
      echo
      sudo cat "${DEPLOY_KEY}.pub" | sed 's/^/     /'
      ;;
    *)
      echo "   The repo is configured as public. If it is private, change REPO"
      echo "   in apps/${APP}.conf to the git@github.com: form and re-run."
      ;;
  esac
  echo
  exit 1
fi

# ---------------------------------------------------------------------------
say "Source: ${REPO}"
# ---------------------------------------------------------------------------
if sudo test -d "${CHECKOUT}/.git"; then
  # The conf is the source of truth for where the code comes from. An existing
  # checkout keeps whatever remote it was cloned with, so switching a repo
  # between ssh and https would otherwise take effect only on a rebuild.
  asuser git -C "$CHECKOUT" remote set-url origin "$REPO"
  asuser git -C "$CHECKOUT" fetch --quiet origin "$BRANCH"
  asuser git -C "$CHECKOUT" reset --quiet --hard "origin/${BRANCH}"
  ok "updated to $(asuser git -C "$CHECKOUT" rev-parse --short HEAD)"
else
  asuser git clone --quiet --branch "$BRANCH" "$REPO" "$CHECKOUT"
  ok "cloned at $(asuser git -C "$CHECKOUT" rev-parse --short HEAD)"
fi

# ---------------------------------------------------------------------------
say "State and configuration"
# ---------------------------------------------------------------------------
asuser mkdir -p "$DATA_DIR"
ok "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1)) — untouched by deploys"

if sudo test -f "$ENV_FILE"; then
  ok "env: ${ENV_FILE} (existing, left alone)"
else
  printf '%s\n' "$ENV_TEMPLATE" | asuser tee "$ENV_FILE" >/dev/null
  asuser chmod 600 "$ENV_FILE"
  ok "env: ${ENV_FILE} CREATED FROM TEMPLATE — edit it, real secrets are not in git"
fi

# ---------------------------------------------------------------------------
say "Build ${IMAGE}:latest"
# ---------------------------------------------------------------------------
# Built natively on the target, so architecture-specific dependencies (sharp,
# better-sqlite3, esbuild) resolve for the host it will actually run on.
asuser podman build --quiet -t "${IMAGE}:latest" "$CHECKOUT" >/dev/null
ok "built $(asuser podman image inspect "${IMAGE}:latest" --format '{{.Id}}' | cut -c1-12)"

# The conf names a snapshot script; the image has to contain it. Nothing else
# connects the two, and .containerignore can silently exclude it. Checking here
# costs one container start and moves the failure to the deploy that caused it,
# rather than to that night's backup.
if [ -n "${BACKUP_SNAPSHOT_CMD:-}" ]; then
  SNAP_SCRIPT=$(printf '%s' "$BACKUP_SNAPSHOT_CMD" | awk '{print $NF}')
  asuser podman run --rm --entrypoint "" "${IMAGE}:latest" \
    test -f "$SNAP_SCRIPT" \
    || { echo "   ${SNAP_SCRIPT} is not in the image, so backups cannot snapshot"
         echo "   ${APP}'s database. Check .containerignore and the conf's"
         echo "   BACKUP_SNAPSHOT_CMD; they have to agree."
         exit 1; }
  ok "backup snapshot script present: ${SNAP_SCRIPT}"
fi

# ---------------------------------------------------------------------------
say "Install unit and start"
# ---------------------------------------------------------------------------
asuser install -m 0644 "${CHECKOUT}/${QUADLET}" \
  "${SVC_HOME}/.config/containers/systemd/$(basename "$QUADLET")"

# Optional systemd user units shipped by the app — timers and the services they
# drive. They live in the app's repo so a schedule change ships with the code
# change that motivated it.
if [ -n "${UNITS_DIR:-}" ] && sudo test -d "${CHECKOUT}/${UNITS_DIR}"; then
  asuser mkdir -p "${SVC_HOME}/.config/systemd/user"
  for unit in $(sudo sh -c "ls -1 ${CHECKOUT}/${UNITS_DIR}"); do
    asuser install -m 0644 "${CHECKOUT}/${UNITS_DIR}/${unit}" \
      "${SVC_HOME}/.config/systemd/user/${unit}"
  done
  ok "units: $(sudo sh -c "ls -1 ${CHECKOUT}/${UNITS_DIR}" | tr '\n' ' ')"
fi

asuser systemctl --user daemon-reload

# After the reload, so systemd sees the units just installed. A timer removed
# from the repo is NOT disabled here — that stays a manual step.
if [ -n "${UNITS_DIR:-}" ] && sudo test -d "${CHECKOUT}/${UNITS_DIR}"; then
  for timer in $(sudo sh -c "ls -1 ${CHECKOUT}/${UNITS_DIR}" | grep '\.timer$' || true); do
    asuser systemctl --user enable --now "$timer" >/dev/null 2>&1
    ok "timer: ${timer} — next $(asuser systemctl --user show "$timer" -p NextElapseUSecRealtime --value)"
  done
fi

asuser systemctl --user restart "${SERVICE}.service"
ok "$(asuser systemctl --user is-active "${SERVICE}.service") — ${SERVICE}.service"

# Auto-deploy. A SYSTEM timer, unlike the app's own units, because it runs this
# script as root. Enabled here so an app cannot deploy cleanly and then silently
# never pick up another commit.
if [ -f /etc/systemd/system/autodeploy@.timer ]; then
  sudo systemctl enable --now "autodeploy@${APP}.timer" >/dev/null 2>&1
  ok "autodeploy@${APP}.timer — $(systemctl is-active "autodeploy@${APP}.timer")"
else
  echo "   NOTE: autodeploy@.timer is not installed; run systemd/install-units.sh"
fi

# ---------------------------------------------------------------------------
say "Health"
# ---------------------------------------------------------------------------
# Fail loudly rather than leaving a broken deploy looking successful.
for i in $(seq 1 30); do
  if curl -sf --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "healthy after ${i}s — ${HEALTH_URL}"
    exit 0
  fi
  sleep 1
done

echo "   UNHEALTHY after 30s. Recent logs:"
asuser journalctl --user -u "${SERVICE}.service" -n 40 --no-pager | sed 's/^/     /'
exit 1
