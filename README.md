# server_setup

Run containerised web apps on a Raspberry Pi: reachable from the internet with
no open ports, backed up off the box, rebuildable from a wiped disk in half an
hour. Free tier Cloudflare; no cost beyond the hardware.

Runs two kinds of app: your own, built from its repo on the Pi, and anyone's
published image, run as is. Each is one conf file plus one Quadlet unit.

- **No inbound ports** — a Cloudflare Tunnel dials out; dynamic IP is irrelevant
- **Rootless containers** under a sudo-less account, so an escape lands nowhere
- **Pull-based deploys** — the Pi polls GitHub; nothing reaches in
- **Verified backups**, with a restore path that gets exercised
- **A rescue disk** carrying the same tunnel, so a dead primary is not a trip

## Commands

Run from the workstation. The disk is always an argument and never defaults —
a default there is a disk to erase. The image URL defaults; it destroys nothing.

```
backup/pull-backups.sh                   pull app state off the Pi
provision-disk.sh   <host> <disk>        erase and image a disk
boot-order.sh       <host> [sd|usb]      choose what boots, and boot it
bootstrap.sh        <host>               everything else, end to end
provision-rescue.sh <host> <disk>        the fallback disk
```

Imaging and booting are separate: a rescue disk is built so it will *not* boot,
and a replacement can be prepared while the machine runs on the old one.

`RECOVERY.md` has the break-glass sequence.

## Layout

```
remote/           the halves that execute on the Pi, piped over ssh
apps/<name>.conf  per-app config — repo, ports, backup, health. One file
                  registers an app everywhere
deploy-app.sh     clone and build, or pull, then start one app
auto-deploy.sh    redeploy if the branch or unit changed; driven by a timer
backup/           pull-backups.sh off the Pi, restore.sh back again;
                  pi-backup.timer runs the pull daily on the laptop
monitor/          health collector, LAN dashboard, rescue-disk check
cloudflared/      tunnel ingress, install.sh, hardened unit
systemd/          system units + install-units.sh, which keeps
                  /etc/systemd/system in step with this directory
```

On the Pi: `~podsvc/apps/<name>` is a disposable checkout, `~podsvc/data/<name>`
is the only thing that matters, `~podsvc/.config/<name>.env` holds secrets.

## Adding an app

Copy `apps/EXAMPLE.conf.template`. For your own app, its repo needs a
`Containerfile`, a cheap health endpoint and `deploy/<name>.container`. For a
published image, leave `REPO` empty and write `apps/<name>.container` here,
pinned to an exact version. Either way, a database is just `BACKUP_DB`.

Then: Access policy, `deploy-app.sh <name>`, real secrets into the env file,
DNS last.

Two things not to copy from the app next door:

**Add the conf when you cut DNS over, not before.** The collector starts polling
the hostname immediately and will book failures against a name that does not
point here yet.

**Size the memory cap to the app's largest file, not its process.** The cap
covers page cache, so a database the app reads passes through it. Check with
`memory.events` — `max` should be 0. `podman stats` will not show this; page
cache the app keeps losing never appears there.

## Remote access

Two hostnames route to the Pi itself rather than an app, declared in
`cloudflared/host-ingress.conf`:

```
<dashboard host>  -> http://127.0.0.1:8080
<ssh host>        -> ssh://localhost:22
```

**Neither authenticates on its own.** Cloudflare Access is the only thing in
front. Create the Access application first, add the ingress second, DNS last —
a line here is inert until DNS exists.

Keep two ssh aliases: direct on the LAN, and through the tunnel from anywhere.
Give the remote one `HostKeyAlias` pointing at the LAN one, so there is a single
trusted host key. The ssh key is still required; Access sits in front of sshd.

Backups from the laptop ride the same Access login, which lasts 30 days. When
it lapses the next run fails with a desktop notification; `ssh mypi-remote
true` renews it.

## Deploys

Nothing can reach the Pi, so deploys are pulled. A timer runs one `git ls-remote`
every 15 minutes and exits unless the branch moved. A failed build leaves the
previous container serving.

This repo is cloned to `/opt/rpi` and updated daily, which also syncs system
units and regenerates the tunnel config.

## Things that will bite you

**A fresh Raspberry Pi OS image will not reach the network.** Three reasons,
none visible until it boots: the first-boot wizard blocks the console, the wifi
radio is persisted rfkill-blocked, and NetworkManager keeps its own
`WirelessEnabled` flag. `remote/provision-disk.sh` handles and verifies all three.

**A Pi has no clock.** A fresh image boots at its build date, so apt rejects
repository signatures as future-dated, falls back to the stale index, and
installs 404. Wait for NTP first.

**Every image ships the same PARTUUID.** With two disks attached
`root=PARTUUID=` is ambiguous, and booting one disk's kernel onto the other's
root looks like success while writes land on the wrong disk.

**The firmware prepends `cgroup_disable=memory`.** Without the override, memory
limits are accepted and silently ignored. `/proc/cmdline` is truth; applying it
needs a reboot.

**`OnCalendar` without `UTC`** silently shifts every job by your offset.

**Quadlet truncates an inline command at the first nested quote**, leaving a
container permanently "unhealthy" while the app is fine. Health checks go in a
script file.

**WAL-mode SQLite cannot be copied.** Recent writes live in the `-wal`, so `cp`
yields a valid, silently empty database. Use `VACUUM INTO`. On restore, delete
the `-wal` and `-shm` first or SQLite replays an empty log over what you
restored.

**Images build on the Pi** — per-architecture binaries.

**Lingering is what survives a power cut.** Without `loginctl enable-linger` the
user manager exits at logout and takes the containers with it.

## The blind spot

The dashboard runs *on the Pi*. If the Pi is down there is no dashboard and
nothing says so. The backup partially covers this — it runs elsewhere and fails
loudly — but with about a day of latency. For minutes instead, have each
scheduled job ping an external dead-man's-switch.
