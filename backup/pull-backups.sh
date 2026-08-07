#!/usr/bin/env bash
#
# pull-backups.sh — pull application state off the Pi onto this Mac.
#
# Run by launchd daily (see com.mathslug.pi-backup.plist), or by hand:
#     ~/src/rpi/backup/pull-backups.sh
#
# Design notes, each of which is load-bearing:
#
#   * PULL, not push. The Mac sleeps and moves; the Pi does not. A push from
#     the Pi would fail silently every time the laptop was closed.
#
#   * VACUUM INTO, never cp. Both apps run SQLite in WAL mode, so recent writes
#     live in the -wal file rather than in the database — production's whorl
#     app.db was once 4096 bytes with 1.3MB of WAL, and copying it alone yields
#     a valid, EMPTY database with no error. VACUUM INTO takes a
#     transactionally consistent snapshot of a live database and folds the WAL
#     in, so this needs no downtime and cannot tear. The snapshot script lives
#     in each app's repo, because it has to run in that app's runtime.
#
#   * Dated snapshots, not a mirror. A mirror faithfully replicates corruption
#     over the last good copy. Unchanged files hardlink to the previous run
#     via --link-dest, so history is nearly free.
#
#   * Compressed on the Pi. SQLite compresses to about 15%, and karb's database
#     is 710MB. Uncompressed this would be 710MB over wifi nightly and 15.6GB
#     of retained snapshots; compressed it is ~107MB and ~2.4GB.
#
#   * Verify every run. A backup nobody has opened is a rumour. What is
#     verified is the compressed copy that was actually kept, not the original
#     on the Pi.

set -euo pipefail

# Chosen at runtime — see the reachability check below. Set PI_HOST to force one.
PI="${PI_HOST:-}"
# Default to backups/ inside this repo, resolved relative to the script so it
# survives the repo being moved. Git-ignored; Time Machine covers it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${BACKUP_DEST:-${REPO_ROOT}/backups}"
KEEP_DAILY=14
KEEP_WEEKLY=8

STAMP=$(date +%Y-%m-%d_%H%M%S)
RUN="${DEST}/daily/${STAMP}"
LATEST="${DEST}/latest"

