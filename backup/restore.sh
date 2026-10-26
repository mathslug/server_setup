#!/usr/bin/env bash
#
# restore.sh — put backed-up state from the backup disk back into place.
#
#     sudo /opt/rpi/backup/restore.sh              # every app, and the tunnel
#     sudo /opt/rpi/backup/restore.sh <app>        # one app
#     sudo /opt/rpi/backup/restore.sh host         # just the tunnel
#
#     sudo BACKUP_SRC=/srv/backup/pi/daily/2026-08-07_235709 /opt/rpi/backup/restore.sh <app>
#
# Run on the Pi. Defaults to /srv/backup/pi/latest, which moves with every
# successful run — pass BACKUP_SRC to roll one app back to a dated copy while
# the rest stay current.
#
# The inverse of snapshot.sh, reading the same apps/*.conf. It restores onto a
# Pi that already has the apps deployed — run deploy-app.sh first, or there is
# no unit to stop and no data directory to write into.
#
# Constraints to preserve:
#
#   * Remove the -wal and -shm alongside the database. A freshly deployed app
#     has created an empty database and a write-ahead log; leaving that log in
#     place means SQLite replays it over the file just restored.
#   * The env file goes back at 0600 owned by the service account. It holds
#     the real secrets and exists nowhere else but here and the backup disk.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
SRC="${BACKUP_SRC:-/srv/backup/pi/latest}"

# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/appconf.sh"

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "FAILED: $*"; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -d "$SRC" ] || die "no backup at ${SRC} — is the backup disk attached and mounted?"
log "restoring from $(readlink -f "$SRC")"

# The service account cannot enter the login user's home, which is where an
# ssh session starts.
cd /tmp
SVC_UID=$(id -u "$SERVICE_USER") || die "no ${SERVICE_USER} account"
AS_SVC=(runuser -u "$SERVICE_USER" -- env HOME="$(_svc_home)"
        XDG_RUNTIME_DIR="/run/user/${SVC_UID}"
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus")

restore_host() {
  log "--- host ---"
  [ -d "${SRC}/host/cloudflared" ] || die "no host/cloudflared in the backup"
  "${REPO_ROOT}/cloudflared/install.sh" "${SRC}/host/cloudflared"
}

restore_app() {
  local app="$1"
  appconf_load "$app"
  [ -d "${SRC}/${app}" ] || { log "${app}: nothing in the backup, skipping"; return 0; }
  log "--- ${app} ---"

  "${AS_SVC[@]}" systemctl --user stop "${SERVICE}.service" || true

  if [ -n "${BACKUP_DB:-}" ] && [ -f "${SRC}/${app}/${BACKUP_DB}.gz" ]; then
    rm -f "${DATA_DIR}/${BACKUP_DB}" "${DATA_DIR}/${BACKUP_DB}-wal" "${DATA_DIR}/${BACKUP_DB}-shm"
    gunzip -c "${SRC}/${app}/${BACKUP_DB}.gz" > "${DATA_DIR}/${BACKUP_DB}"
    log "${app}: database restored"
  fi

  for d in ${BACKUP_DIRS:-}; do
    [ -d "${SRC}/${app}/${d}" ] || continue
    rsync -a "${SRC}/${app}/${d}/" "${DATA_DIR}/${d}/"
    log "${app}: ${d}/ restored ($(find "${SRC}/${app}/${d}" -type f | wc -l) files)"
  done

  if [ -f "${SRC}/${app}/env" ]; then
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0600 "${SRC}/${app}/env" "$ENV_FILE"
    log "${app}: env restored"
  fi

  chown -R "${SERVICE_USER}:${SERVICE_USER}" "$DATA_DIR"
  "${AS_SVC[@]}" systemctl --user start "${SERVICE}.service"
  log "${app}: $("${AS_SVC[@]}" systemctl --user is-active "${SERVICE}.service")"
}

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=("host")
  while read -r a; do TARGETS+=("$a"); done < <(appconf_list)
fi

for t in "${TARGETS[@]}"; do
  case "$t" in
    host) restore_host ;;
    *)    restore_app "$t" ;;
  esac
done

log "=== done ==="
