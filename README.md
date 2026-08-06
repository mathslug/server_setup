# rpi

Infrastructure for the Raspberry Pi that hosts my webapps. Everything the Pi
needs that isn't specific to one application lives here; per-app build and
runtime descriptors (`Containerfile`, Quadlet unit) live in that app's own repo.

The Pi is not a pet. If the SD card dies, the recovery path below rebuilds it
from a blank card without reference to anything that was on the old one.

## Layout

```
bootstrap.sh        one-time (idempotent) Pi setup — run on a fresh install
deploy-app.sh       clone/build/start one app; re-run to update it
apps/<name>.conf    per-app deployment config (repo, unit path, health URL)
PLAN.md             the migration this is part of, and why
```

On the Pi itself:

```
/home/podsvc/
  apps/<name>/                          git checkout, disposable
  data/<name>/                          application state — the only thing that matters
  .config/<name>.env                    secrets, never in git
  .config/containers/systemd/*.container   Quadlet units, installed by deploy-app.sh
```

## Rebuilding from a wiped SD card

1. Flash Raspberry Pi OS Lite (64-bit, trixie or newer). Enable ssh and
   preseed the wifi in Imager's settings.
2. `ssh mypi 'bash -s' < bootstrap.sh`
3. Add the printed deploy key to each private repo as a **read-only** deploy key.
4. `cat apps/<app>.conf deploy-app.sh | ssh mypi 'bash -s -- <app>'` for each app.
   (The config is prepended because a script piped over stdin cannot locate
   its own `apps/` directory.)
5. Restore `~/data/<app>` and `~/.config/<app>.env` from backup.

Step 5 is the only one that needs anything that isn't in version control. That
is the point: everything else is reproducible from these scripts.

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

**Logs live in RAM.** journald is `Storage=volatile`. On comparable servers
logging accounted for most of ~1GB/day of disk writes, which is the dominant
wear source on an SD card. The tradeoff is that logs do not survive a reboot.

**The memory cgroup needs enabling on a Pi.** The firmware prepends
`cgroup_disable=memory` to the kernel command line — it is not in `cmdline.txt`
and is not a Debian default. Without the override in `bootstrap.sh`, container
memory limits are accepted and silently ignored. `/proc/cmdline` is the truth
here; `/boot/firmware/cmdline.txt` is only an intention until you reboot.

**Images are built on the Pi.** `sharp`, `better-sqlite3` and friends ship
per-architecture binaries, so a cross-built image would not run.

## Deliberately not here

- **No secrets.** `.env` files are created from a template on first deploy and
  edited by hand; they live only on the Pi and in backups.
- **No application state.** `deploy-app.sh` never writes to `~/data/`.
- **No static IP.** `ssh mypi` resolves via mDNS, which tracks address changes,
  and the Cloudflare tunnel dials outbound — so nothing depends on the Pi
  holding a particular address.
