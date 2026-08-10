#!/usr/bin/env bash
#
# restore.sh — push backed-up state from this Mac back onto the Pi.
#
#     ./backup/restore.sh              # every app, and the tunnel
#     ./backup/restore.sh <app>        # one app
#     ./backup/restore.sh host         # just the tunnel
#
#     BACKUP_SRC=backups/daily/2026-08-07_235709 ./backup/restore.sh <app>
#
# Defaults to backups/latest, which moves with every successful run — pass
# BACKUP_SRC to roll one app back to a dated copy while the rest stay current.
#
# The inverse of pull-backups.sh, reading the same apps/*.conf. It restores onto
# a Pi that already has the apps deployed — run deploy-app.sh first, or there is
# no unit to stop and no data directory to write into.
#
# Constraints to preserve:
#
#   * Remove the -wal and -shm alongside the database. A freshly deployed app
#     has created an empty database and a write-ahead log; leaving that log in
#     place means SQLite replays it over the file just restored.
#   * The env file goes back at 0600 owned by the service account. It holds
#     the real secrets and exists nowhere else but here and the Pi.

set -euo pipefail

PI="${PI_HOST:-}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${BACKUP_SRC:-${REPO_ROOT}/backups/latest}"

# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/appconf.sh"

log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "FAILED: $*"; exit 1; }

[ -d "$SRC" ] || die "no backup at ${SRC}"

if [ -z "$PI" ]; then
  for c in mypi mypi-remote; do
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$c" true 2>/dev/null && { PI="$c"; break; }
  done
  [ -n "$PI" ] || die "cannot reach the Pi on the LAN (mypi) or the tunnel (mypi-remote)"
fi
log "restoring to '${PI}' from ${SRC}"

# Everything the service account owns has to be written as root and handed
# over, because the login user cannot write into its home.
AS_SVC='sudo -u podsvc env HOME=/home/podsvc XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus'

restore_host() {
  log "--- host ---"
  [ -d "${SRC}/host/cloudflared" ] || die "no host/cloudflared in the backup"
  ssh "$PI" 'rm -rf /tmp/cfrestore && mkdir -p /tmp/cfrestore'
  scp -q "${SRC}"/host/cloudflared/* "${PI}:/tmp/cfrestore/"
  ssh "$PI" "sudo /opt/rpi/cloudflared/install.sh /tmp/cfrestore && rm -rf /tmp/cfrestore"
}

restore_app() {
  local app="$1"
  appconf_load "$app"
  [ -d "${SRC}/${app}" ] || { log "${app}: nothing in the backup, skipping"; return 0; }
  log "--- ${app} ---"

  ssh "$PI" "cd /tmp && ${AS_SVC} systemctl --user stop ${SERVICE}.service" || true

  if [ -n "${BACKUP_DB:-}" ] && [ -f "${SRC}/${app}/${BACKUP_DB}.gz" ]; then
    scp -q "${SRC}/${app}/${BACKUP_DB}.gz" "${PI}:/tmp/${app}.db.gz"
    ssh "$PI" "sudo sh -c '
      rm -f ${DATA_DIR}/${BACKUP_DB} ${DATA_DIR}/${BACKUP_DB}-wal ${DATA_DIR}/${BACKUP_DB}-shm
      gunzip -c /tmp/${app}.db.gz > ${DATA_DIR}/${BACKUP_DB}
      rm -f /tmp/${app}.db.gz'"
    log "${app}: database restored"
  fi

  for d in ${BACKUP_DIRS:-}; do
    [ -d "${SRC}/${app}/${d}" ] || continue
    rsync -a --rsync-path="sudo rsync" "${SRC}/${app}/${d}/" "${PI}:${DATA_DIR}/${d}/"
    log "${app}: ${d}/ restored ($(find "${SRC}/${app}/${d}" -type f | wc -l | tr -d ' ') files)"
  done

  if [ -f "${SRC}/${app}/env" ]; then
    scp -q "${SRC}/${app}/env" "${PI}:/tmp/${app}.env"
    ssh "$PI" "sudo install -o podsvc -g podsvc -m 0600 /tmp/${app}.env ${ENV_FILE} \
      && rm -f /tmp/${app}.env"
    log "${app}: env restored"
  fi

  ssh "$PI" "sudo chown -R podsvc:podsvc ${DATA_DIR}"
  ssh "$PI" "cd /tmp && ${AS_SVC} systemctl --user start ${SERVICE}.service"
  log "${app}: $(ssh "$PI" "cd /tmp && ${AS_SVC} systemctl --user is-active ${SERVICE}.service")"
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
