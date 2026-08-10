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
# A rescue card is an ordinary provisioned disk plus tooling, so the imaging is
# provision-disk.sh — same identity, same tunnel, same checks. All this adds is
# the packages worth having when you are booting it because something is wrong.
#
# BOOT_ORDER falls through to the card only when the primary is absent or
# unbootable. A disk that is corrupt but still presents a boot partition will
# hang instead, so this is a way back in rather than automatic failover.
# boot-order.sh is the lever for that case.

set -euo pipefail

HOST="${1:?usage: $0 <host> <disk> [image-url]}"
DISK="${2:?usage: $0 <host> <disk> [image-url]}"
# Full by default: this is the disk you boot when a desktop and a browser are
# worth having. The disk itself still has no default.
IMG_URL="${3:-https://downloads.raspberrypi.com/raspios_full_arm64_latest}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="${RESCUE_TOOLS:-parted fdisk e2fsprogs xz-utils curl git rsync smartmontools tmux}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\nprovision-rescue: %s\n' "$*" >&2; exit 1; }

"${HERE}/provision-disk.sh" "$HOST" "$DISK" "$IMG_URL" || die "imaging failed"

say "Adding rescue tooling"
ssh "$HOST" "sudo bash -s -- ${DISK} '${TOOLS}'" <<'REMOTE'
set -euo pipefail
# See remote/provision-disk.sh: the client's LANG arrives over ssh and the
# image has not generated it, so apt warns on every call inside the chroot.
export LC_ALL=C LANG=C
DISK="$1"; TOOLS="$2"
MNT=/mnt/rescue
# sda2, but mmcblk0p2 and nvme0n1p2 — a name ending in a digit takes a p.
case "$DISK" in
  *[0-9]) ROOT="${DISK}p2" ;;
  *)      ROOT="${DISK}2"  ;;
esac

cleanup() {
  for m in "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev" "$MNT"; do
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
REMOTE

say "${DISK} is a bootable rescue card"
echo "   Full desktop image, ssh, and cloudflared on the same tunnel."
echo "   It boots when ${HOST}'s primary disk is absent or unbootable, or when"
echo "   you send it there: ./boot-order.sh ${HOST} sd --reboot"
