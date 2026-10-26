#!/usr/bin/env bash
#
# provision-backup-disk.sh — erase a disk and make it the backup disk.
#
#     sudo ./provision-backup-disk.sh /dev/disk/by-id/usb-... [--reformat]
#
# Run ON the Pi, piped over ssh by ../provision-backup-disk.sh. THE TARGET IS
# ERASED. One ext4 partition labelled pi-backup, which remote/setup.sh mounts
# at /srv/backup. ext4 so it reads as plain files on any Linux machine.
#
# Refuses a disk that is already the backup disk unless --reformat: erasing it
# destroys every backup there is.

set -euo pipefail
export LC_ALL=C LANG=C

LABEL=pi-backup
MNT=/srv/backup
# by-id paths resolve to /dev/sdX, which the partition naming below needs.
DISK=$(readlink -f "${1:?usage: $0 <disk> [--reformat]}")
REFORMAT=0
[ "${2:-}" = "--reformat" ] && REFORMAT=1
WHO="${SUDO_USER:-$(id -un)}"

die() { echo "provision-backup-disk: $*" >&2; exit 1; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -b "$DISK" ] || die "$DISK is not a block device"
[ "$(lsblk -dno TYPE "$DISK")" = disk ] || die "$DISK is a partition; pass the whole disk"
[ "/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")" != "$DISK" ] \
  || die "$DISK holds the running root filesystem"
if lsblk -no LABEL "$DISK" | grep -qx "$LABEL" && [ "$REFORMAT" = 0 ]; then
  die "$DISK is already the backup disk; erasing it destroys every backup (--reformat to do it anyway)"
fi
# Mounted by label, so two disks carrying it would make the mount a coin toss.
for d in $(blkid -o device -t "LABEL=${LABEL}" 2>/dev/null); do
  [ "/dev/$(lsblk -no PKNAME "$d")" = "$DISK" ] || die "${d} is already labelled ${LABEL}"
done

case "$DISK" in
  *[0-9]) PART="${DISK}p1" ;;
  *)      PART="${DISK}1"  ;;
esac

if mountpoint -q "$MNT" && [ "$(findmnt -no SOURCE "$MNT")" = "$PART" ]; then
  umount "$MNT"
fi
! lsblk -no MOUNTPOINTS "$DISK" | grep -q . || die "$DISK has a mounted filesystem"

say "Erasing ${DISK} ($(lsblk -dno SIZE,MODEL,SERIAL "$DISK" | xargs))"
wipefs -aq "$DISK"
parted -s "$DISK" mklabel gpt mkpart "$LABEL" ext4 1MiB 100%
partprobe "$DISK"; udevadm settle
[ -b "$PART" ] || die "${PART} did not appear"
# -m 0: nothing on this disk needs space held back for root.
mkfs.ext4 -q -F -m 0 -L "$LABEL" "$PART"
ok "ext4 on ${PART}, labelled ${LABEL}"

# The laptop writes its own directory over sftp as the login user; everything
# else is root's.
TMP=$(mktemp -d)
mount "$PART" "$TMP"
install -d -m 0700 "${TMP}/pi"
install -d -m 0700 -o "$WHO" -g "$(id -g "$WHO")" "${TMP}/laptop"
umount "$TMP"; rmdir "$TMP"
ok "pi/ (root), laptop/ (${WHO})"

if grep -q "^LABEL=${LABEL} " /etc/fstab; then
  udevadm settle
  mount "$MNT"
  ok "mounted at ${MNT}"
else
  ok "not mounted: remote/setup.sh adds the fstab entry (bootstrap.sh runs it)"
fi
