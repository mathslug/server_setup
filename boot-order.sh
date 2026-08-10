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

STAGED=/boot/firmware/pieeprom.upd
BOOT_TIMEOUT="${BOOT_TIMEOUT:-420}"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }
die() { printf '\nboot-order: %s\n' "$*" >&2; exit 1; }

# --apply does not change the running EEPROM; it stages an image that the
# firmware flashes during the next boot. Reading the active config back
# therefore shows the OLD value and looks like the write failed — which is
# exactly the wrong thing to believe, because a boot change is now armed.
order_active() { ssh "$HOST" 'sudo rpi-eeprom-config' | awk -F= '/^BOOT_ORDER=/{print $2}'; }
order_staged() {
  ssh "$HOST" "sudo sh -c 'test -f ${STAGED} && rpi-eeprom-config ${STAGED} || true'" \
    | awk -F= '/^BOOT_ORDER=/{print $2}'
}

describe() {
  case "$1" in
    "$ORDER_SD")  echo "SD card first, then USB" ;;
    "$ORDER_USB") echo "USB first, then SD card" ;;
    *)            echo "custom" ;;
  esac
}

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || die "cannot reach ${HOST} over ssh"

CUR=$(order_active)
[ -n "$CUR" ] || die "no BOOT_ORDER in the bootloader config on ${HOST}"
PENDING=$(order_staged)

say "Current"
ok "BOOT_ORDER=${CUR} — $(describe "$CUR")"
ok "booted from $(ssh "$HOST" 'findmnt -no SOURCE /')"
if [ -n "$PENDING" ] && [ "$PENDING" != "$CUR" ]; then
  ok "PENDING: ${PENDING} — $(describe "$PENDING") — takes effect on the next boot"
fi

[ -n "$WANT" ] || exit 0

case "$WANT" in
  sd)  NEW="$ORDER_SD" ;;
  usb) NEW="$ORDER_USB" ;;
  *)   die "second argument must be 'sd' or 'usb'" ;;
esac

if [ "$CUR" = "$NEW" ] && { [ -z "$PENDING" ] || [ "$PENDING" = "$NEW" ]; }; then
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
VERIFY=$(order_staged)
[ "$VERIFY" = "$NEW" ] || die "the staged image reads '${VERIFY}'; nothing was armed"
ok "staged — active is still ${CUR}; the EEPROM is flashed during the next boot"
ok "to cancel before then: ssh ${HOST} 'sudo rm -f ${STAGED}'"

if [ "$REBOOT" != "1" ]; then
  ok "not rebooting; run '${0} ${HOST} ${WANT} --reboot' or reboot when ready"
  exit 0
fi

say "Rebooting"
ssh "$HOST" 'sudo systemctl reboot' 2>/dev/null || true

# A moment's grace: the old sshd dies mid-command, and answering before it has
# gone would mean verifying the machine we are trying to leave.
sleep 20
DEADLINE=$(( $(date +%s) + BOOT_TIMEOUT ))
until ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" true 2>/dev/null; do
  [ "$(date +%s)" -lt "$DEADLINE" ] || die \
"${HOST} did not come back within ${BOOT_TIMEOUT}s.

   The preferred disk may boot badly rather than not at all, in which case the
   firmware sticks with it instead of falling through. Unplug it and
   power-cycle onto the other one."
  sleep 10
done

say "Verifying"
ok "active BOOT_ORDER=$(order_active)"
ok "booted from $(ssh "$HOST" 'findmnt -no SOURCE /')"
ok "$(ssh "$HOST" 'df -h / | awk "NR==2{print \$2\" filesystem\"}"')"
