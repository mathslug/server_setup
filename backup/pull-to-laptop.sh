#!/usr/bin/env bash
#
# pull-to-laptop.sh — take a snapshot of the Pi and keep it on this laptop.
#
#     ~/src/server_setup/backup/pull-to-laptop.sh
#
# By hand only: an extra copy off the box when you want one. The Pi's own
# daily snapshots stay on its backup disk. This takes a fresh one with the same
# code (snapshot.sh --out), so it works even when that disk does not.
#
# Lands in backups/anchors/<stamp> (git-ignored), with backups/latest pointing
# at the newest. Nothing is pruned. RECOVERY.md has restoring from one; its
# host/cloudflared is what provision-disk.sh takes as CREDS_DIR.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/backups/anchors"
STAMP=$(date +%Y-%m-%d_%H%M%S)

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() { log "FAILED: $*"; exit 1; }

# shellcheck disable=SC1091
. "${REPO_ROOT}/lib/pihost.sh"

pick_pi
log "reaching the Pi as '${PI}'"

# Staged on the Pi's root disk, never the backup disk, and removed however
# this exits.
REMOTE=$(ssh -o BatchMode=yes "$PI" 'sudo mktemp -d /var/tmp/rpi-pull.XXXXXX') \
  || fail "could not make a staging directory on the Pi"
trap 'ssh -o BatchMode=yes "$PI" "sudo rm -rf ${REMOTE}"' EXIT

ssh -o BatchMode=yes "$PI" "sudo /opt/rpi/backup/snapshot.sh --out ${REMOTE}" \
  || fail "the snapshot on the Pi failed (see above)"

mkdir -p "$DEST"
PART="${DEST}/${STAMP}.partial"
rsync -a --rsync-path="sudo rsync" "${PI}:${REMOTE}/" "${PART}/" \
  || fail "copying the snapshot off the Pi failed"

# Verify what was kept, not the original: every database, and the tunnel
# credentials a rebuild cannot do without.
python3 -I - "$PART" <<'PY' || fail "the copy failed verification; left at ${PART}"
import gzip, os, shutil, sqlite3, sys, tempfile
root = sys.argv[1]
for app in sorted(os.listdir(root)):
    d = os.path.join(root, app)
    for f in (sorted(os.listdir(d)) if os.path.isdir(d) else []):
        p = os.path.join(d, f)
        if not (f.endswith(".gz") and os.path.isfile(p)):
            continue
        with tempfile.NamedTemporaryFile(dir=root) as t:
            with gzip.open(p) as g:
                shutil.copyfileobj(g, t)
            t.flush()
            ok = sqlite3.connect(f"file:{t.name}?mode=ro", uri=True).execute(
                "pragma integrity_check").fetchone()[0]
        if ok != "ok":
            sys.exit(f"{app}/{f}: {ok}")
        print(f"  {app}: database ok")
cf = os.path.join(root, "host", "cloudflared")
if not (os.path.isfile(os.path.join(cf, "cert.pem"))
        and any(n.endswith(".json") for n in os.listdir(cf))):
    sys.exit("host/cloudflared: tunnel credentials missing")
print("  host: tunnel credentials present")
PY

mv "$PART" "${DEST}/${STAMP}"
chmod 700 "${DEST}/${STAMP}"
ln -sfn "anchors/${STAMP}" "${REPO_ROOT}/backups/latest"
log "kept ${DEST}/${STAMP} ($(du -sh "${DEST}/${STAMP}" | cut -f1)); $(ls -1 "$DEST" | wc -l) on this laptop, $(du -sh "$DEST" | cut -f1) in all"
