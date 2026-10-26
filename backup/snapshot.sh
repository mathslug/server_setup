#!/usr/bin/env bash
#
# snapshot.sh — snapshot application state onto the backup disk.
#
# Run on the Pi, daily by rpi-backup.timer, or by hand:
#     sudo /opt/rpi/backup/snapshot.sh
#
# Writes /srv/backup/pi/{daily,weekly}/<stamp> as plain files: each database
# gzipped, BACKUP_DIRS copied, env files, the tunnel credentials. `latest`
# points at the newest complete run.
#
# Constraints to preserve:
#
#   * VACUUM INTO, never cp: WAL means copying the database file alone yields a
#     valid but silently empty one.
#   * Snapshot with the Pi's own python3, not inside the container, so it
#     works whatever the image ships.
#   * Dated snapshots, never a mirror — a mirror replicates corruption over the
#     last good copy.
#   * Verify the copy that was kept, not the original.
#   * Never write unless the disk is mounted. The mountpoint is a directory on
#     the root disk, and a run into it fills that instead.

set -euo pipefail

MNT=/srv/backup
DEST="${MNT}/pi"
# Days and weeks, not runs — see collapse_same_day().
KEEP_DAILY=30
KEEP_WEEKLY=52
RECEIPT=/var/lib/rpi-health/last-backup

STAMP=$(date +%Y-%m-%d_%H%M%S)
RUN="${DEST}/daily/${STAMP}"
LATEST="${DEST}/latest"
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"

# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/appconf.sh"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# fail() aborts the run; app_fail() gives up on one app. Both exit non-zero.
fail() { log "FAILED: $*"; exit 1; }
app_fail() { log "FAILED: $*"; return 1; }
FAILED_APPS=""

[ "$(id -u)" = 0 ] || fail "run with sudo"
mountpoint -q "$MNT" || fail "${MNT} is not mounted — is the backup disk attached?"
exec 9>/run/rpi-backup.lock
flock -n 9 || fail "another snapshot is already running"

# .tmp on the disk, not /tmp: that is tmpfs here, and a database decompressed
# for verification would sit in RAM next to the apps.
install -d -m 0700 "$DEST" "${DEST}/daily" "${DEST}/weekly" "${DEST}/.tmp"

log "=== snapshot ${STAMP} ==="

