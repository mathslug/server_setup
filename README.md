# rpi

Infrastructure for the Raspberry Pi that hosts my webapps. Everything the Pi
needs that isn't specific to one application lives here; per-app build and
runtime descriptors (`Containerfile`, Quadlet unit) live in that app's own repo.

The Pi is not a pet. If the SD card dies, the recovery path below rebuilds it
from a blank card without reference to anything that was on the old one.

## Four commands

All run **on the Mac**. The disk is always an argument and never has a default —
a default there is a disk to erase. The image URL does default, since it
destroys nothing.

```
backup/pull-backups.sh                   pull state off the Pi
provision-disk.sh   <host> <disk>        erase, image, reboot into it
bootstrap.sh        <host>               everything else, end to end
provision-rescue.sh <host> <disk>        the fallback card
```

## Layout

```
provision-disk.sh   image a disk and boot it; waits, and verifies the Pi
                    came back on the disk it was told to build
bootstrap.sh        base system, tunnel, every app, state, units, timers,
                    verification. Idempotent; will not restore over data
                    that is already there
provision-rescue.sh the same imaging, plus cloudflared and rescue tooling
remote/             the halves that execute on the Pi, piped over ssh
deploy-app.sh       clone/build/start one app; re-run to update it
auto-deploy.sh      redeploy only if the branch moved; driven by a timer
apps/<name>.conf    per-app deployment config (repo, unit path, health URL)
backup/             pull-backups.sh to the Mac, restore.sh back again
monitor/            health collector + the LAN dashboard on :8080
cloudflared/        tunnel ingress, install.sh, hardened systemd unit
systemd/            system units, and install-units.sh which keeps
                    /etc/systemd/system in step with this directory
PLAN.md             the migration this is part of, and why
RECOVERY.md         rebuilding from a dead disk
SIMPLIFY.md         replacing hand-rolled parts with maintained ones,
                    and an honest account of where that is not worth it
```

## Adding an app

Start from `apps/EXAMPLE.conf.template`, which documents every field. That one
file is the whole registration — the deploy, the auto-deploy timer, the nightly
backup, the dashboard and the tunnel ingress all read it.

**In the app's own repo** (this half is easy to forget, because none of it
lives here):

- `Containerfile` — built **on the Pi**, so architecture is a non-issue
- A health endpoint that is genuinely cheap; it is polled every 30s
- `healthcheck.<ext>` — a *script*, never an inline `command -c "…"` in the
  Quadlet unit. Quadlet's parser does not survive nested quotes and truncates
  silently, leaving a container permanently "unhealthy" while the app is fine
- `snapshot.<ext>` at the **repo root** — only if the app has a database. Not
  in `deploy/`, which `.containerignore` may exclude; that bug cost a night of
  backups. `deploy-app.sh` now checks the image really contains it
- `deploy/<name>.container` — the Quadlet unit

**Then**, in order:

```
# 1. Access policy first, if it should not be public
# 2. Deploy — clones, builds, runs tests if the image does, installs units,
#    enables autodeploy@<name>.timer, health-checks
sudo /opt/rpi/deploy-app.sh <name>

# 3. Real secrets into ~podsvc/.config/<name>.env, then restart

# 4. DNS last
sudo /opt/rpi/cloudflared/render-config.sh
sudo cloudflared tunnel route dns mypi <hostname>
```

Two things are worth deciding rather than copying from the app next door.

**Sequence the conf against DNS.** The health collector starts checking
`https://<hostname><HEALTH_PATH>` the moment the conf lands on the Pi. Add the
conf when you cut DNS over, not before — karb's arrived three hours early and
booked 37 samples of 404 against a hostname still pointing at the old server,
for an outage no user experienced.

**Size the memory cap to the app's largest single file, not to its process.**
The cap in the Quadlet unit covers page cache as well as process memory, and
the nightly backup runs `VACUUM INTO` *inside the container*, so the whole
database passes through it.

