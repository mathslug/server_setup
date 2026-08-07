# Recovery: the SD card died

Assumes the card is unreadable and the Pi holds nothing. Everything below comes
from this repo plus the backups on the Mac (`backups/latest/`).

Rough time: 30–45 minutes, most of it waiting on a flash and an image build.

## What you need in front of you

- The Mac, with `~/src/rpi` and its `backups/` directory
- A blank SD card (or, better, a USB SSD — `BOOT_ORDER=0xf14` already prefers USB)
- Access to GitHub to add deploy keys

## 1. Flash

Raspberry Pi OS Lite (64-bit), trixie or newer. In Imager's settings, preseed:
hostname `mypi`, your ssh public key, wifi credentials, locale.

Boot it and confirm `ssh mypi` works before continuing.

## 2. Base system

```
cd ~/src/rpi
ssh mypi 'bash -s' < bootstrap.sh
```

Idempotent. Installs podman, creates the `podsvc` service account, enables
lingering, sets journald volatile, enables the memory cgroup, removes the
desktop leftovers, and generates a new ssh key for `podsvc`.

**Reboot if it says the memory cgroup needs one.**

## 3. Deploy keys

The old keys died with the card, so GitHub still lists them and they are now
useless. Delete them and add the new ones.

```
# podsvc's key, printed at the end of bootstrap.sh
gh repo deploy-key list --repo mathslug/secretBlog     # note the stale id
gh repo deploy-key delete <id> --repo mathslug/secretBlog
gh repo deploy-key add <podsvc pubkey> --repo mathslug/secretBlog --title "podsvc@mypi"

# root needs its OWN key: GitHub requires deploy keys to be unique per repo
ssh mypi 'sudo ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_rpi'
gh repo deploy-key delete <stale id> --repo mathslug/rpi
gh repo deploy-key add <root pubkey> --repo mathslug/rpi --title "mypi root"
```

## 4. This repo, onto the Pi

```
ssh mypi 'sudo sh -c "
  printf \"Host github.com\n  IdentityFile /root/.ssh/id_ed25519_rpi\n  IdentitiesOnly yes\n\" > /root/.ssh/config
  chmod 600 /root/.ssh/config
  ssh-keyscan -H github.com >> /root/.ssh/known_hosts
  git clone git@github.com:mathslug/rpi.git /opt/rpi
"'
```

## 5. Restore the tunnel

**This is the step with no shortcut.** Cloudflare issues a tunnel's credentials
once, at `tunnel create`, and will not reissue them. If `host/cloudflared/` is
missing from your backups, skip to "If the tunnel credentials are lost" below.

```
ssh mypi 'sudo mkdir -p /etc/cloudflared /root/.cloudflared'
scp backups/latest/host/cloudflared/cert.pem mypi:/tmp/
scp backups/latest/host/cloudflared/*.json   mypi:/tmp/
scp backups/latest/host/cloudflared/config.yml mypi:/tmp/

ssh mypi 'sudo sh -c "
  install -m 0600 /tmp/cert.pem /root/.cloudflared/cert.pem
  install -m 0600 /tmp/*.json   /etc/cloudflared/
  install -m 0644 /tmp/config.yml /etc/cloudflared/config.yml
  rm -f /tmp/cert.pem /tmp/*.json /tmp/config.yml
  id cloudflared >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared
  chown cloudflared:cloudflared /etc/cloudflared/*.json
  chmod 0400 /etc/cloudflared/*.json
  # cloudflared is not in Debian; the apt repo has no trixie suite yet
  curl -fsSL -o /tmp/cf.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
  dpkg -i /tmp/cf.deb && rm -f /tmp/cf.deb
  install -m 0644 /opt/rpi/cloudflared/cloudflared.service /etc/systemd/system/
  systemctl daemon-reload && systemctl enable --now cloudflared
"'
```

DNS needs no change — the CNAME still points at the same tunnel UUID.

## 6. Redeploy the apps

```
ssh mypi 'sudo /opt/rpi/deploy-app.sh whorl'
ssh mypi 'sudo /opt/rpi/deploy-app.sh karb'
```

Clones, builds for the local architecture, installs the Quadlet unit and any
timers the app ships, starts, health-checks. Creates `<app>.env` from the
template — the real values come next.

whorl's repo is private, so its first run generates `~/.ssh/id_ed25519_whorl`,
prints it, and stops. Add it at the URL it gives you and run again. karb's repo
is public and clones over https with no key. **One key per app** — GitHub will
not accept the same public key as a deploy key on two repositories.

karb's build takes several minutes on a Pi and runs the test suite as part of
the build; a failing suite fails the build by design.

## 7. Restore application state

Snapshots are gzipped. Both databases are WAL-mode SQLite, and both were taken
with `VACUUM INTO`, so they are already consistent — there is no WAL to replay
and no repair step.

