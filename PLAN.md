# Self-hosting plan: DigitalOcean → Raspberry Pi

## Context

The GitHub Student Pack credit that covered DigitalOcean is exhausted. July's invoice was
$21.73 fully covered; August has only $0.86 of credit left against $12/mo of droplets, so this
is the first month with a real bill — $144/yr going forward.

The goal is to move the three live webapps onto hardware already owned (a Raspberry Pi 4B),
front them with a free tunnel, and decommission the paid infrastructure. **Budget is $0** — no
hardware purchases. Everything below uses equipment already in hand.

Secondary benefit: `whorl` currently has no backup of any kind. This fixes that.

---

## Verified current state

**Pi** — `mypi.local`, Pi 4B 8GB, 4×Cortex-A72
- Debian 13 (trixie) 13.6, kernel 6.18.39+rpt-rpi-v8, arm64 — upgraded in place 2026-08-06
- Desktop stack purged (66 packages); effectively Pi OS Lite
- 18GB free on a 32GB SanDisk Ultra SD card (manufactured 05/2021)
- Podman 5.4.2 available (Quadlet-capable)
- **Wi-Fi only** — `eth0` is `NO-CARRIER`
- `BOOT_ORDER=0xf14` — USB first, SD fallback. No change needed if a drive is ever added.

**Apps to move**

| App | Stack | Port | Data | Currently |
|---|---|---|---|---|
| `whorl` | Node ≥22.13, Express, `node:sqlite`, sharp | 3000 | `/srv/app-data` (4MB) | DO `slugclub` |
| `karb` | Python 3.13, Flask, gunicorn, uv | 8000 | `/var/lib/slonk-arb` (703MB db) | DO `slonk-arb` |
| `AvaLong` | Python 3.12, Flask, uWSGI FastCGI | 3031 | none (in-memory) | OpenBSD vm08 |

**Staying put:** `www.mathslug.com`, `bentleybuilding.com`, `timbentleymusic.com` are all on
GitHub Pages already, despite being configured in the OpenBSD box's `httpd.conf`. That config is
dead — DNS points at `185.199.108-111.153`. `gpdecaf.info` has no DNS at all.

**Consequence:** AvaLong is the OpenBSD VM's *only* live workload. Once it moves, that renewal
(~€60/yr) buys nothing.

---

## Target architecture

```
visitor ──https──▶ Cloudflare edge (TLS, ~15ms)
                        │  outbound tunnel, no open ports
                        ▼
                   cloudflared on Pi
                        │
              ┌─────────┼─────────┐
              ▼         ▼         ▼
          whorl:3000  karb:8000  avalong:5000
              └─────────┼─────────┘
                   Podman + Quadlet
                        │
                   Mac pulls app data nightly (rsync)
```

Cloudflare Tunnel dials *out* from the Pi, so the ISP's dynamic IP and NAT are both non-issues,
and no router ports are opened.

---

## Steps

### 1. Pi baseline

- Remove desktop leftovers still listening: **VNC on `*:5900`** and CUPS on `:631`.
  `apt purge cups cups-browsed` and disable/remove the VNC server.
- SD-card write mitigation — measured baseline on the existing droplets is ~1GB/day, almost all
  of it journald and system churn rather than app writes:
  - `/etc/systemd/journald.conf` → `Storage=volatile`, `RuntimeMaxUse=64M`
  - `logrotate` for karb (its logs are currently **279MB unrotated** in production)
- DHCP reservation for the Pi on the router.
- `unattended-upgrades` for security patches.

### 2. Podman + Quadlet

`apt install podman`. Run **rootless** under a dedicated user. Quadlet units live in
`~/.config/containers/systemd/*.container` and are managed by systemd directly — no
`podman generate systemd`, which is what bookworm's 4.3 would have forced.

### 3. Containerize the apps

**whorl** — the cleanest port. Reuse `secretBlog/deploy/`:
- Base `node:24-trixie-slim` (arm64 prebuilds exist for `sharp`)
- `node:sqlite` requires Node ≥22.5 — pin 24, matching the existing `deploy.sh`
- Volume: `/srv/whorl-data` → `DATA_DIR`
- Env from existing GH Actions secrets: `PORT NODE_ENV DATA_DIR DOMAIN APP_TZ INVITE_CODE`

**karb** — the most work:
- Base `python:3.13-slim`, `uv` for deps
- Volumes: `/var/lib/slonk-arb` (db + .env), `/var/log/slonk-arb`
- **Cron:** replace `/etc/cron.d/slonk-arb` with systemd timers on the host invoking
  `podman exec`. Schedule: hourly at `:30`, daily 07:30 / 08:00 / 15:00 / 20:00, Sunday 07:00 backup.
