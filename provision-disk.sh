#!/usr/bin/env bash
#
# provision-disk.sh — make a disk on the Pi bootable, and boot it.
#
#     ./provision-disk.sh mypi /dev/sda \
#       https://downloads.raspberrypi.com/raspios_lite_arm64_latest
#
# Run on the Mac. THE TARGET DISK IS ERASED. Find it first — `ssh mypi lsblk` —
# and pass it in; nothing here has a default, because a default would be a disk
# to erase.
#
# The imaging runs on the Pi (remote/provision-disk.sh, piped over ssh); this
# side owns the reboot and the waiting, and refuses to report success until the
# machine has actually come back on the disk it was told to build.

set -euo pipefail

HOST="${1:?usage: $0 <host> <disk> <image-url> [--no-tunnel]}"
DISK="${2:?usage: $0 <host> <disk> <image-url> [--no-tunnel]}"
IMG_URL="${3:?usage: $0 <host> <disk> <image-url> [--no-tunnel]}"
TUNNEL=1
[ "${4:-}" = "--no-tunnel" ] && TUNNEL=0

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"
CREDS="${CREDS_DIR:-${HERE}/backups/latest/host/cloudflared}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }
die() { printf '\nprovision-disk: %s\n' "$*" >&2; exit 1; }

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || die "cannot reach ${HOST} over ssh"

# Ship the tunnel with the disk rather than installing it afterwards. Reaching
# the machine to run bootstrap.sh is exactly what the tunnel provides, so a disk
# that boots without it can only be rebuilt from the same LAN.
BUNDLE_ARG=""
if [ "$TUNNEL" = "1" ]; then
  [ -f "${CREDS}/cert.pem" ] || die "no cert.pem in ${CREDS} (--no-tunnel to skip)"
  ls "${CREDS}"/*.json >/dev/null 2>&1 || die "no tunnel credentials in ${CREDS}"
  ssh "$HOST" 'rm -rf /tmp/cf-prov && mkdir -p /tmp/cf-prov'
  scp -q "${CREDS}"/* "${HERE}/cloudflared/install.sh" \
         "${HERE}/cloudflared/cloudflared.service" "${HOST}:/tmp/cf-prov/"
  BUNDLE_ARG=/tmp/cf-prov
  ok "tunnel credentials staged from ${CREDS}"
fi

say "Imaging ${DISK} on ${HOST}"
ssh "$HOST" "sudo bash -s -- ${DISK} ${IMG_URL} ${BUNDLE_ARG}" < "${HERE}/remote/provision-disk.sh"
[ -z "$BUNDLE_ARG" ] || ssh "$HOST" "rm -rf ${BUNDLE_ARG}"

say "Rebooting"
ssh "$HOST" 'sudo systemctl reboot' 2>/dev/null || true

# The old sshd dies mid-command, so a moment's grace stops us "succeeding"
# against the machine we are trying to replace.
sleep 20
DEADLINE=$(( $(date +%s) + BOOT_TIMEOUT ))
until ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || die \
"${HOST} did not come back within ${BOOT_TIMEOUT}s.

   It is most likely booted from ${DISK} and unreachable, because the boot
   order prefers it and a disk that boots badly does not fall through.

   Unplug ${DISK}, power-cycle to boot the other disk, and re-run this."
  sleep 10
done
ok "back after $(( BOOT_TIMEOUT - (DEADLINE - $(date +%s)) ))s"

say "Verifying"
ROOT=$(ssh "$HOST" 'findmnt -no SOURCE /')
case "$ROOT" in
  "${DISK}"*) ok "root: ${ROOT}" ;;
  *) die "came back on ${ROOT}, not ${DISK} — the new disk did not boot and the
   old one answered instead. Nothing is broken; the new disk is not in use." ;;
esac
ssh "$HOST" 'echo "   size: $(df -h / | awk "NR==2{print \$2}")"
             echo "   $(tr " " "\n" < /proc/cmdline | grep -i partuuid)"
             echo "   net:  $(ip -br addr | awk "/UP/ && !/LOOPBACK/{print \$1, \$3}")"'

say "${HOST} is running from ${DISK}"
echo "   Next: ./bootstrap.sh ${HOST}"