```
# --- whorl ---
scp backups/latest/whorl/app.db.gz mypi:/tmp/
scp -r backups/latest/whorl/images mypi:/tmp/
scp backups/latest/whorl/env mypi:/tmp/whorl.env

ssh mypi 'cd /tmp && sudo sh -c "
  U=\"sudo -u podsvc env HOME=/home/podsvc XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus\"
  \$U systemctl --user stop whorl.service
  D=/home/podsvc/data/whorl
  # Remove any WAL belonging to the freshly-created empty database, or SQLite
  # will try to replay it against the restored file.
  rm -f \$D/app.db \$D/app.db-wal \$D/app.db-shm
  gunzip -c /tmp/app.db.gz > \$D/app.db
  cp /tmp/images/* \$D/images/ 2>/dev/null || true
  install -o podsvc -g podsvc -m 0600 /tmp/whorl.env /home/podsvc/.config/whorl.env
  chown -R podsvc:podsvc \$D
  rm -rf /tmp/app.db.gz /tmp/images /tmp/whorl.env
  \$U systemctl --user start whorl.service
"'

# --- karb --- (~700MB uncompressed; the gunzip takes a minute)
scp backups/latest/karb/slonk_arb.db.gz mypi:/tmp/
scp backups/latest/karb/env mypi:/tmp/karb.env

ssh mypi 'cd /tmp && sudo sh -c "
  U=\"sudo -u podsvc env HOME=/home/podsvc XDG_RUNTIME_DIR=/run/user/1001 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus\"
  \$U systemctl --user stop karb.service
  D=/home/podsvc/data/karb
  rm -f \$D/slonk_arb.db \$D/slonk_arb.db-wal \$D/slonk_arb.db-shm
  gunzip -c /tmp/slonk_arb.db.gz > \$D/slonk_arb.db
  install -o podsvc -g podsvc -m 0600 /tmp/karb.env /home/podsvc/.config/karb.env
  chown -R podsvc:podsvc \$D
  rm -f /tmp/slonk_arb.db.gz /tmp/karb.env
  \$U systemctl --user start karb.service
"'
```

The first request to karb after a restore is slow — up to a minute. `db.py`
re-runs its migrations on every connection, one of which touches all 610k rows
of `tickers`, and the page cache is cold. It is fast on every request after.

## 8. Timers

```
ssh mypi 'sudo sh -c "
  /opt/rpi/systemd/install-units.sh
  systemctl enable --now rpi-selfupdate.timer rpi-health.timer
  systemctl enable --now autodeploy@whorl.timer autodeploy@karb.timer
"'
```

`install-units.sh` is also run by `rpi-selfupdate.service` on every pull, so
after this the units stay in step with the repo on their own. It used to be a
hand-copy here and nowhere else, which meant `/opt/rpi` tracked git while
`/etc/systemd/system` quietly did not.

karb's own timers — the four scan/evaluate jobs — are user units and are
installed and enabled by `deploy-app.sh` from the app's repo, so there is
nothing to do for them here.

## 9. Verify

```
curl -s -o /dev/null -w "%{http_code}\n" https://whorl.mathslug.com/healthz   # 200
curl -s -o /dev/null -w "%{http_code}\n" https://karb.mathslug.com/healthz    # 200
ssh mypi 'sudo systemctl start rpi-health.service; sudo cat /run/rpi-health/summary.txt'
./backup/pull-backups.sh                                                      # counts match
```

Check the row counts in the backup output against what you expect. If posts
came back as 0, you restored an empty database — see the WAL note in step 7.

karb's scheduled jobs are user timers installed by `deploy-app.sh`. Confirm all
four are armed, and that the times are the UTC ones (03:30/04:00 EDT, not
07:30/08:00 local — an unsuffixed `OnCalendar` would silently shift them):

```
ssh mypi 'cd /tmp && sudo -u podsvc env HOME=/home/podsvc XDG_RUNTIME_DIR=/run/user/1001 \
  systemctl --user list-timers "karb-job@*" --no-pager'
```

Their output goes to the journal, not to log files. To read it:

```
ssh mypi 'sudo journalctl _UID=1001 -n 50 --no-pager'
```

---

## If the tunnel credentials are lost

Recoverable, but noisier. `cert.pem` can be reissued by logging in again; the
per-tunnel credentials cannot, so you make a new tunnel.

```
ssh mypi 'sudo cloudflared tunnel login'        # prints a URL; authorize mathslug.com
ssh mypi 'sudo cloudflared tunnel create mypi2'
# put the new UUID into /etc/cloudflared/config.yml
ssh mypi 'sudo cloudflared tunnel route dns --overwrite-dns mypi2 whorl.mathslug.com'
```

The DNS record is rewritten to the new tunnel. Note that the browser may hand
you `cert.pem` as a download rather than delivering it to the Pi — if so, copy
it to `/root/.cloudflared/cert.pem` yourself.

Afterwards, delete the orphaned tunnel: `cloudflared tunnel delete mypi`.

## What is NOT recoverable

Anything written since the last backup — up to 24 hours of posts, comments,
uploaded images, and scan results. The backup runs daily at 12:30 and only when
the Mac is awake and on the same network as the Pi.

For karb specifically that is a day of prices and evaluations, which the next
scan largely re-derives from Kalshi. The irreplaceable part is your **human
review decisions** in `candidate_pairs` — those exist nowhere else.
