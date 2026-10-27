# Recovery

Rebuilding from a wiped disk, using this repo plus the backup disk, which stays
plugged into the Pi throughout. About 25 minutes from the rescue card, plus 10
if the card has to be built first, mostly waiting on an image write and a build.

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
ssh <host> lsblk -o NAME,SIZE,MODEL,LABEL   # confirm which disk is the primary
./provision-disk.sh <host> /dev/sda         # erases and images it
```

Writes the image, gives the disk this machine's identity — user, ssh host keys,
wifi, hostname, timezone — and installs cloudflared, so it comes back reachable
from anywhere. Does **not** reboot.

With the backup disk attached, `sda` and `sdb` can trade names between boots,
so read the model column rather than trusting last time's letter. The script
refuses the disk labelled `pi-backup`, and takes the tunnel credentials from
it.

### 3. Boot it

```
./boot-order.sh <host> usb --reboot
```

Flips the preference, reboots, waits, and fails unless the disk asked for came
up. If the Pi never comes back, the new disk boots badly rather than not at all,
so the firmware sticks with it. Unplug it, power-cycle onto the rescue disk,
retry step 2. If it reports that the bootloader changed, see
[Updates and the bootloader](#updates-and-the-bootloader).

### 4. Bring the services back

```
./bootstrap.sh <host> --swap-mb 8192
```

Packages, service account, memory cgroup and the reboot it needs, swap,
`/opt/rpi`, tunnel, every app in `apps/*.conf`, units, timers, verification.

Safe to re-run — it will not restore over existing data without
`--force-restore`. Refuses to run on the rescue card. Passes when every app
answers 200 and each database matches its backup's size.

## The rescue disk

A fallback, not a replica: full desktop image, ssh, cloudflared on the same
tunnel, plus `parted`, `smartctl`, `git`, `rsync`, `tmux`. No containers, no
apps. It exists to get you a shell, and a browser if a monitor is attached.

`BOOT_ORDER` falls through **only when the primary is absent or unbootable**. A
disk that boots badly — a bad kernel, a corrupt root filesystem — gets chosen
forever. If the Pi is still reachable, that is what `boot-order.sh` is for. If
it is not, unplug the primary and power-cycle: the firmware finds nothing
bootable on USB and boots the card.

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

Rebuild it only as the first step of a rehearsal, never on its own — including
when your ssh key changes, host keys are regenerated, the tunnel is recreated or
you join a new network. A card from a newer image can carry a newer bootloader
than the primary, and only a rehearsal, which reimages the primary from the
same day's image, can prove both disks boot on it. The dashboard reports drift
and age; only booting it proves it works.

## Updates and the bootloader

**The bare metal changes only in a rehearsal.** Unattended upgrades take
Debian's security fixes and nothing else. Raspberry Pi's kernel, firmware and
bootloader, and cloudflared, arrive when a rehearsal reimages both disks from
that day's images. Between rehearsals the machine is exactly what the last one
proved. Rehearse about monthly, and early when an advisory lands. App code and
this repo still deploy when pushed.

**The bootloader is a chip on the board, not on either disk.** Both disks boot
through it, and it is what falls through to the rescue card. It changes in one
place only: every `boot-order.sh` switch writes the boot order *plus the newest
bootloader the running disk carries*. Nothing on the primary flashes it at
boot: `setup.sh` masks `rpi-eeprom-update.service`.

So a rehearsal can bring a new bootloader, at the switch from the fresh rescue
card back to the primary. `boot-order.sh` then prints THE BOOTLOADER CHANGED:
the primary has booted on it, the rescue card has not. **Do the round trip it
prints before calling the rehearsal done.** A fallback that has never run on
the bootloader in the chip is not a proven fallback, and the day you find out is
the day you need it.

## What the scripts do not decide

**Lost tunnel credentials.** Issued once, never reissued, but present in every
backup under `host/cloudflared/`. If those are gone too:
`cloudflared tunnel login`, `tunnel create`, `tunnel route dns --overwrite-dns`
per hostname, new UUID into `config.yml`, delete the orphan.

**No working disk at all.** Everything above needs a running system to
provision *from*. Write a card with Raspberry Pi Imager — hostname, ssh key and
wifi in its settings — boot that, then join at step 2.

**Rolling one app back.** `bootstrap.sh` always restores from
`/srv/backup/pi/latest`, which moves with every successful snapshot. To put a
single app back to an older copy, call `restore.sh` directly and leave the rest
alone:

```
ssh <host> sudo BACKUP_SRC=/srv/backup/pi/daily/<dated-run> /opt/rpi/backup/restore.sh <app>
```

**Reading the backup disk elsewhere.** It is plain ext4: plug it into any Linux
machine. `pi/` is ordinary files, root-only because it holds the env files and
tunnel credentials. `laptop/` is a restic repository, opened with the password
from wherever you keep it:

```
restic -r sftp:mypi-remote:/srv/backup/laptop restore latest --target ~/restored
restic -r /run/media/$USER/pi-backup/laptop mount ~/mnt     # disk plugged in here
```

**Restoring a database by hand.** Delete the `-wal` and `-shm` alongside it
first, or SQLite replays the empty log over what you restored. Check row counts;
an empty table means you hit exactly that.

**The backup disk is gone too.** Only what `backup/pull-to-laptop.sh` last
kept on the laptop survives, in `backups/latest`. Its tunnel credentials go to
step 2 as `CREDS_DIR=backups/latest/host/cloudflared ./provision-disk.sh ...`.
At step 4, copy it to the Pi and restore from there:

```
rsync -a backups/latest/ <host>:/var/tmp/anchor/
BACKUP_SRC=/var/tmp/anchor ./bootstrap.sh <host>
```

**What is not recoverable.** Anything since the last snapshot. And the backup
disk shares a location and a USB bus with the Pi: lose both together and the
data goes with them.

## Proving it works

A recovery path nobody has run is a rumour. The rehearsal is the break-glass
sequence run deliberately, and it is also how the bare metal gets updated:

```
ssh <host> ls -l /dev/disk/by-id                      # name both disks stably
./rehearse.sh <host> /dev/disk/by-id/<primary> /dev/disk/by-id/<rescue card> --dry-run
./rehearse.sh <host> /dev/disk/by-id/<primary> /dev/disk/by-id/<rescue card>
```

It rebuilds the rescue card, snapshots onto the backup disk, copies the Pi to
the laptop, boots the card, reimages the primary, boots it and bootstraps it.
If the bootloader changed along the way, it then does the round trip. It stops
at the first failure and says what state that leaves the Pi in; each step is
also its own script, so it can be finished by hand from there. It passes when
it reaches the end: every app answering 200, and row counts matching
`/srv/backup/pi/latest`. The apps are down from the reboot onto the card to the
end of bootstrap, about 25 minutes.

Worth doing after any change to provisioning, too. Four rehearsals in August
turned up eight defects that reading the scripts had not, two of which only
appear on a cold disk. October's found five more, among them a rebuild from the
rescue card that could never have worked: it read the tunnel credentials only
off a backup disk that the card never mounts.
