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
# The imaging runs on the Pi (remote/provision-disk.sh, piped over ssh). This
# script makes a disk bootable and stops there — it never reboots. Which disk
# the machine actually boots is boot-order.sh's job, and separating them means
# a rescue card can be built without booting it, and a disk can be prepared
# while the boot order still prefers something else.

set -euo pipefail

HOST="${1:?usage: $0 <host> <disk> [image-url] [--no-tunnel]}"
DISK="${2:?usage: $0 <host> <disk> [image-url] [--no-tunnel]}"
# The disk has no default — a default there is a disk to erase. The image does:
# it destroys nothing, and a long URL pasted across a line break is its own
# class of mistake.
IMG_URL="${3:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}"
case "$IMG_URL" in --*) IMG_URL="https://downloads.raspberrypi.com/raspios_lite_arm64_latest" ;; esac
TUNNEL=1
case " $* " in *" --no-tunnel "*) TUNNEL=0 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

say "${DISK} is bootable on ${HOST}"
echo "   Nothing has switched over — ${HOST} is still running from"
echo "   $(ssh "$HOST" 'findmnt -no SOURCE /'), and boots this disk only when the boot order"
echo "   reaches it."
echo
echo "   To boot it now:  ./boot-order.sh ${HOST} usb --reboot"
echo "   Then:            ./bootstrap.sh ${HOST}"
