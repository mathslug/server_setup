# Recovery: the boot disk died

Assumes the disk is gone and the Pi holds nothing. Everything below comes from
this repo plus `backups/latest` on the Mac.

Rough time: 45 minutes, most of it waiting on an image write and a container
build.

## What you need

- The Mac, with this repo and its `backups/` directory
- A disk to boot from — a USB SSD, or the SD card
- `gh` logged in, if any app repo is private

## The whole thing

```
ssh mypi lsblk                             # find the disk; do not guess

./provision-disk.sh mypi /dev/sda          # erases it, reboots into it
./bootstrap.sh      mypi --swap-mb 8192    # everything else
```

Both default to Raspberry Pi OS Lite; pass a URL as a third argument to
override. `provision-disk.sh` also puts cloudflared on the disk, so it comes
back reachable from anywhere rather than only from its own LAN — which matters,
because reaching it is what `bootstrap.sh` needs.

`provision-disk.sh` writes the image, gives the disk this machine's identity —
user, ssh host keys, wifi, hostname, timezone — reboots, and refuses to report
success unless the Pi comes back on the disk it was told to build.

`bootstrap.sh` does the rest: packages, `podsvc`, the memory cgroup and the
reboot it needs, swap, `/opt/rpi`, the tunnel, every app in `apps/*.conf`
(deploy, deploy-key rotation, state restore), units, timers, and a verification
pass. It is safe to re-run — it will not restore over data that is already
there unless you pass `--force-restore`.

If the Pi never comes back, it is booted from the new disk and unreachable: the
boot order prefers it, and a disk that boots badly does not fall through. Unplug
it, power-cycle onto the other disk, and re-run.

## The rescue card

The SD card is a fallback, not a replica: full desktop image, ssh, and
cloudflared on the same tunnel. No podman and no apps.

```
./provision-rescue.sh mypi /dev/mmcblk0
```

Defaults to the Full desktop image — this is the disk you boot when a browser
and a graphical wifi picker are worth having.

`BOOT_ORDER=0xf14` prefers USB and falls back to the card **only when the
primary disk is absent or unbootable**. A disk that is corrupt but still
presents a boot partition gets chosen forever. Treat this as a way back in, not
as automatic failover.

### Getting onto the rescue card deliberately

Two routes, and which one you can use depends on where you are.

**Unplug the SSD and power-cycle.** Nothing to configure, nothing to undo, and
it cannot fail in a way that leaves you worse off. Use this whenever you can
reach the machine.

**Or change the boot order over ssh**, for when you cannot:

```
./boot-order.sh mypi              # what is it set to now?
./boot-order.sh mypi sd --reboot  # prefer the card, then reboot into it
./boot-order.sh mypi usb --reboot # and back again
```

This is the lever for the case automatic fallback misses: a primary disk that
boots far enough to be broken. It only reorders — both disks stay listed, so a
wrong guess still lands somewhere you can ssh into and run it again, and both
carry cloudflared so either one is reachable from anywhere.

**It carries a risk nothing else here does.** The EEPROM write is staged and
flashed during the next boot; losing power in that window can leave the
bootloader unusable, which needs physical recovery with a dedicated SD image.
Everything else in this repo is recoverable by unplugging something. This is
not. Prefer the unplug route when you have the option.

Rebuilding the card removes your fallback while it runs, so do it only when the
primary is known good.

---

## What the scripts do not decide for you

### If the tunnel credentials are lost

Cloudflare issues a tunnel's credentials once and will not reissue them. They
are in every backup under `host/cloudflared/`, so this only arises if the
backups are gone too.

```
ssh mypi 'sudo cloudflared tunnel login'      # prints a URL; authorize mathslug.com
ssh mypi 'sudo cloudflared tunnel create mypi2'
ssh mypi 'sudo cloudflared tunnel route dns --overwrite-dns mypi2 whorl.mathslug.com'
```

Put the new UUID in `/etc/cloudflared/config.yml`, repeat the DNS route per
hostname, then delete the orphan: `cloudflared tunnel delete mypi`. The browser
may hand you `cert.pem` as a download rather than delivering it to the Pi.

### Restoring a database by hand

`backup/restore.sh` handles this, but if you are doing it manually: **delete the
`-wal` and `-shm` alongside the database first.** A freshly deployed app has
created an empty database and a write-ahead log, and SQLite will replay that log
over the file you just restored. Snapshots are taken with `VACUUM INTO`, so they
are already consistent — there is nothing to replay and no repair step.

Check row counts afterwards. If posts came back as 0, that is the WAL.

### What is not recoverable

Anything written since the last backup — up to 24 hours of posts, comments,
images and scan results. The backup runs at 06:00 and needs the Mac awake and
able to reach the Pi.

For karb that is a day of prices and evaluations, which the next scan largely
re-derives from Kalshi. The irreplaceable part is the **human review decisions**
in `candidate_pairs`; those exist nowhere else.

### Proving it works

A recovery path nobody has run is a rumour. The real test is to rebuild *from*
the rescue card with the primary disk wiped:

```
./backup/pull-backups.sh                     # immediately before — the next step erases
# unplug the primary disk, power-cycle onto the card
./provision-disk.sh mypi /dev/sda
./bootstrap.sh      mypi --swap-mb 8192
```

It passes when the row counts match `backups/latest` and both apps answer 200.
