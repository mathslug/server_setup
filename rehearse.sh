#!/usr/bin/env bash
#
# rehearse.sh — run the whole rebuild deliberately: it proves recovery works,
# and it is how the bare metal gets updated (RECOVERY.md, "Proving it works").
#
#     ./rehearse.sh mypi-remote \
#       /dev/disk/by-id/ata-KINGSTON_SA400S37960G_50026B768786668E \
#       /dev/disk/by-id/mmc-SL32G_0xb237baac
#
# Run on the laptop. BOTH DISKS NAMED ARE ERASED: the primary, then the rescue
# card. Name them by /dev/disk/by-id, which survives sda and sdb trading places
# between boots; `ssh <host> ls -l /dev/disk/by-id` lists them. Arguments after
# the two disks go to bootstrap.sh (default --swap-mb 8192); --dry-run first
# runs only the preflight checks.
#
# Stops at the first failure and says what state that leaves the Pi in. The
# apps are down from step 4 to the end of step 7, about 25 minutes, plus about
# 5 more for the round trip when the bootloader changed.

set -euo pipefail

USAGE="usage: $0 <host> <primary by-id> <rescue by-id> [bootstrap args]"
HOST="${1:?$USAGE}"
PRIMARY="${2:?$USAGE}"
RESCUE="${3:?$USAGE}"
shift 3
DRY=0
[ "${1:-}" = "--dry-run" ] && { DRY=1; shift; }
BOOTSTRAP_ARGS=("$@")
[ ${#BOOTSTRAP_ARGS[@]} -gt 0 ] || BOOTSTRAP_ARGS=(--swap-mb 8192)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"
START=$(date +%s)
STEP="preflight"
STATE="nothing has changed yet"

step() { STEP="$1"; printf '\n\033[1m######## %s  %s\033[0m\n' "$(date +%H:%M:%S)" "$1"; }
ok()   { printf '   %s\n' "$*"; }
die()  { printf '\nrehearse: %s\n' "$*" >&2; exit 1; }
trap 'rc=$?; [ "$rc" = 0 ] || printf "\nrehearse: STOPPED in %s.\n   %s\n" "$STEP" "$STATE" >&2' EXIT

on()         { ssh -o BatchMode=yes -o ConnectTimeout=15 "$HOST" "$@"; }
resolve()    { on "readlink -f '$1'"; }
root_disk()  { on 'echo "/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"'; }
bootloader() { on 'vcgencmd bootloader_version | head -1'; }

# The apps come back on their own after a reboot; wait for each public URL.
apps_answer() {
  local app code deadline=$(( $(date +%s) + 600 ))
  for app in $(appconf_list); do
    appconf_load "$app"
    until code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$PUBLIC_URL") \
          && { [ "$code" = 200 ] || [ "$code" = 302 ]; }; do
      [ "$(date +%s)" -lt "$deadline" ] || die "${app}: ${PUBLIC_URL} answers ${code:-nothing}"
      sleep 15
    done
    ok "${app}: ${code}"
  done
}

step "preflight"
on true 2>/dev/null || die "cannot reach ${HOST} over ssh"
case "$PRIMARY" in /dev/disk/by-id/*) ;; *) die "name the primary by /dev/disk/by-id: sda and sdb trade places between boots" ;; esac
case "$RESCUE"  in /dev/disk/by-id/*) ;; *) die "name the rescue card by /dev/disk/by-id" ;; esac
P=$(resolve "$PRIMARY"); R=$(resolve "$RESCUE"); ROOT=$(root_disk)
on "test -b '$P' && test -b '$R'" || die "${PRIMARY} or ${RESCUE} is not a disk on ${HOST}"
# The primary is the disk running now. Anything else named here would be erased
# while the machine carries on from a disk this run never rebuilds.
[ "$P" = "$ROOT" ] || die "${PRIMARY} is ${P}, but ${HOST} is running from ${ROOT}"
[ "$R" != "$P" ] || die "the primary and the rescue card are the same disk"
on 'mountpoint -q /srv/backup' || die "the backup disk is not mounted, and the rebuild restores from it"
BL_START=$(bootloader)
ok "primary ${P}, rescue ${R}, bootloader ${BL_START}"
[ "$DRY" = 0 ] || { ok "dry run: stopping before anything changes"; exit 0; }

step "1/7 rebuild the rescue card"
STATE="the rescue card may be half written; the primary is untouched and serving. Re-run."
"${HERE}/provision-rescue.sh" "$HOST" "$RESCUE"
STATE="the rescue card is rebuilt but has not booted; the primary is untouched and serving. Re-run."

step "2/7 snapshot onto the backup disk"
on 'sudo systemctl start rpi-backup.service' \
  && [ "$(on 'systemctl show rpi-backup.service -p Result --value')" = success ] \
  || die "the snapshot failed: journalctl -u rpi-backup on ${HOST}"
ok "latest: $(on 'sudo readlink /srv/backup/pi/latest')"

step "3/7 a copy to the laptop"
"${HERE}/backup/pull-to-laptop.sh"

step "4/7 boot the rescue card"
STATE="the boot order may be armed for the SD card: ./boot-order.sh ${HOST} shows it, and usb --reboot returns. The primary is untouched."
"${HERE}/boot-order.sh" "$HOST" sd --reboot
STATE="running from the rescue card, apps down. The primary is untouched: ./boot-order.sh ${HOST} usb --reboot returns to it."

step "5/7 reimage the primary"
STATE="running from the rescue card, apps down. THE PRIMARY MAY BE PARTLY ERASED: re-run this step, ./provision-disk.sh ${HOST} ${PRIMARY}, then RECOVERY.md from step 3."
"${HERE}/provision-disk.sh" "$HOST" "$PRIMARY"
STATE="running from the rescue card, apps down. The primary is imaged: ./boot-order.sh ${HOST} usb --reboot, then ./bootstrap.sh ${HOST}."

step "6/7 boot the primary"
"${HERE}/boot-order.sh" "$HOST" usb --reboot
STATE="running from the fresh primary, apps down: ./bootstrap.sh ${HOST} ${BOOTSTRAP_ARGS[*]}"

step "7/7 bootstrap"
"${HERE}/bootstrap.sh" "$HOST" "${BOOTSTRAP_ARGS[@]}"
STATE="the primary is serving."

# The rescue card has not booted on a bootloader this run brought. Prove it now
# rather than on the day it is needed.
BL_END=$(bootloader)
if [ "$BL_END" != "$BL_START" ]; then
  step "bootloader round trip (${BL_START} -> ${BL_END})"
  STATE="the bootloader round trip did not finish: ./boot-order.sh ${HOST} shows where the Pi is."
  "${HERE}/boot-order.sh" "$HOST" sd --reboot
  BL_RESCUE=$(bootloader)
  "${HERE}/boot-order.sh" "$HOST" usb --reboot
  [ "$BL_RESCUE" = "$(bootloader)" ] \
    || die "the rescue card booted on ${BL_RESCUE} but the chip now holds $(bootloader): the two images carry different bootloaders"
  apps_answer
  STATE="the primary is serving."
fi

step "rehearsal passed in $(( ($(date +%s) - START) / 60 )) minutes"