# Apps are discovered from apps/*.conf rather than listed here, so a new app
# is backed up the moment its config exists — no second place to remember.
# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/appconf.sh"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# A failure used to produce a line in a log file nobody opens and a non-zero
# exit code nobody queries — which is to say, nothing. This is the immediate
# half of the fix; the slow half is the "Last backup" row on the Pi's
# dashboard, which catches a backup that stops running rather than one that
# runs and fails.
#
# Best-effort by design: no notification daemon must ever be able to fail the
# backup that is trying to report through it.
notify() {
  [ -n "${BACKUP_NO_NOTIFY:-}" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$1\" with title \"Pi backup failed\" sound name \"Basso\"" \
    >/dev/null 2>&1 || true
}

# fail() aborts the whole run; it is for conditions that make every app
# hopeless, like the Pi being unreachable. A single app failing must not take
# the others down with it — that is app_fail(), which gives up on one app and
# lets the loop continue. The run still exits non-zero at the end.
fail() { log "FAILED: $*"; notify "$*"; exit 1; }
app_fail() { log "FAILED: $*"; return 1; }
FAILED_APPS=""

mkdir -p "${DEST}/daily" "${DEST}/weekly"

log "=== backup run ${STAMP} ==="

# LAN first, Cloudflare tunnel second.
#
# The LAN path is direct and works when the internet does not, so it stays the
# default. The tunnel is why "the Mac was not at home" no longer means "no
# backup today", which was the largest remaining hole in this arrangement.
#
# Bounded with `timeout`, not just ConnectTimeout: if the Access token has
# expired, `cloudflared access ssh` waits for a browser login that nobody is
# there to complete, and this runs unattended from launchd at 06:00.
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
try_host() {
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" 30 ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" true 2>/dev/null
  else
    ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" true 2>/dev/null
  fi
}

if [ -n "$PI" ]; then
  try_host "$PI" || fail "cannot reach ${PI} over ssh"
else
  for CANDIDATE in mypi mypi-remote; do
    if try_host "$CANDIDATE"; then PI="$CANDIDATE"; break; fi
  done
  [ -n "$PI" ] || fail "cannot reach the Pi on the LAN (mypi) or the tunnel (mypi-remote)"
fi
log "reaching the Pi as '${PI}'"

backup_app() {
  local APP="$1"
  appconf_load "$APP"
  mkdir -p "${RUN}/${APP}"

  # Not every app has a database. AvaLong keeps its whole state in an in-memory
  # dict, so an empty BACKUP_DB says "nothing to snapshot" explicitly rather
  # than this script assuming SQLite because the first two apps happened to use
  # it. Everything below that is not database-specific still runs.
  if [ -n "${BACKUP_DB:-}" ]; then

  # 1. Consistent snapshot of the live database, taken on the Pi inside the
  #    app's own container so it sees the same file the app has open. The
  #    command comes from the app's conf because it has to run in the app's
  #    runtime — node for whorl, python for karb — and lives as a script in the
  #    app's repo rather than inline here, because the escaping needed to pass
  #    a nested-quoted one-liner through ssh breaks silently.
  ssh -o BatchMode=yes "$PI" "cd /tmp && sudo -u podsvc env HOME=/home/podsvc \
      XDG_RUNTIME_DIR=/run/user/1001 podman exec ${APP} ${BACKUP_SNAPSHOT_CMD}" \
    >/dev/null || { app_fail "${APP}: snapshot failed"; return 1; }

  # 2. Retrieve it compressed, then remove it from the Pi so it isn't served or
  #    re-backed-up. gzip runs on the Pi and streams, so nothing extra is
  #    written to the SD card. karb's database is 710MB and compresses to 15%:
  #    that is the difference between 710MB and ~107MB over wifi every night,
  #    and between 15.6GB and 2.4GB of retained snapshots.
  ssh -o BatchMode=yes "$PI" "sudo gzip -c ${DATA_DIR}/.backup.db" \
    > "${RUN}/${APP}/${BACKUP_DB}.gz" || { app_fail "${APP}: could not retrieve snapshot"; return 1; }
  ssh -o BatchMode=yes "$PI" "sudo rm -f ${DATA_DIR}/.backup.db"
  [ -s "${RUN}/${APP}/${BACKUP_DB}.gz" ] || { app_fail "${APP}: snapshot came back empty"; return 1; }
  fi

  # 3. Any state that is not in the database. --link-dest makes unchanged files
  #    hardlinks against yesterday's run: a new dated snapshot that costs almost
  #    nothing. karb has none of this; whorl has its uploaded photos.
  FILES=0
  for DIR in ${BACKUP_DIRS:-}; do
    LINK_ARG=""
    [ -d "${LATEST}/${APP}/${DIR}" ] && LINK_ARG="--link-dest=${LATEST}/${APP}/${DIR}"
    rsync -a --rsync-path="sudo rsync" $LINK_ARG \
      "${PI}:${DATA_DIR}/${DIR}/" "${RUN}/${APP}/${DIR}/" \
      || { app_fail "${APP}: ${DIR} rsync failed"; return 1; }
    FILES=$(( FILES + $(find "${RUN}/${APP}/${DIR}" -type f 2>/dev/null | wc -l | tr -d ' ') ))
  done

  # Via sudo cat, not scp: the env file is 0600 and owned by the service
  # account, so scp as the login user silently reads nothing.
  ssh -o BatchMode=yes "$PI" "sudo cat ${ENV_FILE}" > "${RUN}/${APP}/env" \
    || { app_fail "${APP}: could not read ${ENV_FILE}"; return 1; }
  chmod 600 "${RUN}/${APP}/env"
  [ -s "${RUN}/${APP}/env" ] || { app_fail "${APP}: env file came back empty"; return 1; }

  # 4. Verify — the compressed copy that was actually kept, not the Pi's
  #    original, which would prove nothing about what arrived here. Fail rather
  #    than keep a file that only looks like a backup. Decompressed to a scratch
  #    file first because sqlite needs a real one. python3 rather than each
  #    app's own runtime, so there is one verifier for every app.
  if [ -z "${BACKUP_DB:-}" ]; then
    log "${APP}: ok — no database; env and ${FILES} file(s)"
    log "${APP}: size=$(du -sh "${RUN}/${APP}" | cut -f1)"
    return 0
  fi

  TMPDB=$(mktemp "${TMPDIR:-/tmp}/pi-backup-verify.XXXXXX")
  gunzip -c "${RUN}/${APP}/${BACKUP_DB}.gz" > "$TMPDB" \
    || { rm -f "$TMPDB"; app_fail "${APP}: snapshot will not decompress"; return 1; }
  RESULT=$(python3 - "$TMPDB" <<'PY'
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
ok = db.execute("pragma integrity_check").fetchone()[0]
if ok != "ok":
    sys.exit(f"integrity: {ok}")
tables = [r[0] for r in db.execute("select name from sqlite_master where type='table'")
          if not r[0].startswith("sqlite_")]
if not tables:
    sys.exit("no tables")
counts = []
for t in tables:
    n = db.execute(f'select count(*) from "{t}"').fetchone()[0]
    counts.append(f"{t}={n}")
print(" ".join(counts))
PY
  ) || { rm -f "$TMPDB"; app_fail "${APP}: snapshot failed verification"; return 1; }
  rm -f "$TMPDB"

  log "${APP}: ok — ${RESULT}"
  log "${APP}: files=${FILES} size=$(du -sh "${RUN}/${APP}" | cut -f1)"
}

# Apps are discovered from apps/*.conf rather than listed here, so a new app is
# backed up the moment its config exists — no second place to remember. The
# cost of that is a window where a conf exists and the app is not deployed yet,
# which is exactly why one app's failure must not abort the others.
for APP in $(appconf_list); do
  log "--- ${APP} ---"
  backup_app "$APP" || FAILED_APPS="${FAILED_APPS} ${APP}"
done

# --- Host state -------------------------------------------------------------
# Not application data, but without it a rebuilt Pi cannot serve. The tunnel
# credentials in particular are unrecoverable: Cloudflare issues the token once
# at `tunnel create` and will not reissue it. Lose them and the only path is
# creating a NEW tunnel and repointing DNS.
log "--- host ---"
mkdir -p "${RUN}/host/cloudflared"
chmod 700 "${RUN}/host"

for f in /etc/cloudflared/config.yml /root/.cloudflared/cert.pem; do
  ssh -o BatchMode=yes "$PI" "sudo cat $f" > "${RUN}/host/cloudflared/$(basename "$f")" \
    || fail "host: could not read $f"
done
# The tunnel credentials file is named for the tunnel UUID.
CRED=$(ssh -o BatchMode=yes "$PI" "sudo sh -c 'ls -1 /etc/cloudflared/*.json'" | head -1)
ssh -o BatchMode=yes "$PI" "sudo cat ${CRED}" > "${RUN}/host/cloudflared/$(basename "$CRED")" \
  || fail "host: could not read tunnel credentials"

chmod 600 "${RUN}"/host/cloudflared/*
log "host: cloudflared config + tunnel credentials"

# Promote to `latest` so tomorrow's run can hardlink against this one.
rm -f "$LATEST"; ln -s "$RUN" "$LATEST"

# Weekly: keep Sunday's run as a longer-lived copy.
if [ "$(date +%u)" = "7" ]; then
  cp -al "$RUN" "${DEST}/weekly/${STAMP}" 2>/dev/null || cp -a "$RUN" "${DEST}/weekly/${STAMP}"
  log "promoted to weekly"
fi

# Prune. `latest` is a symlink into daily/, so prune before it can dangle.
prune() {
  local dir="$1" keep="$2"
  local n; n=$(ls -1 "$dir" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt "$keep" ]; then
    ls -1 "$dir" | sort | head -n $(( n - keep )) | while read -r old; do
      [ -n "$old" ] && rm -rf "${dir:?}/${old}" && log "pruned $(basename "$dir")/${old}"
    done
  fi
}
prune "${DEST}/daily" "$KEEP_DAILY"
prune "${DEST}/weekly" "$KEEP_WEEKLY"
[ -e "$LATEST" ] || ln -s "$RUN" "$LATEST"

if [ -n "$FAILED_APPS" ]; then
  # The run still promoted and pruned: the apps that did succeed have a good
  # snapshot, and refusing to keep it would be worse. But the exit status is
  # what launchd records, so this does not pass as a clean run — and the
  # receipt below is deliberately NOT written, so the Pi's dashboard keeps
  # ageing "Last backup" until every app is covered again. A partial backup
  # must not read as a backup.
  log "=== INCOMPLETE — no backup for:${FAILED_APPS} ==="
  log "=== total $(du -sh "$DEST" | cut -f1) in ${DEST} ==="
  notify "no backup for:${FAILED_APPS}"
  exit 1
fi

# Receipt for the Pi's dashboard. Written last, and only on a fully clean run,
# so "Last backup: 6h ago" means every app actually has a verified snapshot.
#
# It lives on the Pi rather than here because the dashboard is the page that
# gets looked at, and this inverts the dependency usefully: the Pi ends up
# reporting on something it neither does nor controls, so a Mac that quietly
# stops backing up becomes visible instead of silent.
ssh -o BatchMode=yes "$PI" \
  "sudo install -d -m 0755 /var/lib/rpi-health && \
   printf '%s %s\\n' \"$(date +%s)\" \"${STAMP}\" | sudo tee /var/lib/rpi-health/last-backup >/dev/null" \
  || log "WARNING: could not write the backup receipt to the Pi (dashboard will show this run as missed)"

log "=== done — total $(du -sh "$DEST" | cut -f1) in ${DEST} ==="
