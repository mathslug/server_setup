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
#   * VACUUM INTO, never cp. whorl's database keeps most of its data in the
#     write-ahead log — production's app.db was 4096 bytes with 1.3MB of WAL.
#     Copying app.db alone yields a valid, EMPTY database with no error. VACUUM
#     INTO takes a transactionally consistent snapshot of a live database and
#     folds the WAL in, so this needs no downtime and cannot tear.
#
#   * Dated snapshots, not a mirror. A mirror faithfully replicates corruption
#     over the last good copy. Unchanged images hardlink to the previous run
#     via --link-dest, so history is nearly free.
#
#   * Verify every run. A backup nobody has opened is a rumour.

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

  # 1. Consistent snapshot of the live database, taken on the Pi.
  #    Node ships SQLite (node:sqlite); the sqlite3 CLI is not installed and is
  #    not needed. The snapshot is written inside the container so it sees the
  #    same file the app has open.
  ssh -o BatchMode=yes "$PI" "cd /tmp && sudo -u podsvc env HOME=/home/podsvc \
      XDG_RUNTIME_DIR=/run/user/1001 podman exec ${APP} node -e '
    const {DatabaseSync} = require(\"node:sqlite\");
    const fs = require(\"fs\");
    try { fs.unlinkSync(\"/data/.backup.db\"); } catch {}
    const db = new DatabaseSync(\"/data/app.db\", {readOnly:true});
    db.exec(\"VACUUM INTO \x27/data/.backup.db\x27\");
  '" || fail "${APP}: snapshot failed"

  # 2. Retrieve it, then remove it from the Pi so it isn't served or re-backed-up.
  scp -q "${PI}:${DATA_DIR}/.backup.db" "${RUN}/${APP}/app.db" \
    || fail "${APP}: could not retrieve snapshot"
  ssh -o BatchMode=yes "$PI" "sudo rm -f ${DATA_DIR}/.backup.db"

  # 3. Images and config. --link-dest makes unchanged files hardlinks against
  #    yesterday's run: a new dated snapshot that costs almost nothing.
  LINK_ARG=""
  [ -d "${LATEST}/${APP}/images" ] && LINK_ARG="--link-dest=${LATEST}/${APP}/images"
  rsync -a --rsync-path="sudo rsync" $LINK_ARG \
    "${PI}:${DATA_DIR}/images/" "${RUN}/${APP}/images/" \
    || fail "${APP}: images rsync failed"

  # Via sudo cat, not scp: the env file is 0600 and owned by the service
  # account, so scp as the login user silently reads nothing.
  ssh -o BatchMode=yes "$PI" "sudo cat ${ENV_FILE}" > "${RUN}/${APP}/env" \
    || fail "${APP}: could not read ${ENV_FILE}"
  chmod 600 "${RUN}/${APP}/env"
  [ -s "${RUN}/${APP}/env" ] || fail "${APP}: env file came back empty"

  # 4. Verify. Fail loudly rather than keeping a file that only looks like a backup.
  RESULT=$(node -e '
    const {DatabaseSync} = require("node:sqlite");
    const db = new DatabaseSync(process.argv[1], {readOnly:true});
    const ic = db.prepare("pragma integrity_check").get().integrity_check;
    if (ic !== "ok") { console.error("integrity: " + ic); process.exit(1); }
    const t = db.prepare("select name from sqlite_master where type=@t").all({t:"table"})
                .map(r => r.name).filter(n => !n.startsWith("sqlite_"));
    if (!t.length) { console.error("no tables"); process.exit(1); }
    const counts = t.map(n => n + "=" + db.prepare(`select count(*) c from "${n}"`).get().c);
    console.log(counts.join(" "));
  ' "${RUN}/${APP}/app.db") || fail "${APP}: snapshot failed verification"

  IMG=$(find "${RUN}/${APP}/images" -type f 2>/dev/null | wc -l | tr -d ' ')
  log "${APP}: ok — ${RESULT} images=${IMG} size=$(du -sh "${RUN}/${APP}" | cut -f1)"
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
