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
#   * A unique disk ID. Every image ships the same PARTUUID, and the kernel
#     mounts root by it — with two disks attached that is ambiguous, and booting
#     one disk's kernel onto the other's root looks like success.
#   * ssh host keys are copied, so known_hosts still matches after the swap.
#   * The user is created by chroot, not userconf.txt, so it keeps its uid and
#     password hash.

set -euo pipefail

# ssh carries the client's LANG across, and the image being built has not
# generated that locale yet, so perl and apt warn on every invocation inside
# the chroot. Nothing here depends on collation or formatting.
export LC_ALL=C LANG=C

DISK="${1:?usage: $0 <disk> <image-url> [tunnel-bundle-dir]}"
IMG_URL="${2:?usage: $0 <disk> <image-url> [tunnel-bundle-dir]}"
# A directory holding cloudflared's install.sh, cloudflared.service, and the
# tunnel credentials. Optional, but without it the disk boots reachable only
# from the LAN — see the cloudflared section below.
BUNDLE="${3:-}"
WHO="${SUDO_USER:-$(id -un)}"
MNT=/mnt/newroot

die() { echo "provision-disk: $*" >&2; exit 1; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -b "$DISK" ] || die "$DISK is not a block device"

# Partition naming is not uniform: /dev/sda gives sda1, but a device whose name
# already ends in a digit takes a p — mmcblk0p1, nvme0n1p1. Getting this wrong
# produces "/dev/mmcblk02", which merely does not exist.
case "$DISK" in
  *[0-9]) BOOT="${DISK}p1"; ROOT="${DISK}p2" ;;
  *)      BOOT="${DISK}1";  ROOT="${DISK}2"  ;;
esac
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
e2fsck -fp "$ROOT" || true
resize2fs "$ROOT" >/dev/null
ok "$(lsblk -dno SIZE "$ROOT" | tr -d ' ')"

say "Mounting"
mkdir -p "$MNT"
mount "$ROOT" "$MNT"
mount "$BOOT" "$MNT/boot/firmware"
mount --bind /dev "$MNT/dev"
mount --bind /dev/pts "$MNT/dev/pts"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

say "Identity"
UID_N=$(id -u "$WHO"); GID_N=$(id -g "$WHO")
HASH=$(getent shadow "$WHO" | cut -d: -f2)

# The image ships a placeholder at uid 1000 (`pi`, nologin). Rename it: the uid,
# home and group already exist.
PLACEHOLDER=$(chroot "$MNT" getent passwd "$UID_N" | cut -d: -f1 || true)
if [ -n "$PLACEHOLDER" ] && [ "$PLACEHOLDER" != "$WHO" ]; then
  chroot "$MNT" usermod -l "$WHO" -d "/home/${WHO}" -m "$PLACEHOLDER"
  chroot "$MNT" groupmod -n "$WHO" "$PLACEHOLDER" 2>/dev/null || true
  ok "renamed ${PLACEHOLDER} -> ${WHO}"
elif [ -z "$PLACEHOLDER" ]; then
  chroot "$MNT" useradd -u "$UID_N" -m "$WHO"
fi
chroot "$MNT" usermod -p "$HASH" -s /bin/bash "$WHO"

# One at a time: usermod -G rejects the whole list if a group is missing, and a
# Lite image lacks some the running system has.
GRP=""
for g in sudo adm dialout cdrom audio video plugdev games users input netdev; do
  chroot "$MNT" getent group "$g" >/dev/null 2>&1 || continue
  chroot "$MNT" gpasswd -a "$WHO" "$g" >/dev/null
  GRP="${GRP}${GRP:+,}${g}"
done
# bootstrap.sh and deploy-app.sh both run sudo non-interactively over ssh.
install -m 0440 /etc/sudoers.d/010_pi-nopasswd "$MNT/etc/sudoers.d/010_pi-nopasswd"
ok "user ${WHO} (${UID_N}), groups ${GRP}"

install -d -m 700 -o "$UID_N" -g "$GID_N" "${MNT}/home/${WHO}/.ssh"
install -m 600 -o "$UID_N" -g "$GID_N" \
  "/home/${WHO}/.ssh/authorized_keys" "${MNT}/home/${WHO}/.ssh/authorized_keys"
cp -a /etc/ssh/ssh_host_* "$MNT/etc/ssh/"
touch "$MNT/boot/firmware/ssh"
# ssh.service ships disabled and sshswitch enables it from that flag file.
# Enable it directly too: if it does not start, the disk has to be pulled.
install -d "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sf /lib/systemd/system/ssh.service \
       "$MNT/etc/systemd/system/multi-user.target.wants/ssh.service"
ok "ssh: authorized_keys, host keys, service enabled"

cp /etc/hostname /etc/hosts "$MNT/etc/"
# Scheduled jobs pin UTC explicitly, so this only affects what logs and the
# dashboard read like — but a machine that disagrees with itself about the time
# is a bad thing to debug against.
cp -a /etc/localtime "$MNT/etc/localtime"
[ -f /etc/timezone ] && cp /etc/timezone "$MNT/etc/timezone"
mkdir -p "$MNT/etc/NetworkManager/system-connections"
cp -a /etc/NetworkManager/system-connections/. \
      "$MNT/etc/NetworkManager/system-connections/"