backup_app() {
  local APP="$1"
  appconf_load "$APP"
  mkdir -p "${RUN}/${APP}"

  # An empty BACKUP_DB means the app has no database. Everything below that is
  # not database-specific still runs.
  if [ -n "${BACKUP_DB:-}" ]; then

  # 1. Snapshot as the account that owns the data. SQLite locks the file the
  #    same way from either side of the container boundary, so this is as safe
  #    as a second connection inside it.
  runuser -u "$SERVICE_USER" -- python3 -I - "${DATA_DIR}/${BACKUP_DB}" \
    >/dev/null <<'PY' || { app_fail "${APP}: snapshot failed"; return 1; }
import os, sqlite3, sys
src = sys.argv[1]
dst = os.path.join(os.path.dirname(src), ".backup.db")
# VACUUM INTO refuses an existing file; one here is from a run that died.
if os.path.exists(dst):
    os.remove(dst)
# mode=rw: fail on a missing database rather than create an empty one. Not
# read-only, which on a WAL database needs the -shm to exist already. The
# timeout rides out a job holding the write lock.
con = sqlite3.connect(f"file:{src}?mode=rw", uri=True, timeout=120)
con.execute("VACUUM INTO ?", (dst,))
con.close()
PY

  # 2. Compress onto the disk, then delete the snapshot.
  gzip -c "${DATA_DIR}/.backup.db" > "${RUN}/${APP}/${BACKUP_DB}.gz" \
    || { rm -f "${DATA_DIR}/.backup.db"; app_fail "${APP}: could not compress snapshot"; return 1; }
  rm -f "${DATA_DIR}/.backup.db"
  [ -s "${RUN}/${APP}/${BACKUP_DB}.gz" ] || { app_fail "${APP}: snapshot came back empty"; return 1; }
  fi

  # 3. State that is not in the database. --link-dest hardlinks unchanged files
  #    against the previous run.
  FILES=0
  for DIR in ${BACKUP_DIRS:-}; do
    LINK_ARG=""
    [ -d "${LATEST}/${APP}/${DIR}" ] && LINK_ARG="--link-dest=${LATEST}/${APP}/${DIR}"
    rsync -a $LINK_ARG "${DATA_DIR}/${DIR}/" "${RUN}/${APP}/${DIR}/" \
      || { app_fail "${APP}: ${DIR} rsync failed"; return 1; }
    FILES=$(( FILES + $(find "${RUN}/${APP}/${DIR}" -type f 2>/dev/null | wc -l) ))
  done

  install -m 0600 "$ENV_FILE" "${RUN}/${APP}/env" \
    || { app_fail "${APP}: could not read ${ENV_FILE}"; return 1; }
  [ -s "${RUN}/${APP}/env" ] || { app_fail "${APP}: env file is empty"; return 1; }

  # 4. Verify what was kept, not the original. python3, so one verifier covers
  #    every app.
  if [ -z "${BACKUP_DB:-}" ]; then
    log "${APP}: ok — no database; env and ${FILES} file(s)"
    log "${APP}: size=$(du -sh "${RUN}/${APP}" | cut -f1)"
    return 0
  fi

  TMPDB=$(mktemp "${DEST}/.tmp/verify.XXXXXX")
  gunzip -c "${RUN}/${APP}/${BACKUP_DB}.gz" > "$TMPDB" \
    || { rm -f "$TMPDB"; app_fail "${APP}: snapshot will not decompress"; return 1; }
  RESULT=$(python3 -I - "$TMPDB" <<'PY'
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

# From apps/*.conf, so a new app is covered as soon as its config exists —
# including before it is deployed, hence per-app failure isolation.
for APP in $(appconf_list); do
  log "--- ${APP} ---"
  # A directory here always means a complete, verified backup. Later runs write
  # new dated directories, so a fragment would survive as that date's copy.
  backup_app "$APP" || { rm -rf "${RUN:?}/${APP}"; FAILED_APPS="${FAILED_APPS} ${APP}"; }
done

# --- Host state -------------------------------------------------------------
# Without this a rebuilt Pi cannot serve. The tunnel credentials are
# unrecoverable — Cloudflare issues the token once and will not reissue it.
log "--- host ---"
install -d -m 0700 "${RUN}/host" "${RUN}/host/cloudflared"
# The tunnel credentials file is named for the tunnel UUID.
CRED=$(ls -1 /etc/cloudflared/*.json 2>/dev/null | head -1)
[ -n "$CRED" ] || fail "host: no tunnel credentials in /etc/cloudflared"
for f in /etc/cloudflared/config.yml /root/.cloudflared/cert.pem "$CRED"; do
  install -m 0600 "$f" "${RUN}/host/cloudflared/" || fail "host: could not read $f"
done
log "host: cloudflared config + tunnel credentials"

# Promote to `latest` so tomorrow's run can hardlink against this one. Relative,
# so it still resolves with the disk mounted somewhere else.
ln -sfn "daily/${STAMP}" "$LATEST"

# Weekly: keep Sunday's run as a longer-lived copy.
if [ "$(date +%u)" = "7" ]; then
  cp -al "$RUN" "${DEST}/weekly/${STAMP}"
  log "promoted to weekly"
fi

# Prune. `latest` is a symlink into daily/, so prune before it can dangle.
prune() {
  local dir="$1" keep="$2"
  local n; n=$(ls -1 "$dir" 2>/dev/null | wc -l)
  if [ "$n" -gt "$keep" ]; then
    ls -1 "$dir" | sort | head -n $(( n - keep )) | while read -r old; do
      [ -n "$old" ] && rm -rf "${dir:?}/${old}" && log "pruned $(basename "$dir")/${old}"
    done
  fi
}
# Collapse each finished day to its newest run before pruning, so KEEP_DAILY
# counts days not runs. Only finished days: collapsing today would let a run
# taken minutes ago delete the one before it, and newer is not always better —
# a restore that produced an empty database would evict the good copy.
collapse_same_day() {
  local dir="$1" d day prev="" today; today=$(date +%Y-%m-%d)
  for d in $(ls -1 "$dir" 2>/dev/null | sort -r); do
    day="${d%%_*}"
    [ "$day" = "$today" ] && continue
    if [ "$day" = "$prev" ]; then
      rm -rf "${dir:?}/${d}" && log "pruned daily/${d} (superseded later the same day)"
    else
      prev="$day"
    fi
  done
}
collapse_same_day "${DEST}/daily"

prune "${DEST}/daily" "$KEEP_DAILY"
prune "${DEST}/weekly" "$KEEP_WEEKLY"
[ -e "$LATEST" ] || ln -sfn "daily/${STAMP}" "$LATEST"

DISK_LINE="$(du -sh "$DEST" | cut -f1) in ${DEST}, $(df -h --output=avail "$MNT" | tail -1 | tr -d ' ') free"

if [ -n "$FAILED_APPS" ]; then
  # Successful apps keep their snapshot, but the receipt is NOT written, so the
  # dashboard keeps ageing "Last backup" until every app is covered.
  log "=== INCOMPLETE — no backup for:${FAILED_APPS} ==="
  log "=== ${DISK_LINE} ==="
  exit 1
fi

# Receipt for the dashboard, only on a fully clean run.
install -d -m 0755 "$(dirname "$RECEIPT")"
printf '%s %s\n' "$(date +%s)" "$STAMP" > "$RECEIPT"

log "=== done — ${DISK_LINE} ==="
