#!/usr/bin/env bash
#
# provision-rescue.sh — build the fallback boot disk.
#
#     ./provision-rescue.sh mypi /dev/mmcblk0 \
#       https://downloads.raspberrypi.com/raspios_full_arm64_latest
#
# Run on the Mac. THE TARGET DISK IS ERASED, and it is the disk you fall back
# to, so do this only when the primary is known good.
#
# Point it at the FULL image, not Lite: this is what you boot when things are
# bad enough that a desktop and a browser are worth having, and the card has
# room to spare.
#
# Unlike provision-disk.sh this does NOT reboot. The primary disk stays the
# running system; the card sits there until it is needed.
#
# BOOT_ORDER falls through to the card only when the primary is absent or
# unbootable. A disk that is corrupt but still presents a boot partition will
# hang instead, so this is a way back in rather than automatic failover.

set -euo pipefail

HOST="${1:?usage: $0 <host> <disk> <image-url> [credentials-dir]}"
DISK="${2:?usage: $0 <host> <disk> <image-url> [credentials-dir]}"
IMG_URL="${3:?usage: $0 <host> <disk> <image-url> [credentials-dir]}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# From the backup rather than off the running Pi: cloudflared keeps cert.pem in
# /root/.cloudflared and the tunnel credentials in /etc/cloudflared, and the
# backup is the one place all of it sits together.
CREDS="${4:-${HERE}/backups/latest/host/cloudflared}"
TOOLS="${RESCUE_TOOLS:-parted fdisk e2fsprogs xz-utils curl git rsync smartmontools tmux}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\nprovision-rescue: %s\n' "$*" >&2; exit 1; }

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || die "cannot reach ${HOST} over ssh"
[ -f "${CREDS}/cert.pem" ] || die "no cert.pem in ${CREDS}"
ls "${CREDS}"/*.json >/dev/null 2>&1 || die "no tunnel credentials (*.json) in ${CREDS}"

say "Imaging ${DISK} on ${HOST}"
ssh "$HOST" "sudo bash -s -- ${DISK} ${IMG_URL}" < "${HERE}/remote/provision-disk.sh"

ssh "$HOST" 'rm -rf /tmp/cf-rescue && mkdir -p /tmp/cf-rescue'
scp -q "${CREDS}"/* "${HOST}:/tmp/cf-rescue/"

say "Adding cloudflared and rescue tooling"
ssh "$HOST" "sudo bash -s -- ${DISK} /tmp/cf-rescue '${TOOLS}'" <<'REMOTE'
set -euo pipefail
DISK="$1"; CREDS="$2"; TOOLS="$3"
MNT=/mnt/rescue
# sda2, but mmcblk0p2 and nvme0n1p2 — a name ending in a digit takes a p.
case "$DISK" in
  *[0-9]) ROOT="${DISK}p2" ;;
  *)      ROOT="${DISK}2"  ;;
esac

cleanup() {
  for m in "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev" "$MNT/opt/rpi" "$MNT"; do
    mountpoint -q "$m" && umount -l "$m"
  done
  return 0
}
trap cleanup EXIT

mkdir -p "$MNT"
mount "$ROOT" "$MNT"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

# Without this the chroot has no resolver, and every apt-get and curl inside it
# fails on DNS rather than on anything informative.
cp /etc/resolv.conf "$MNT/etc/resolv.conf"

chroot "$MNT" apt-get -qq update >/dev/null
# shellcheck disable=SC2086
chroot "$MNT" env DEBIAN_FRONTEND=noninteractive apt-get -y -qq install $TOOLS >/dev/null
printf '   tools: %s\n' "$TOOLS"

# install.sh reads cloudflared.service from its own directory, so the repo has
# to be visible inside the chroot at the path it will run from.
mkdir -p "$MNT/opt/rpi" "$MNT/tmp/cf"
mount --bind /opt/rpi "$MNT/opt/rpi"
cp "$CREDS"/cert.pem "$CREDS"/*.json "$MNT/tmp/cf/"
[ -f "${CREDS}/config.yml" ] && cp "${CREDS}/config.yml" "$MNT/tmp/cf/"
chroot "$MNT" /opt/rpi/cloudflared/install.sh /tmp/cf | sed 's/^/   /'
rm -rf "$MNT/tmp/cf"
REMOTE
ssh "$HOST" 'rm -rf /tmp/cf-rescue'

say "${DISK} is a bootable rescue card"
echo "   Full desktop image, ssh, and cloudflared on the same tunnel."
echo "   It boots only when ${HOST}'s primary disk is absent or unbootable."
