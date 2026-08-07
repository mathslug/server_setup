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

PI="${PI_HOST:-mypi}"
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
fail() { log "FAILED: $*"; exit 1; }

mkdir -p "${DEST}/daily" "${DEST}/weekly"

log "=== backup run ${STAMP} ==="

ssh -o ConnectTimeout=15 -o BatchMode=yes "$PI" true 2>/dev/null \
  || fail "cannot reach ${PI} over ssh"

for APP in $(appconf_list); do
  appconf_load "$APP"
  log "--- ${APP} ---"
  mkdir -p "${RUN}/${APP}"

  # 1. Consistent snapshot of the live database, taken on the Pi inside the
  #    app's own container so it sees the same file the app has open. The
  #    command comes from the app's conf because it has to run in the app's
  #    runtime — node for whorl, python for karb — and lives as a script in the
  #    app's repo rather than inline here, because the escaping needed to pass
  #    a nested-quoted one-liner through ssh breaks silently.
  ssh -o BatchMode=yes "$PI" "cd /tmp && sudo -u podsvc env HOME=/home/podsvc \
      XDG_RUNTIME_DIR=/run/user/1001 podman exec ${APP} ${BACKUP_SNAPSHOT_CMD}" \
    >/dev/null || fail "${APP}: snapshot failed"

  # 2. Retrieve it compressed, then remove it from the Pi so it isn't served or
  #    re-backed-up. gzip runs on the Pi and streams, so nothing extra is
  #    written to the SD card. karb's database is 710MB and compresses to 15%:
  #    that is the difference between 710MB and ~107MB over wifi every night,
  #    and between 15.6GB and 2.4GB of retained snapshots.
  ssh -o BatchMode=yes "$PI" "sudo gzip -c ${DATA_DIR}/.backup.db" \
    > "${RUN}/${APP}/${BACKUP_DB}.gz" || fail "${APP}: could not retrieve snapshot"
  ssh -o BatchMode=yes "$PI" "sudo rm -f ${DATA_DIR}/.backup.db"
  [ -s "${RUN}/${APP}/${BACKUP_DB}.gz" ] || fail "${APP}: snapshot came back empty"

  # 3. Any state that is not in the database. --link-dest makes unchanged files
  #    hardlinks against yesterday's run: a new dated snapshot that costs almost
  #    nothing. karb has none of this; whorl has its uploaded photos.
  FILES=0
  for DIR in ${BACKUP_DIRS:-}; do
    LINK_ARG=""
    [ -d "${LATEST}/${APP}/${DIR}" ] && LINK_ARG="--link-dest=${LATEST}/${APP}/${DIR}"
    rsync -a --rsync-path="sudo rsync" $LINK_ARG \
      "${PI}:${DATA_DIR}/${DIR}/" "${RUN}/${APP}/${DIR}/" \
      || fail "${APP}: ${DIR} rsync failed"
    FILES=$(( FILES + $(find "${RUN}/${APP}/${DIR}" -type f 2>/dev/null | wc -l | tr -d ' ') ))
  done

  # Via sudo cat, not scp: the env file is 0600 and owned by the service
  # account, so scp as the login user silently reads nothing.
  ssh -o BatchMode=yes "$PI" "sudo cat ${ENV_FILE}" > "${RUN}/${APP}/env" \
    || fail "${APP}: could not read ${ENV_FILE}"
  chmod 600 "${RUN}/${APP}/env"
  [ -s "${RUN}/${APP}/env" ] || fail "${APP}: env file came back empty"

  # 4. Verify. Fail loudly rather than keeping a file that only looks like a
  #    backup. Decompressed to a scratch file first: sqlite needs a real file,
  #    and checking the compressed copy we actually keep is the whole point —
  #    verifying the Pi's original would prove nothing about what arrived here.
  #    python3 rather than each app's own runtime, so there is one verifier.
  TMPDB=$(mktemp "${TMPDIR:-/tmp}/pi-backup-verify.XXXXXX")
  gunzip -c "${RUN}/${APP}/${BACKUP_DB}.gz" > "$TMPDB" \
    || { rm -f "$TMPDB"; fail "${APP}: snapshot will not decompress"; }
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
  ) || { rm -f "$TMPDB"; fail "${APP}: snapshot failed verification"; }
  rm -f "$TMPDB"

  log "${APP}: ok — ${RESULT}"
  log "${APP}: files=${FILES} size=$(du -sh "${RUN}/${APP}" | cut -f1)"
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

log "=== done — total $(du -sh "$DEST" | cut -f1) in ${DEST} ==="