chmod 600 "$MNT"/etc/NetworkManager/system-connections/* 2>/dev/null || true
ok "hostname $(cat /etc/hostname), $(ls -1 /etc/NetworkManager/system-connections | tr '\n' ' ')"

# A correct profile is not enough: the radio is persisted rfkill-blocked and
# NetworkManager keeps its own WirelessEnabled flag. A fresh image restores both
# disabled and comes up with no network and no way in.
mkdir -p "$MNT/var/lib/systemd/rfkill" "$MNT/var/lib/NetworkManager"
cp -a /var/lib/systemd/rfkill/. "$MNT/var/lib/systemd/rfkill/" 2>/dev/null || true
[ -f /var/lib/NetworkManager/NetworkManager.state ] \
  && cp -a /var/lib/NetworkManager/NetworkManager.state "$MNT/var/lib/NetworkManager/"
ok "radio state: $(grep -h . "$MNT"/var/lib/systemd/rfkill/*wlan* 2>/dev/null | tr '\n' ' ')$(grep -h WirelessEnabled "$MNT/var/lib/NetworkManager/NetworkManager.state" 2>/dev/null)"

# The wizard blocks tty1 asking for a keyboard layout and username, so the
# machine never finishes booting — and it renames the user we just made,
# replacing its home directory and taking authorized_keys with it.
for u in userconfig.service userconf.service; do
  [ -e "$MNT/lib/systemd/system/$u" ] || continue
  ln -sf /dev/null "$MNT/etc/systemd/system/$u"
  ok "masked $u"
done
rm -f "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf"
# The same mechanism sets an sshd banner announcing that no user is configured,
# which then prints on every single ssh command including non-interactive ones.
rm -f "$MNT/etc/ssh/sshd_config.d/rename_user.conf"

say "Pointing the new system at its own root"
sed -i "s/PARTUUID=[0-9a-fA-F]\{8\}/PARTUUID=${PARTUUID}/g" \
  "$MNT/boot/firmware/cmdline.txt" "$MNT/etc/fstab"

# Carry over the wireless regulatory domain, which fixes the permitted channels
# and power. Without it the driver falls back to world-roaming, where some 5GHz
# channels are unavailable and a network on one of them is simply invisible.
REGDOM=$(tr ' ' '\n' < /boot/firmware/cmdline.txt | grep '^cfg80211.ieee80211_regdom=' || true)
if [ -n "$REGDOM" ] && ! grep -q 'ieee80211_regdom' "$MNT/boot/firmware/cmdline.txt"; then
  sed -i "1 s|\$| ${REGDOM}|" "$MNT/boot/firmware/cmdline.txt"
  ok "$REGDOM"
fi
# The image resizes and applies userconf on first boot. Both are already done
# here, and leaving it in means one more thing that can behave unexpectedly.
sed -i 's#init=/usr/lib/raspberrypi-sys-mods/firstboot ##' "$MNT/boot/firmware/cmdline.txt"
ok "$(tr ' ' '\n' < "$MNT/boot/firmware/cmdline.txt" | grep PARTUUID)"

# The disk must come up reachable from off the LAN. Installing the tunnel later
# in bootstrap.sh is too late: reaching the machine to run bootstrap is what the
# tunnel provides.
if [ -n "$BUNDLE" ]; then
  say "Tunnel"
  [ -f "${BUNDLE}/cert.pem" ] || die "no cert.pem in ${BUNDLE}"
  # The chroot inherits no resolver, so apt and curl inside it fail on DNS
  # rather than on anything that names the problem.
  cp /etc/resolv.conf "$MNT/etc/resolv.conf"
  rm -rf "$MNT/tmp/cf"; mkdir -p "$MNT/tmp/cf"
  cp "$BUNDLE"/* "$MNT/tmp/cf/"
  chmod +x "$MNT/tmp/cf/install.sh"
  chroot "$MNT" /tmp/cf/install.sh /tmp/cf | sed 's/^/   /'
  rm -rf "$MNT/tmp/cf"
fi

# Read by check-rescue.sh. A disk that never boots never takes a security
# update, so age matters as much as drift.
printf '%s %s\n' "$(date +%s)" "$IMG_URL" > "$MNT/etc/rpi-provisioned"

say "Verifying"
[ -s "${MNT}/home/${WHO}/.ssh/authorized_keys" ] || die "authorized_keys did not land"
chroot "$MNT" id "$WHO" >/dev/null            || die "user was not created"
ls "$MNT"/etc/ssh/ssh_host_*_key >/dev/null   || die "host keys did not land"
grep -q "PARTUUID=${PARTUUID}" "$MNT/etc/fstab" || die "fstab was not rewritten"
# Everything above is fixed by re-running. These are not: without them the disk
# boots with no network and the only fix is pulling it.
ls "$MNT"/etc/NetworkManager/system-connections/*.nmconnection >/dev/null 2>&1 \
  || die "no wifi profile — the machine would boot unreachable"
grep -q '^0$' "$MNT"/var/lib/systemd/rfkill/*wlan 2>/dev/null \
  || die "wifi would come up rfkill-blocked"
grep -q 'WirelessEnabled=true' "$MNT/var/lib/NetworkManager/NetworkManager.state" 2>/dev/null \
  || die "NetworkManager would come up with wifi disabled"
[ -e "$MNT/etc/systemd/system/userconfig.service" ] \
  || [ ! -e "$MNT/lib/systemd/system/userconfig.service" ] \
  || die "the first-boot wizard is not masked and would block the console"
if [ -n "$BUNDLE" ]; then
  [ -L "$MNT/etc/systemd/system/multi-user.target.wants/cloudflared.service" ] \
    || die "cloudflared is not enabled — the disk would boot reachable only from the LAN"
fi
ok "ok"

sync
say "${DISK} is bootable — reboot to use it"
