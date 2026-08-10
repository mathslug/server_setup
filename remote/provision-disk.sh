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

# The image ships a placeholder account at uid 1000 (`pi`, nologin) that first
# boot would rename from userconf.txt. Rename it here instead — the uid, home
# and group already exist, so this is one step rather than delete-and-recreate.
PLACEHOLDER=$(chroot "$MNT" getent passwd "$UID_N" | cut -d: -f1 || true)
if [ -n "$PLACEHOLDER" ] && [ "$PLACEHOLDER" != "$WHO" ]; then
  chroot "$MNT" usermod -l "$WHO" -d "/home/${WHO}" -m "$PLACEHOLDER"
  chroot "$MNT" groupmod -n "$WHO" "$PLACEHOLDER" 2>/dev/null || true
  ok "renamed ${PLACEHOLDER} -> ${WHO}"
elif [ -z "$PLACEHOLDER" ]; then
  chroot "$MNT" useradd -u "$UID_N" -m "$WHO"
fi
chroot "$MNT" usermod -p "$HASH" -s /bin/bash "$WHO"

# Added one at a time: the running system carries groups a Lite image may not
# define (spi, gpio, lpadmin), and usermod -G rejects the whole list if one is
# missing.
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
# ssh.service ships disabled; sshswitch.service enables it when that flag file
# exists. Enable it here as well rather than trusting one mechanism, because
# the cost of it not starting is a disk that has to be physically pulled.
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

# A correct wifi profile is not enough. Raspberry Pi OS persists the radio as
# rfkill-soft-blocked, and NetworkManager keeps its own WirelessEnabled flag;
# a fresh image restores both as disabled and comes up with no network and no
# way in. Carry the state from this machine, which is demonstrably connected.
mkdir -p "$MNT/var/lib/systemd/rfkill" "$MNT/var/lib/NetworkManager"
cp -a /var/lib/systemd/rfkill/. "$MNT/var/lib/systemd/rfkill/" 2>/dev/null || true
[ -f /var/lib/NetworkManager/NetworkManager.state ] \
  && cp -a /var/lib/NetworkManager/NetworkManager.state "$MNT/var/lib/NetworkManager/"
ok "radio state: $(grep -h . "$MNT"/var/lib/systemd/rfkill/*wlan* 2>/dev/null | tr '\n' ' ')$(grep -h WirelessEnabled "$MNT/var/lib/NetworkManager/NetworkManager.state" 2>/dev/null)"

# The first-boot wizard blocks tty1 asking for a keyboard layout and a
# username, so the machine never finishes booting. The user already exists, so
# there is nothing for it to ask — and left to run it renames that user and
# replaces its home directory, taking authorized_keys with it.
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

# The disk has to come up reachable from OFF the LAN, not just on it. Without
# this the tunnel is installed later by bootstrap.sh — which is too late, since
# reaching the machine to run bootstrap is the thing the tunnel provides. A
# rebuild driven from anywhere but the same network would strand it.
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

# Read by monitor/check-rescue.sh to age the disk. An image that never boots
# never takes a security update, so how old it is matters as much as whether
# its contents still match.
printf '%s %s\n' "$(date +%s)" "$IMG_URL" > "$MNT/etc/rpi-provisioned"

say "Verifying"
[ -s "${MNT}/home/${WHO}/.ssh/authorized_keys" ] || die "authorized_keys did not land"
chroot "$MNT" id "$WHO" >/dev/null            || die "user was not created"
ls "$MNT"/etc/ssh/ssh_host_*_key >/dev/null   || die "host keys did not land"
grep -q "PARTUUID=${PARTUUID}" "$MNT/etc/fstab" || die "fstab was not rewritten"
# Everything above is recoverable by re-running. These two are not: without
# them the machine boots with no network and no way in, and the only fix is
# physically pulling the disk.
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
