#!/usr/bin/env bash
#
# laptop-backup.sh — back up this laptop's home folder to the Pi's backup disk.
#
# Run weekly by laptop-backup.timer (install: see laptop-backup.service), or by
# hand:
#     ~/src/server_setup/backup/laptop-backup.sh
#
# restic over sftp, encrypted here: the Pi faces the internet, so it only ever
# holds ciphertext. To browse or restore:
#     export RESTIC_PASSWORD_FILE=~/.local/share/laptop-backup/password
#     restic -r sftp:mypi-remote:/srv/backup/laptop snapshots
#     restic -r sftp:mypi-remote:/srv/backup/laptop mount ~/mnt
#
# The password is the only key to the backup. Keep a copy off this laptop, or a
# dead laptop takes the means of reading its backup with it.
#
# A run that cannot reach the Pi fails with a desktop notification, which is
# also how a dead Pi gets noticed.

set -euo pipefail

# Set PI_HOST to force a host; otherwise chosen by the reachability check below.
PI="${PI_HOST:-}"
REPO_PATH=/srv/backup/laptop
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-${HOME}/.local/share/laptop-backup/password}"
# Weekly runs; a year of monthlies behind them.
KEEP_WEEKLY=8
KEEP_MONTHLY=12

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Best effort: a notification daemon must never be able to fail the backup that
# is reporting through it.
notify() {
  [ -n "${BACKUP_NO_NOTIFY:-}" ] && return 0
  command -v notify-send >/dev/null 2>&1 || return 0
  notify-send --urgency=critical --app-name="Laptop backup" "$1" "$2" \
    >/dev/null 2>&1 || true
}
fail() { log "FAILED: $*"; notify "Laptop backup failed" "$*"; exit 1; }

command -v restic >/dev/null 2>&1 || fail "restic is not installed"
[ -r "$RESTIC_PASSWORD_FILE" ] || fail "no restic password at ${RESTIC_PASSWORD_FILE}"

log "=== laptop backup ==="

# LAN first, tunnel second. `timeout`, not just ConnectTimeout: with an expired
# Access login `cloudflared access ssh` blocks on a browser login nobody answers.
#
# Each failure logs ssh's own last line. A run once failed on the tunnel in
# under a second without reaching the Pi, and with the error discarded there
# was nothing to say why.
try_host() {
  local err rc
  err=$(timeout 30 ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" true 2>&1) && return 0
  rc=$?
  [ "$rc" = 124 ] && err="no answer in 30s"
  log "  ${1}: $(printf '%s' "$err" | tail -1)"
  return 1
}

if [ -n "$PI" ]; then
  try_host "$PI" || fail "cannot reach ${PI} over ssh"
else
  # Three rounds: one dropped tunnel handshake should not cost a week's backup.
  for ROUND in 1 2 3; do
    for CANDIDATE in mypi mypi-remote; do
      if try_host "$CANDIDATE"; then PI="$CANDIDATE"; break 2; fi
    done
    [ "$ROUND" = 3 ] || sleep 20
  done
  # Off the LAN, the usual cause is the 30-day Access login lapsing.
  [ -n "$PI" ] || fail "cannot reach the Pi on the LAN (mypi) or the tunnel (mypi-remote) — if the Access login expired, \`ssh mypi-remote true\` renews it"
fi
log "reaching the Pi as '${PI}'"

export RESTIC_REPOSITORY="sftp:${PI}:${REPO_PATH}"
# BatchMode for the same reason as above: never wait on a login prompt.
SFTP=(-o "sftp.command=ssh ${PI} -o BatchMode=yes -s sftp")

# Only removes locks whose owner is gone — a run cut off by sleep or a dropped
# tunnel leaves one that would block every run after it.
restic "${SFTP[@]}" unlock -q || fail "cannot open the repository at ${RESTIC_REPOSITORY}"

# --one-file-system: the home folder and nothing mounted inside it.
RC=0
restic "${SFTP[@]}" backup "$HOME" --one-file-system \
  --exclude-caches --exclude-file="${HERE}/laptop-excludes" || RC=$?
# 3: the snapshot was saved but some files changed or vanished mid-read. A live
# home folder always has a few, so it is logged, not alarmed on.
case "$RC" in
  0) ;;
  3) log "WARNING: some files could not be read and were skipped (listed above)" ;;
  *) fail "restic backup exited ${RC} — see journalctl --user -u laptop-backup" ;;
esac

restic "${SFTP[@]}" forget --prune --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY" \
  || fail "restic forget/prune failed"

# Verify what was kept: the structure every run, plus one fifty-second of the
# data, by week number, so the whole repository is read back once a year.
SUBSET="$(( 10#$(date +%V) % 52 + 1 ))/52"
restic "${SFTP[@]}" check --read-data-subset="$SUBSET" \
  || fail "restic check failed (data subset ${SUBSET}) — the repository may be damaged"
log "check ok, data subset ${SUBSET}"

# The Pi's own snapshots have no one watching them but the dashboard. This run
# is the one thing that reaches the Pi on a schedule, so it looks.
PI_AGE=$(ssh -o BatchMode=yes "$PI" \
  'read t _ < /var/lib/rpi-health/last-backup && echo $(( $(date +%s) - t ))' 2>/dev/null || echo "")
if [ -z "$PI_AGE" ] || [ "$PI_AGE" -gt $(( 2 * 86400 )) ]; then
  MSG="the Pi's own snapshots have stopped: last one $([ -n "$PI_AGE" ] && echo "$(( PI_AGE / 3600 ))h ago" || echo "never recorded") — journalctl -u rpi-backup on the Pi"
  log "WARNING: ${MSG}"
  notify "Pi snapshots stale" "$MSG"
fi

# Receipt for the dashboard, only on a clean run. The timestamp is generated ON
# THE PI (note the escaped \$) — the dashboard subtracts it from the Pi's clock,
# so writing this clock would measure skew and can go negative.
ssh -o BatchMode=yes "$PI" \
  "sudo install -d -m 0755 /var/lib/rpi-health && \
   printf '%s\\n' \"\$(date +%s)\" | sudo tee /var/lib/rpi-health/last-laptop-backup >/dev/null" \
  || log "WARNING: could not write the receipt to the Pi (dashboard will show this run as missed)"

log "=== done ==="