| app | data | cap | why |
|---|---|---|---|
| whorl | 2.9MB | 512m | process only; anything covers it |
| karb | 702MB | 1536m | has to pass its database through the limit |
| dashboard | none | 64m | busybox httpd |

A cap is a ceiling, not a reservation, so the sum can exceed the Pi's 7.8GB and
oversizing costs nothing. Undersizing does not crash — it silently churns.

To check one is right:

```
CG=$(podman inspect <app> --format '{{.State.CgroupPath}}')
sudo cat /sys/fs/cgroup$CG/memory.events      # max should be 0
sudo grep -E '^(anon|file) ' /sys/fs/cgroup$CG/memory.stat
```

`max` counts times the app hit its ceiling; `oom_kill` counts times something
died. Non-zero `max` with zero `oom_kill` is the quiet case worth catching.
**Do not use `podman stats` MemPerc for this** — karb read a comfortable 25%
while hitting its ceiling 852 times, because the page cache it kept losing was
never counted in that number.

## Reaching the Pi from outside the LAN

Two hostnames go through the tunnel to the Pi itself rather than to an app, and
both sit behind Cloudflare Access with an email one-time-PIN policy:

```
mypi.mathslug.com    health dashboard   -> http://127.0.0.1:8080
ssh.mathslug.com     ssh                -> ssh://localhost:22
```

They are declared in `cloudflared/host-ingress.conf`, which `render-config.sh`
folds into the generated tunnel config. **Neither authenticates on its own** —
the dashboard has no login at all — so the Access policy is the only thing in
front of it. Create the Access application first, add the ingress line second,
and the DNS record last; a line here is inert until DNS exists, which is what
makes that order safe.

The dashboard is still bound to the LAN on `:8080`, so at home it is reachable
directly without a Cloudflare round trip.

SSH uses two aliases deliberately (see `~/.ssh/config`):

```
ssh mypi           LAN, direct — the default; works when the internet doesn't
ssh mypi-remote    through the tunnel and Access, from anywhere
```

`mypi-remote` shares the LAN alias's recorded host key via `HostKeyAlias`, so
there is one trusted key for the machine rather than two that could disagree.
The SSH key is still required — Access is in front of sshd, not instead of it.

First use needs a browser: `cloudflared access login https://ssh.mathslug.com`.

**The cached token lasts exactly as long as the Access application's session
duration — currently 24 hours.** That matters because `pull-backups.sh` falls
back to `mypi-remote` when the LAN is unavailable: off-LAN backups work for a
day after an interactive login, then fail (loudly — the run exits non-zero).
Making that genuinely unattended needs an Access *service token*, which is in
TODO.md and is not set up yet.

## Automatic deploys

GitHub Actions cannot reach the Pi — the tunnel only carries inbound traffic
for the apps, and nothing else connects in. So deploys are *pulled*, not pushed.

This repo is itself cloned to `/opt/rpi` on the Pi:

```
# Public, so no deploy key. Private app repos still need one each — GitHub
# refuses the same public key on a second repository.
sudo git clone https://github.com/mathslug/server_setup.git /opt/rpi

sudo /opt/rpi/systemd/install-units.sh
sudo systemctl enable --now rpi-selfupdate.timer      # keeps /opt/rpi current
sudo systemctl enable --now autodeploy@<app>.timer    # one per app
```

Every 15 minutes the timer runs a single `git ls-remote` — one SSH round trip,
no objects fetched, nothing written — and exits if the deployed SHA matches.
A rebuild only happens when the branch actually moved. If a build fails, the
previous container keeps serving; `deploy-app.sh` only restarts after a
successful build.

On the Pi itself:

```
/home/podsvc/
  apps/<name>/                          git checkout, disposable
  data/<name>/                          application state — the only thing that matters
  .config/<name>.env                    secrets, never in git
  .config/containers/systemd/*.container   Quadlet units, installed by deploy-app.sh
```

## Rebuilding onto a new disk

Find the disk first and pass it in — nothing here guesses, because a guess
would be a disk to erase.

