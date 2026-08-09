#!/usr/bin/env bash
#
# provision-disk.sh — write Raspberry Pi OS to a disk and give it this
# machine's identity, so it boots and rejoins the network unattended.
#
#     sudo ./provision-disk.sh /dev/sda https://downloads.raspberrypi.com/raspios_lite_arm64_latest
#
# Run ON the Pi. THE TARGET IS ERASED. Find the disk with lsblk and pass it in;
# nothing here has a default, because a default would be a disk to erase.
#
# Constraints to preserve:
#
#   * A unique disk ID. Choosing which disk to boot only settles where the
#     kernel comes from — the kernel then mounts root by root=PARTUUID= from
#     cmdline.txt, and every Raspberry Pi OS image ships the same one. With two
#     disks attached that is ambiguous, and booting one disk's kernel onto the
#     other's root looks like success while every write lands on the wrong disk.
#   * The ssh host keys are copied, so the machine keeps its ssh identity and
#     known_hosts on the Mac still matches after the swap.
#   * The user is created by chroot rather than by userconf.txt, so it gets the
#     same uid and password hash instead of whatever first boot decides.

set -euo pipefail

DISK="${1:?usage: $0 <disk> <image-url>}"
IMG_URL="${2:?usage: $0 <disk> <image-url>}"
WHO="${SUDO_USER:-$(id -un)}"
MNT=/mnt/newroot

die() { echo "provision-disk: $*" >&2; exit 1; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -b "$DISK" ] || die "$DISK is not a block device"
case "$(findmnt -no SOURCE /)" in
  "${DISK}"*) die "$DISK holds the running root filesystem" ;;
esac
id "$WHO" >/dev/null 2>&1 || die "no such user to copy: $WHO"

cleanup() {
  for m in "$MNT/sys" "$MNT/proc" "$MNT/dev/pts" "$MNT/dev" \
           "$MNT/boot/firmware" "$MNT"; do
    mountpoint -q "$m" && umount -l "$m"
  done
  return 0
}
trap cleanup EXIT

say "Writing image to ${DISK} ($(lsblk -dno SIZE "$DISK" | tr -d ' '))"
curl -fsSL "$IMG_URL" | xz -dc | dd of="$DISK" bs=4M conv=fsync status=none
partprobe "$DISK"; sleep 2
ok "written"

say "Assigning a unique disk ID"
DISKID=$(printf '0x%04x%04x' $RANDOM $RANDOM)
sfdisk --disk-id "$DISK" "$DISKID"
partprobe "$DISK"; sleep 2
PARTUUID="${DISKID#0x}"
ok "$PARTUUID"

say "Growing the root partition to fill the disk"
parted -s "$DISK" resizepart 2 100%
partprobe "$DISK"; sleep 2
e2fsck -fp "${DISK}2" || true
resize2fs "${DISK}2" >/dev/null
ok "$(lsblk -dno SIZE "${DISK}2" | tr -d ' ')"

say "Mounting"
mkdir -p "$MNT"
mount "${DISK}2" "$MNT"
mount "${DISK}1" "$MNT/boot/firmware"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

say "Identity"
UID_N=$(id -u "$WHO"); GID_N=$(id -g "$WHO")
HASH=$(getent shadow "$WHO" | cut -d: -f2)

# Only groups the fresh image defines. The running system carries extras (spi,
# gpio, lpadmin) and useradd rejects the whole list if one is missing.
GRP=""
for g in sudo adm dialout cdrom audio video plugdev games users input netdev; do
  chroot "$MNT" getent group "$g" >/dev/null 2>&1 && GRP="${GRP}${GRP:+,}${g}"
done
chroot "$MNT" useradd -u "$UID_N" -m -s /bin/bash -G "$GRP" "$WHO"
chroot "$MNT" usermod -p "$HASH" "$WHO"
# bootstrap.sh and deploy-app.sh both run sudo non-interactively over ssh.
install -m 0440 /etc/sudoers.d/010_pi-nopasswd "$MNT/etc/sudoers.d/010_pi-nopasswd"
ok "user ${WHO} (${UID_N}), groups ${GRP}"

install -d -m 700 -o "$UID_N" -g "$GID_N" "${MNT}/home/${WHO}/.ssh"
install -m 600 -o "$UID_N" -g "$GID_N" \
  "/home/${WHO}/.ssh/authorized_keys" "${MNT}/home/${WHO}/.ssh/authorized_keys"
cp -a /etc/ssh/ssh_host_* "$MNT/etc/ssh/"
touch "$MNT/boot/firmware/ssh"
ok "ssh: authorized_keys and host keys"

cp /etc/hostname /etc/hosts "$MNT/etc/"
mkdir -p "$MNT/etc/NetworkManager/system-connections"
cp -a /etc/NetworkManager/system-connections/. \
      "$MNT/etc/NetworkManager/system-connections/"
chmod 600 "$MNT"/etc/NetworkManager/system-connections/* 2>/dev/null || true
ok "hostname $(cat /etc/hostname), $(ls -1 /etc/NetworkManager/system-connections | tr '\n' ' ')"

say "Pointing the new system at its own root"
sed -i "s/PARTUUID=[0-9a-fA-F]\{8\}/PARTUUID=${PARTUUID}/g" \
  "$MNT/boot/firmware/cmdline.txt" "$MNT/etc/fstab"
# The image resizes and applies userconf on first boot. Both are already done
# here, and leaving it in means one more thing that can behave unexpectedly.
sed -i 's#init=/usr/lib/raspberrypi-sys-mods/firstboot ##' "$MNT/boot/firmware/cmdline.txt"
ok "$(tr ' ' '\n' < "$MNT/boot/firmware/cmdline.txt" | grep PARTUUID)"

say "Verifying"
[ -s "${MNT}/home/${WHO}/.ssh/authorized_keys" ] || die "authorized_keys did not land"
chroot "$MNT" id "$WHO" >/dev/null            || die "user was not created"
ls "$MNT"/etc/ssh/ssh_host_*_key >/dev/null   || die "host keys did not land"
grep -q "PARTUUID=${PARTUUID}" "$MNT/etc/fstab" || die "fstab was not rewritten"
ok "ok"

sync
say "${DISK} is bootable — reboot to use it"
