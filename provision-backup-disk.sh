#!/usr/bin/env bash
#
# provision-backup-disk.sh — erase a disk on the Pi and make it the backup disk.
#
#     ./provision-backup-disk.sh mypi /dev/disk/by-id/usb-Seagate_Portable_XXXX-0:0
#
# Run on the laptop. THE TARGET DISK IS ERASED. Find it first — `ssh mypi lsblk`,
# `ls /dev/disk/by-id` — and pass it in; nothing here has a default, because a
# default would be a disk to erase. Prefer the by-id path: with two USB disks
# attached, sda and sdb can trade names between boots.
#
# The work runs on the Pi (remote/provision-backup-disk.sh, piped over ssh).

set -euo pipefail

HOST="${1:?usage: $0 <host> <disk> [--reformat]}"
DISK="${2:?usage: $0 <host> <disk> [--reformat]}"
shift 2
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" true 2>/dev/null \
  || { echo "provision-backup-disk: cannot reach ${HOST} over ssh" >&2; exit 1; }

ssh "$HOST" "sudo bash -s -- '${DISK}' $*" < "${HERE}/remote/provision-backup-disk.sh"