```
ssh mypi lsblk                    # which one is it? /dev/sda, /dev/mmcblk0 …

LITE=https://downloads.raspberrypi.com/raspios_lite_arm64_latest
FULL=https://downloads.raspberrypi.com/raspios_full_arm64_latest
```

**Back up first, while the old system is still the running one.** Once the Pi
boots the new disk there are no containers to snapshot, and nothing to restore
from.

```
./backup/pull-backups.sh
./provision-disk.sh mypi /dev/sda
./bootstrap.sh      mypi --swap-mb 8192
```

That is the whole rebuild. `provision-disk.sh` carries the machine's identity
across — user, ssh host keys, wifi, hostname, timezone — so it comes back
without a prompt and `bootstrap.sh` can pick it up. Deploy keys for private app
repos are rotated with `gh` along the way.

`bootstrap.sh` is safe to re-run against a working system: it will not restore
over data that is already there unless you pass `--force-restore`.

### The rescue card

Once the primary disk is proven, give the SD card a full desktop image and
cloudflared, so a bad day still has a way in:

```
ssh mypi "sudo /opt/rpi/provision-rescue.sh /dev/mmcblk0 $FULL /etc/cloudflared"
```

`BOOT_ORDER=0xf14` tries USB first and falls back to the card. That fallback
fires when the primary disk is **absent or unbootable** — a disk that is
corrupt but still presents a boot partition will hang instead, so treat this as
a way back in rather than as automatic failover.

## Design notes

**Rootless containers under a sudo-less account.** Containers run as `podsvc`,
which has no sudo and no password. Under rootless podman a container's uid 0 is
mapped to `podsvc` on the host, so "root in the container" is an unprivileged
host user. Running them as the admin account would have made a container escape
equivalent to root.

**Quadlet, not `podman generate systemd`.** Units are declarative files that
systemd reads directly via `podman-user-generator`; editing one and running
`daemon-reload` is the whole update path. This needs podman >= 4.4, which is why
the Pi runs trixie — Debian 12 pins podman at 4.3.

**Lingering is what makes it survive a power cut.** Without
`loginctl enable-linger podsvc`, the user manager exits at logout and takes the
containers with it. With it, plus `WantedBy=default.target` in each unit,
containers start at boot with no login. `Restart=always` covers crashes.

**Logs live in RAM only on an SD card.** journald is `Storage=volatile` when
root is on `mmcblk`, because logging is the dominant source of writes (~1GB/day)
and that is what wears a card out. Anywhere else it is persistent and capped at
2G — a post-mortem needs the logs from before the reboot that lost them, which
is exactly what a volatile journal destroys.

**The memory cgroup needs enabling on a Pi.** The firmware prepends
`cgroup_disable=memory` to the kernel command line — it is not in `cmdline.txt`
and is not a Debian default. Without the override in `remote/setup.sh`,
container memory limits are accepted and silently ignored, and it takes a reboot
to apply. `/proc/cmdline` is the truth here; `/boot/firmware/cmdline.txt` is
only an intention until you reboot.

**A fresh image will not reach the network on its own.** Three things stop it,
none visible until it is booted: the first-boot wizard blocks the console
waiting for a keyboard layout, the wifi radio is persisted as rfkill-blocked,
and NetworkManager keeps a separate `WirelessEnabled` flag. `remote/provision-disk.sh`
handles all three and verifies them before the disk is trusted.

**Images are built on the Pi.** `sharp`, `better-sqlite3` and friends ship
per-architecture binaries, so a cross-built image would not run.

## Deliberately not here

- **No secrets.** `.env` files are created from a template on first deploy and
  edited by hand; they live only on the Pi and in backups.
- **No application state.** `deploy-app.sh` never writes to `~/data/`.
- **No static IP.** `ssh mypi` resolves via mDNS, which tracks address changes,
  and the Cloudflare tunnel dials outbound — so nothing depends on the Pi
  holding a particular address.
