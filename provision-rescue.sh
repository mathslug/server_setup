#!/usr/bin/env bash
#
# provision-rescue.sh — build the fallback boot disk.
#
#     sudo ./provision-rescue.sh /dev/mmcblk0 <image-url> /etc/cloudflared
#
# Runs provision-disk.sh, then adds cloudflared so the card can be reached
# remotely. Point it at the FULL Raspberry Pi OS image, not Lite: this is what
# you boot when things are bad enough that a desktop is worth having, and the
# card has room to spare.
#
# No podman and no apps. It exists to get you a shell, not to serve.
#
# BOOT_ORDER falls through to this card only when the primary disk is absent or
# unbootable. A disk that is corrupt but still presents a boot partition will
# hang instead, so this is a convenience path rather than automatic failover.

set -euo pipefail

DISK="${1:?usage: $0 <disk> <image-url> <credentials-dir>}"
IMG_URL="${2:?usage: $0 <disk> <image-url> <credentials-dir>}"
CREDS="${3:?usage: $0 <disk> <image-url> <credentials-dir>}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MNT=/mnt/newroot

die() { echo "provision-rescue: $*" >&2; exit 1; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -f "${CREDS}/cert.pem" ] || die "no cert.pem in ${CREDS}"

"${HERE}/provision-disk.sh" "$DISK" "$IMG_URL"

cleanup() {
  for m in "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev" "$MNT/opt/rpi" "$MNT"; do
    mountpoint -q "$m" && umount -l "$m"
  done
  return 0
}
trap cleanup EXIT

say "Adding cloudflared to the rescue disk"
mount "${DISK}2" "$MNT"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

# install.sh reads cloudflared.service from its own directory, so the repo has
# to be visible inside the chroot at the path it will run from.
mkdir -p "$MNT/opt/rpi" "$MNT/tmp/cfrestore"
mount --bind "$HERE" "$MNT/opt/rpi"
cp "$CREDS"/cert.pem "$CREDS"/*.json "$MNT/tmp/cfrestore/"
[ -f "${CREDS}/config.yml" ] && cp "${CREDS}/config.yml" "$MNT/tmp/cfrestore/"

# enable, not enable --now: there is no running system in here to start it on.
chroot "$MNT" /opt/rpi/cloudflared/install.sh /tmp/cfrestore \
  || die "cloudflared install failed inside the image"
rm -rf "$MNT/tmp/cfrestore"

say "Rescue disk ready on ${DISK}"
echo "   Reachable at ssh.mathslug.com when this card is what boots."
