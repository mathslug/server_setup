#!/usr/bin/env bash
#
# boot-order.sh — choose which disk the Pi prefers at boot, remotely.
#
#     ./boot-order.sh mypi                 # show the current order
#     ./boot-order.sh mypi sd              # prefer the SD card, then USB
#     ./boot-order.sh mypi usb             # prefer USB, then the SD card
#     ./boot-order.sh mypi sd --reboot     # and reboot into it
#
# For the case automatic fallback does not cover. BOOT_ORDER falls through only
# when the primary disk is absent or unbootable; a disk that boots far enough
# to be broken — corrupt filesystem, bad update, a service that will not start
# — gets chosen forever. This is the lever for that, and it works from
# anywhere, because both disks carry cloudflared.
#
# It only ever REORDERS. Both disks stay in the list, so a wrong guess still
# lands somewhere you can ssh into and run this again.
#
# THE RISK, which is a different class from everything else here: --apply
# stages the EEPROM write and the flash happens during the next boot. Losing
# power in that window can leave the bootloader unusable, which needs physical
# recovery with a dedicated SD image. Everything else in this repo is
# recoverable by unplugging something; this is not. Prefer to run it while you
# can reach the machine.

set -euo pipefail

HOST="${1:?usage: $0 <host> [sd|usb] [--reboot]}"
WANT="${2:-}"
REBOOT=0
case " $* " in *" --reboot "*) REBOOT=1 ;; esac

# Read right-to-left, one nibble per device: 1=SD, 4=USB-MSD, f=restart the
# sequence. Both orders list both disks; only the preference differs.
ORDER_SD=0xf41
ORDER_USB=0xf14

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }
die() { printf '\nboot-order: %s\n' "$*" >&2; exit 1; }

describe() {
  case "$1" in
    "$ORDER_SD")  echo "SD card first, then USB" ;;
    "$ORDER_USB") echo "USB first, then SD card" ;;
    *)            echo "custom" ;;
  esac
}

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || die "cannot reach ${HOST} over ssh"

CUR=$(ssh "$HOST" 'sudo rpi-eeprom-config' | awk -F= '/^BOOT_ORDER=/{print $2}')
[ -n "$CUR" ] || die "no BOOT_ORDER in the bootloader config on ${HOST}"

say "Current"
ok "BOOT_ORDER=${CUR} — $(describe "$CUR")"
ok "booted from $(ssh "$HOST" 'findmnt -no SOURCE /')"

[ -n "$WANT" ] || exit 0

case "$WANT" in
  sd)  NEW="$ORDER_SD" ;;
  usb) NEW="$ORDER_USB" ;;
  *)   die "second argument must be 'sd' or 'usb'" ;;
esac

if [ "$CUR" = "$NEW" ]; then
  ok "already ${NEW}; nothing to do"
  exit 0
fi

# Refuse anything that is not one of the two known reorderings. A hand-edited
# order might have dropped a device, and rewriting it from here would remove
# the fallback this whole arrangement depends on.
case "$CUR" in
  "$ORDER_SD"|"$ORDER_USB") ;;
  *) die "BOOT_ORDER is ${CUR}, which this script did not set.
   Change it by hand if you meant to — refusing to overwrite an order that may
   list devices these two do not." ;;
esac

say "Setting BOOT_ORDER=${NEW} — $(describe "$NEW")"
ssh "$HOST" "sudo sh -c '
  rpi-eeprom-config --out /tmp/boot.conf
  sed -i \"s/^BOOT_ORDER=.*/BOOT_ORDER=${NEW}/\" /tmp/boot.conf
  rpi-eeprom-config --apply /tmp/boot.conf >/dev/null
  rm -f /tmp/boot.conf
'"
VERIFY=$(ssh "$HOST" 'sudo rpi-eeprom-config' | awk -F= '/^BOOT_ORDER=/{print $2}')
[ "$VERIFY" = "$NEW" ] || die "the config still reads ${VERIFY}; nothing was staged"
ok "staged — the EEPROM is flashed during the next boot"

if [ "$REBOOT" = "1" ]; then
  say "Rebooting"
  ssh "$HOST" 'sudo systemctl reboot' 2>/dev/null || true
  ok "wait for it to come back, then check with: $0 ${HOST}"
else
  ok "not rebooting; run '${0} ${HOST} ${WANT} --reboot' or reboot when ready"
fi
