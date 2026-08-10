#!/usr/bin/env bash
#
# check-rescue.sh — is the fallback disk still a usable copy of this machine?
#
#     sudo ./check-rescue.sh [disk]
#
# Writes a one-line receipt to /var/lib/rpi-health/rescue, which the dashboard
# renders. Run daily by rpi-rescue-check.timer; mounting on every health tick
# would be pointless I/O for something that changes about twice a year.
#
# What it compares is what would strand you: the ssh key you would log in with,
# the host key your known_hosts expects, the wifi it would join, and the tunnel
# it would dial. Each of those can drift silently and none of them announce it.
#
# Drift is not the same as working. Only booting the disk proves that, and
# nothing here can establish it.

set -uo pipefail

RECEIPT=/var/lib/rpi-health/rescue
MNT=/mnt/rescue-check

die() { printf '%s absent %s\n' "$(date +%s)" "$*" > "$RECEIPT"; exit 0; }

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
install -d -m 0755 "$(dirname "$RECEIPT")"

ROOT_SRC=$(findmnt -no SOURCE /)
ROOT_DISK=$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null)

# Any whole disk that is not the one we booted from. With one candidate this is
# unambiguous; with several, the first is taken and named in the receipt.
DISK="${1:-}"
if [ -z "$DISK" ]; then
  for d in $(lsblk -dno NAME --nodeps 2>/dev/null); do
    case "$d" in zram*|loop*) continue ;; esac
    [ "$d" = "$ROOT_DISK" ] && continue
    DISK="/dev/$d"; break
  done
fi
[ -n "$DISK" ] || die "no second disk attached"

case "$DISK" in
  *[0-9]) PART="${DISK}p2" ;;
  *)      PART="${DISK}2"  ;;
esac
[ -b "$PART" ] || die "${DISK} has no second partition"

mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT"
mount -o ro "$PART" "$MNT" 2>/dev/null || die "${PART} would not mount"
trap 'umount "$MNT" 2>/dev/null' EXIT

sum() { [ -e "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo missing; }
set_sum() { cat "$@" 2>/dev/null | sha256sum | cut -c1-16; }

DIFFS=""
add() { DIFFS="${DIFFS}${DIFFS:+, }$1"; }

# The key you would log in with.
LIVE_AK=$(set_sum /home/*/.ssh/authorized_keys)
CARD_AK=$(set_sum "$MNT"/home/*/.ssh/authorized_keys)
[ "$LIVE_AK" = "$CARD_AK" ] || add "authorized_keys"

# The host key your known_hosts expects.
[ "$(sum /etc/ssh/ssh_host_ed25519_key.pub)" = "$(sum "$MNT/etc/ssh/ssh_host_ed25519_key.pub")" ] \
  || add "ssh host key"

# The networks it could join.
LIVE_WIFI=$(set_sum /etc/NetworkManager/system-connections/*)
CARD_WIFI=$(set_sum "$MNT"/etc/NetworkManager/system-connections/*)
[ "$LIVE_WIFI" = "$CARD_WIFI" ] || add "wifi profiles"

# The tunnel it would dial. A credential for a tunnel that no longer exists is
# indistinguishable from a working one until you boot it.
LIVE_TUN=$(basename "$(ls -1 /etc/cloudflared/*.json 2>/dev/null | head -1)" 2>/dev/null)
CARD_TUN=$(basename "$(ls -1 "$MNT"/etc/cloudflared/*.json 2>/dev/null | head -1)" 2>/dev/null)
[ -n "$CARD_TUN" ] || add "no tunnel credentials"
[ -z "$CARD_TUN" ] || [ "$LIVE_TUN" = "$CARD_TUN" ] || add "different tunnel"

AGE_D=""
if [ -f "$MNT/etc/rpi-provisioned" ]; then
  WHEN=$(cut -d' ' -f1 "$MNT/etc/rpi-provisioned" 2>/dev/null)
  [ -n "$WHEN" ] && AGE_D=$(( ( $(date +%s) - WHEN ) / 86400 ))
fi

if [ -n "$DIFFS" ]; then
  STATUS=stale; DETAIL="$DIFFS"
else
  STATUS=ok; DETAIL="in sync with the running system"
fi
[ -z "$AGE_D" ] || DETAIL="${DETAIL}; provisioned ${AGE_D}d ago"

printf '%s %s %s on %s\n' "$(date +%s)" "$STATUS" "$DETAIL" "$DISK" > "$RECEIPT"
cat "$RECEIPT"