- **Delete `SCANNER_HOST = "karb.mathslug.com"`** from `gpu_droplet.py`. Once karb is behind
  Cloudflare that name resolves to an anycast edge IP, and `ensure_firewall()` would whitelist
  a *shared* Cloudflare address on port 11434 against an unauthenticated Ollama. `_caller_ip()`
  already discovers the real egress IP via ipify on every `create`, so the hostname lookup is
  redundant, not load-bearing.
- Migrate the 703MB SQLite db with the app stopped.

**AvaLong** — smallest, but two changes:
- Swap uWSGI FastCGI → gunicorn HTTP (the tunnel speaks HTTP; FastCGI was for OpenBSD `httpd`)
- **Single worker only.** Game state is a module-global `games` dict with `storage_uri="memory://"`
  rate limiting. Multiple workers would silently break games.
- There is a leftover `uwsgi.core` dump on the VM from 2026-07-23 — it has been crashing.

### 4. Cloudflare Tunnel

1. Add `mathslug.com` to Cloudflare, change nameservers at Namecheap (registrar stays Namecheap).
2. **Recreate every record in the `mathslug.com` zone first.** Only this zone moves —
   `bentleybuilding.com` and `timbentleymusic.com` are separate delegations and are unaffected.
   Within the zone that does move, the GitHub Pages records matter:
   `mathslug.com A 185.199.108-111.153` and `www.mathslug.com CNAME mathslug.github.io`.
   Cloudflare's scan usually catches these, but verify before flipping nameservers.
   - **Email will break unless handled.** The `MX eforward1/2/5.registrar-servers.com` records
     are Namecheap's free forwarding, which only works while Namecheap hosts the zone's DNS.
     Copying the MX records to Cloudflare does *not* preserve it. Replace with Cloudflare
     Email Routing (free), or drop the MX + SPF records if no `@mathslug.com` address is in use.
   - Set the GitHub Pages records to **DNS-only** (grey cloud), not proxied — Pages does its
     own TLS and proxying them causes redirect loops.
3. `cloudflared` on the Pi with ingress rules:
   `whorl.mathslug.com → localhost:3000`, `karb.mathslug.com → localhost:8000`,
   `avalong.mathslug.com → localhost:5000`
4. Free-plan limits that matter: 100MB max request body (whorl caps uploads at 15MB, fine).

### 5. Backups — Mac pulls from Pi

`launchd` job on the Mac, nightly `rsync` over SSH of `/srv/whorl-data` and `/var/lib/slonk-arb`
(~2GB total, against 182GB free). Pull rather than push — the Mac is the machine that sleeps.
This is what makes the SD card acceptable: a failure costs an afternoon, not data.

### 6. Monitoring

The Pi cannot report its own death, so this needs two halves:
- **On-box:** systemd timer checking RAM, disk, load, `vcgencmd measure_temp` and
  `vcgencmd get_throttled` (undervoltage detection — likely, given Wi-Fi and USB load) → ntfy.sh push
- **Off-box dead-man's switch:** healthchecks.io free tier. Pi pings on a schedule; missed ping
  alerts. This is the half that catches a dead Pi or a home internet outage.

*(ntfy chosen as a free default — swappable for email via the OpenBSD box's smtpd, or Gotify.)*

### 7. Decommission

Only after each app is verified serving through the tunnel:
- `doctl compute droplet delete slugclub slonk-arb` → **saves $144/yr**
- Cancel the OpenBSD vm08 renewal → **~€60/yr**
- Note: karb's ephemeral MI300X GPU droplets are billed separately at $1.99/hr and are
  unaffected by any of this.

---

## Known risks

- **Wi-Fi is the weakest link.** The single most likely cause of an outage. Ethernet is free if
  the Pi can reach the router.
- **SD card,** 5 years old, no SMART, fails without warning. Mitigated by step 5, not eliminated.
- **All three apps on one box behind one residential connection** — no redundancy. Acceptable for
  personal projects; worth stating plainly.
- **Secrets migration:** `.env` files for karb (Anthropic key, DO token, SMTP creds) must move
  out of band, not through git.

---

## Verification

1. `podman ps` — three containers running, restart-on-failure via Quadlet
2. `curl -sf localhost:3000/healthz` (whorl has a health endpoint; deploy.sh polls it 30×)
3. `curl -I https://whorl.mathslug.com` etc. — 200 through the tunnel, valid TLS
4. Exercise each app: post to whorl, load karb's dashboard, start an AvaLong game
5. Confirm karb's hourly `:30` timer fires and writes to the db
6. Run the Mac's rsync job manually, confirm data lands
7. Trigger a monitoring alert deliberately (fill a tmpfs) and confirm the push arrives
8. Stop the Pi's network; confirm the dead-man's switch fires
9. **Only then** destroy the droplets
