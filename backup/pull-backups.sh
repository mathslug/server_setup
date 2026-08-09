#!/usr/bin/env bash
#
# pull-backups.sh — pull application state off the Pi onto this Mac.
#
# Run by launchd daily (see com.mathslug.pi-backup.plist), or by hand:
#     ~/src/rpi/backup/pull-backups.sh
#
# Constraints to preserve when changing this:
#
#   * Pull, not push. The Mac sleeps and moves; a push would fail silently
#     whenever the laptop was closed.
#   * VACUUM INTO, never cp. SQLite runs in WAL mode, so copying the database
#     file alone yields a valid but silently empty database.
#   * The snapshot script lives in each app's repo — it runs in that app's
#     runtime.
#   * Dated snapshots, never a mirror. A mirror replicates corruption over the
#     last good copy.
#   * Verify the copy that was kept, not the Pi's original.

set -euo pipefail

# Set PI_HOST to force a host; otherwise chosen by the reachability check below.
PI="${PI_HOST:-}"
# Git-ignored; Time Machine covers it.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${BACKUP_DEST:-${REPO_ROOT}/backups}"
# Days and weeks, not runs — see collapse_same_day().
KEEP_DAILY=14
KEEP_WEEKLY=8

STAMP=$(date +%Y-%m-%d_%H%M%S)
RUN="${DEST}/daily/${STAMP}"
LATEST="${DEST}/latest"

# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/appconf.sh"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Best effort: a notification daemon must never be able to fail the backup that
# is reporting through it.
notify() {
  [ -n "${BACKUP_NO_NOTIFY:-}" ] && return 0
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$1\" with title \"Pi backup failed\" sound name \"Basso\"" \
    >/dev/null 2>&1 || true
}

# fail() aborts the run, for conditions that doom every app. app_fail() gives up
# on one app and lets the rest continue. Either way the run exits non-zero.
fail() { log "FAILED: $*"; notify "$*"; exit 1; }
app_fail() { log "FAILED: $*"; return 1; }
FAILED_APPS=""

mkdir -p "${DEST}/daily" "${DEST}/weekly"

log "=== backup run ${STAMP} ==="

# LAN first, Cloudflare tunnel second. `timeout` rather than ConnectTimeout
# alone: with an expired Access token `cloudflared access ssh` blocks waiting
# for a browser login, and this runs unattended at 06:00.
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

  # An empty BACKUP_DB means the app has no database. Everything below that is
  # not database-specific still runs.
  if [ -n "${BACKUP_DB:-}" ]; then

  # 1. Snapshot inside the app's container, so it sees the file the app has
  #    open. Keep the command in a script rather than inline — a nested-quoted
  #    one-liner through ssh breaks silently.
  ssh -o BatchMode=yes "$PI" "cd /tmp && sudo -u podsvc env HOME=/home/podsvc \
      XDG_RUNTIME_DIR=/run/user/1001 podman exec ${APP} ${BACKUP_SNAPSHOT_CMD}" \
    >/dev/null || { app_fail "${APP}: snapshot failed"; return 1; }

  # 2. Retrieve compressed, then delete from the Pi. gzip streams, so the SD
  #    card takes no extra writes.
  ssh -o BatchMode=yes "$PI" "sudo gzip -c ${DATA_DIR}/.backup.db" \
    > "${RUN}/${APP}/${BACKUP_DB}.gz" || { app_fail "${APP}: could not retrieve snapshot"; return 1; }
  ssh -o BatchMode=yes "$PI" "sudo rm -f ${DATA_DIR}/.backup.db"
  [ -s "${RUN}/${APP}/${BACKUP_DB}.gz" ] || { app_fail "${APP}: snapshot came back empty"; return 1; }
  fi

  # 3. State that is not in the database. --link-dest hardlinks unchanged files
  #    against the previous run.
  FILES=0
  for DIR in ${BACKUP_DIRS:-}; do
    LINK_ARG=""
    [ -d "${LATEST}/${APP}/${DIR}" ] && LINK_ARG="--link-dest=${LATEST}/${APP}/${DIR}"
    rsync -a --rsync-path="sudo rsync" $LINK_ARG \
      "${PI}:${DATA_DIR}/${DIR}/" "${RUN}/${APP}/${DIR}/" \
      || { app_fail "${APP}: ${DIR} rsync failed"; return 1; }
    FILES=$(( FILES + $(find "${RUN}/${APP}/${DIR}" -type f 2>/dev/null | wc -l | tr -d ' ') ))
  done

  # sudo cat, not scp: the env file is 0600 and owned by the service account, so
  # scp as the login user silently reads nothing.
  ssh -o BatchMode=yes "$PI" "sudo cat ${ENV_FILE}" > "${RUN}/${APP}/env" \
    || { app_fail "${APP}: could not read ${ENV_FILE}"; return 1; }
  chmod 600 "${RUN}/${APP}/env"
  [ -s "${RUN}/${APP}/env" ] || { app_fail "${APP}: env file came back empty"; return 1; }

  # 4. Verify the copy that was kept, and fail rather than keep a file that only
  #    looks like a backup. python3 rather than each app's own runtime, so one
  #    verifier covers every app.
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

# Apps come from apps/*.conf, so a new app is backed up as soon as its config
# exists — including before it is deployed, which is why one app's failure must
# not abort the rest.
for APP in $(appconf_list); do
  log "--- ${APP} ---"
  # Leave nothing behind for an app that failed: a directory here always means a
  # complete, verified backup. Later runs never revisit this one, so a fragment
  # would survive as that date's only restore point.
  backup_app "$APP" || { rm -rf "${RUN:?}/${APP}"; FAILED_APPS="${FAILED_APPS} ${APP}"; }
done

# --- Host state -------------------------------------------------------------
# Without this a rebuilt Pi cannot serve. The tunnel credentials are
# unrecoverable — Cloudflare issues the token once and will not reissue it.
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
# Collapse each day to its newest run BEFORE pruning, so KEEP_DAILY counts days
# rather than runs — otherwise several runs in one afternoon evict days of real
# history. Iterating newest-first keeps the current run, so `latest` cannot be
# left dangling.
collapse_same_day() {
  local dir="$1" d day prev=""
  for d in $(ls -1 "$dir" 2>/dev/null | sort -r); do
    day="${d%%_*}"
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
[ -e "$LATEST" ] || ln -s "$RUN" "$LATEST"

if [ -n "$FAILED_APPS" ]; then
  # The apps that succeeded keep their snapshot, but the receipt below is NOT
  # written: the Pi's dashboard keeps ageing "Last backup" until every app is
  # covered again.
  log "=== INCOMPLETE — no backup for:${FAILED_APPS} ==="
  log "=== total $(du -sh "$DEST" | cut -f1) in ${DEST} ==="
  notify "no backup for:${FAILED_APPS}"
  exit 1
fi

# Receipt for the Pi's dashboard, written only on a fully clean run. The
# timestamp must be generated ON THE PI (note the escaped \$): the dashboard
# subtracts it from the Pi's clock, so the Mac's clock here would measure skew
# between two machines and can go negative.
ssh -o BatchMode=yes "$PI" \
  "sudo install -d -m 0755 /var/lib/rpi-health && \
   printf '%s %s\\n' \"\$(date +%s)\" \"${STAMP}\" | sudo tee /var/lib/rpi-health/last-backup >/dev/null" \
  || log "WARNING: could not write the backup receipt to the Pi (dashboard will show this run as missed)"

log "=== done — total $(du -sh "$DEST" | cut -f1) in ${DEST} ==="
