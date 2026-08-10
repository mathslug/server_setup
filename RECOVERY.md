# Recovery

Rebuilding from a wiped disk, using this repo plus `backups/latest` on the
workstation. About 45 minutes, mostly waiting on an image write and a build.

Needs `gh` logged in if any app repo is private.

## Break glass

### 1. Get onto the rescue disk

Build one if it does not exist — this works from the running system as long as
it still boots enough to ssh:

```
ssh <host> lsblk                       # find the disk; do not guess
./provision-rescue.sh <host> /dev/mmcblk0
```

Then boot it, remotely or physically:

```
./boot-order.sh <host> sd --reboot
```

or **unplug the primary and power-cycle** — the firmware falls through on its
own. Prefer this when you can reach the machine; see the warning below.

### 2. Rebuild the primary

```
ssh <host> lsblk                       # confirm which disk is the primary
./provision-disk.sh <host> /dev/sda    # erases and images it
```

Writes the image, gives the disk this machine's identity — user, ssh host keys,
wifi, hostname, timezone — and installs cloudflared, so it comes back reachable
from anywhere. Does **not** reboot.

### 3. Boot it

```
./boot-order.sh <host> usb --reboot
```

Flips the preference, reboots, waits, reports which disk came up. If it reports
the wrong one, the new disk boots badly rather than not at all, so the firmware
sticks with it. Unplug it, power-cycle onto the rescue disk, retry step 2.

### 4. Bring the services back

```
./bootstrap.sh <host> --swap-mb 8192
```

Packages, service account, memory cgroup and the reboot it needs, swap,
`/opt/rpi`, tunnel, every app in `apps/*.conf`, units, timers, verification.

Safe to re-run — it will not restore over existing data without
`--force-restore`. Passes when every app answers 200 and each database matches
its backup's size.

## The rescue disk

A fallback, not a replica: full desktop image, ssh, cloudflared on the same
tunnel, plus `parted`, `smartctl`, `git`, `rsync`, `tmux`. No containers, no
apps. It exists to get you a shell, and a browser if a monitor is attached.

`BOOT_ORDER` falls through **only when the primary is absent or unbootable**. A
disk that is corrupt but still presents a boot partition gets chosen forever —
that is what `boot-order.sh` is for.

```
./boot-order.sh <host>                 # what is it now?
./boot-order.sh <host> sd --reboot     # prefer the other disk, and boot it
```

It only reorders; both disks stay listed and both carry cloudflared, so a wrong
guess still lands somewhere reachable.

**It carries a risk nothing else here does.** The EEPROM write is staged and
flashed during the *next* boot — so an unplanned reboot applies a change you
left armed, and losing power during the flash needs physical recovery with a
dedicated SD image. Everything else here is undone by unplugging something.

Rebuild the rescue disk when your ssh key changes, host keys are regenerated,
the tunnel is recreated, or you join a new network — and periodically anyway,
since a disk that never boots never takes a security update. The dashboard
reports drift and age; only booting it proves it works.

## What the scripts do not decide

**Lost tunnel credentials.** Issued once, never reissued, but present in every
backup under `host/cloudflared/`. If those are gone too:
`cloudflared tunnel login`, `tunnel create`, `tunnel route dns --overwrite-dns`
per hostname, new UUID into `config.yml`, delete the orphan.

**No working disk at all.** Everything above needs a running system to
provision *from*. Write a card with Raspberry Pi Imager — hostname, ssh key and
wifi in its settings — boot that, then join at step 2.

**Restoring a database by hand.** Delete the `-wal` and `-shm` alongside it
first, or SQLite replays the empty log over what you restored. Check row counts;
an empty table means you hit exactly that.

**What is not recoverable.** Anything since the last backup.

## Proving it works

A recovery path nobody has run is a rumour. Take a backup, then run the
break-glass sequence deliberately. It passes when row counts match
`backups/latest` and every app answers 200.

Worth doing after any change to provisioning. Four rehearsals turned up eight
defects that reading the scripts had not, two of which only appear on a cold
disk.
