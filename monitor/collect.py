#!/usr/bin/env python3
"""
Sample the Pi's health, append to a rolling 24h history, and render a static
dashboard.

Run from a systemd timer every 5 minutes. Everything lives in /run (tmpfs), so
this writes nothing to the SD card — which matters, because 288 samples a day
of anything is exactly the kind of steady small write that wears a card out.

Outputs, all in /run/rpi-health:
    samples.tsv      rolling history, newest last, capped at 24h
    www/index.html   the dashboard
    summary.txt      plain text, for a future email or push notification

The dashboard is deliberately static HTML with no JavaScript and no external
requests: it must render on a phone on the LAN with no internet, and it must
keep working when the thing it is monitoring is the thing that is broken.
"""

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path("/run/rpi-health")
SAMPLES = ROOT / "samples.tsv"
WWW = ROOT / "www"

# Written by the Mac's pull-backups.sh after a successful run. Persistent
# rather than under /run, so a reboot is not mistaken for a missed backup.
BACKUP_STAMP = Path("/var/lib/rpi-health/last-backup")

# Backups are daily. One missed day is a laptop that stayed shut; three is a
# habit that has broken. The gap between those two numbers is deliberate —
# warning early enough to notice, critical late enough to mean something.
BACKUP_WARN_S = 30 * 3600
BACKUP_CRIT_S = 72 * 3600
INTERVAL_S = 300
WINDOW_S = 24 * 3600
HERE = Path(__file__).resolve().parent.parent


def apps():
    """Discover apps from apps/*.conf — the same source of truth the deploy and
    backup scripts use, so a new app appears on the dashboard automatically.

    The confs are shell, so they are read by sourcing them in a subshell rather
    than parsed here: that handles quoting and the multi-line ENV_TEMPLATE
    correctly instead of approximately.
    """
    out = []
    for conf in sorted((HERE / "apps").glob("*.conf")):
        name = conf.stem
        got = sh(
            f'. "{conf}"; printf "%s\\n%s\\n%s\\n%s\\n%s" '
            f'"$SERVICE" "$HOSTNAME" "$LOCAL_PORT" "$HEALTH_PATH" "$DATA_SUBDIR"'
        ).split("\n")
        if len(got) == 5 and got[0]:
            out.append({
                "name": name, "service": got[0], "host": got[1],
                "url": f"https://{got[1]}{got[3]}",
                "data_dir": f"/home/podsvc/data/{got[4]}",
            })
    return out

# Thresholds. Deliberately generous — a dashboard that cries wolf gets ignored.
LIMITS = {"disk": (80, 90), "mem": (85, 95), "temp": (70, 80), "load": (3.0, 6.0)}


def sh(cmd, timeout=15):
    try:
        return subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        ).stdout.strip()
    except Exception:
        return ""


def human_bytes(v):
    try:
        n = float(v)
    except (TypeError, ValueError):
        return "\u2014"
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return f"{n:.0f}{unit}" if unit in ("B", "KB") else f"{n:.1f}{unit}"
        n /= 1024


def backup_age():
    """Seconds since the Mac last completed a backup, or None if never.

    Deliberately inverted: the Pi reports on something it does not do and
    cannot control. The backup runs on the Mac, pulls over ssh, and writes this
    receipt at the end of a successful run — so a Mac that quietly stops
    backing up shows up here, on the page that actually gets looked at.

    Before this, a failed backup produced a line in a log file nobody opens and
    a non-zero exit code nobody queries. Which is to say: nothing.

    Persistent, not /run/rpi-health — a reboot must not read as "never backed
    up" and raise a false alarm.
    """
    try:
        return int(time.time()) - int(BACKUP_STAMP.read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def sample():
    du = shutil.disk_usage("/")
    disk = 100.0 * du.used / du.total

    mem_total = mem_avail = 0
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            mem_total = int(line.split()[1])
        elif line.startswith("MemAvailable:"):
            mem_avail = int(line.split()[1])
    mem = 100.0 * (mem_total - mem_avail) / mem_total if mem_total else 0.0

    load = float(Path("/proc/loadavg").read_text().split()[0])
    uptime = float(Path("/proc/uptime").read_text().split()[0])

    temp_raw = sh("vcgencmd measure_temp")           # temp=44.8'C
    try:
        temp = float(temp_raw.split("=")[1].split("'")[0])
    except Exception:
        # Vanilla Debian has no vcgencmd; the thermal zone always exists.
        try:
            temp = int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000
        except Exception:
            temp = 0.0

    # Non-zero means undervoltage or thermal throttling, now or since boot.
    # The single most common way a Pi misbehaves, and invisible without this.
    throttled = sh("vcgencmd get_throttled").replace("throttled=", "") or "0x0"

    tunnel = sh("systemctl is-active cloudflared")

    # Per app: is its unit up, and does its PUBLIC url answer? Fetching the
    # public url exercises DNS -> Cloudflare -> tunnel -> app; a purely local
    # check would call a silently dead tunnel healthy.
    # One podman stats call for every container, rather than one per app:
    # each invocation samples over a short interval, so per-app calls would
    # multiply the collector's own runtime by the number of apps.
    stats = {}
    raw = sh(
        "sudo -u podsvc env XDG_RUNTIME_DIR=/run/user/1001 "
        "podman stats --no-stream --format "
        "'{{.Name}}\t{{.CPU}}\t{{.MemUsage}}\t{{.MemPerc}}'"
    )
    def pct(v):
        # podman emits CPU as a bare float with full precision
        # ("0.9897660795695922"), which is unreadable in a UI.
        v = v.strip().rstrip("%")
        try:
            return f"{float(v):.1f}%"
        except ValueError:
            return "\u2014"

    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) == 4:
            stats[parts[0]] = {
                "cpu": pct(parts[1]),
                "mem": parts[2].split("/")[0].strip(),
                "mem_pct": pct(parts[3]),
            }

    app_state = {}
    for a in apps():
        unit = sh(
            "sudo -u podsvc env XDG_RUNTIME_DIR=/run/user/1001 "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus "
            f"systemctl --user is-active {a['service']}.service"
        )
        code = sh(
            f"curl -s -o /dev/null -w '%{{http_code}}' --max-time 10 {a['url']}"
        )
        st = stats.get(a["service"], {})
        # Disk here means the app's persistent state, not its image: images are
        # layered and largely shared, while the data directory is what actually
        # grows — and is the number worth watching once karb lands with a 703MB
        # database on a 32GB card.
        disk_b = sh(f"du -sb {a['data_dir']} 2>/dev/null | cut -f1")
        app_state[a["name"]] = {
            "unit": unit or "unknown",
            "http": code or "000",
            "cpu": st.get("cpu", "—"),
            "mem": st.get("mem", "—"),
            "mem_pct": st.get("mem_pct", "—"),
            "disk": human_bytes(disk_b),
        }

    return {
        "t": int(time.time()),
        "disk": round(disk, 1),
        "mem": round(mem, 1),
        "load": round(load, 2),
        "temp": round(temp, 1),
        "throttled": throttled,
        "tunnel": tunnel or "unknown",
        "apps": app_state,
        "backup_age": backup_age(),
        "uptime": int(uptime),
        "mem_mb": round((mem_total - mem_avail) / 1024),
        "mem_total_mb": round(mem_total / 1024),
        "disk_free_gb": round(du.free / 1e9, 1),
    }


def load_history():
    if not SAMPLES.exists():
        return []
    cutoff = time.time() - WINDOW_S
    out = []
    for line in SAMPLES.read_text(encoding="utf-8").splitlines():
        try:
            row = json.loads(line)
            if row["t"] >= cutoff:
                out.append(row)
        except Exception:
            continue
    return out


def state(metric, value):
    warn, crit = LIMITS[metric]
    return "critical" if value >= crit else "warning" if value >= warn else "good"


def human_dt(seconds):
    d, r = divmod(int(seconds), 86400)
    h, r = divmod(r, 3600)
    m = r // 60
    if d:
        return f"{d}d {h}h"
    if h:
        return f"{h}h {m}m"
    return f"{m}m"


def spark(values, w=150, h=32):
    """Inline SVG sparkline. Single series, so it takes the sequential hue."""
    if len(values) < 2:
        return '<svg class="spark" viewBox="0 0 150 32" role="img" aria-hidden="true"></svg>'
    lo, hi = min(values), max(values)
    span = (hi - lo) or 1.0
    step = w / (len(values) - 1)
    pts = " ".join(
        f"{i*step:.1f},{h - 3 - ((v - lo) / span) * (h - 6):.1f}"
        for i, v in enumerate(values)
    )
    last_x, last_y = pts.split()[-1].split(",")
    return (
        f'<svg class="spark" viewBox="0 0 {w} {h}" preserveAspectRatio="none" '
        f'role="img" aria-hidden="true">'
        f'<polyline points="{pts}" fill="none" stroke="var(--series-1)" '
        f'stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>'
        f'<circle cx="{last_x}" cy="{last_y}" r="2.5" fill="var(--series-1)"/></svg>'
    )


# Status colours are the reserved status palette, never the series hues, and
# every one ships with an icon AND a label so colour never carries meaning alone.
ICON = {"good": "●", "warning": "▲", "critical": "■", "unknown": "?"}


def tile(label, value, unit, sub, st, values):
    return f"""    <div class="tile">
      <div class="tile-label">{label}</div>
      <div class="tile-value">{value}<span class="unit">{unit}</span></div>
      <div class="tile-sub"><span class="dot {st}">{ICON[st]}</span> {sub}</div>
      {spark(values)}
    </div>"""


def row(label, ok, detail, st):
    return f"""      <tr>
        <th scope="row">{label}</th>
        <td><span class="dot {st}">{ICON[st]}</span> <span class="state">{ok}</span></td>
        <td class="muted">{detail}</td>
      </tr>"""


def render(cur, hist):
    age = int(time.time() - cur["t"])
    checks = [
        state("disk", cur["disk"]),
        state("mem", cur["mem"]),
        state("temp", cur["temp"]),
        state("load", cur["load"]),
        "good" if cur["tunnel"] == "active" else "critical",
        "good" if cur["throttled"] == "0x0" else "warning",
    ] + [
        "good" if (a["unit"] == "active" and a["http"] == "200") else "critical"
        for a in cur.get("apps", {}).values()
    ] + [
        # A stale backup counts toward the headline. A row nobody scrolls to is
        # only marginally better than a log nobody opens.
        "good" if (cur.get("backup_age") is not None
                   and cur["backup_age"] < BACKUP_WARN_S)
        else "warning" if (cur.get("backup_age") is not None
                           and cur["backup_age"] < BACKUP_CRIT_S)
        else "critical"
    ]
    overall = (
        "critical" if "critical" in checks
        else "warning" if "warning" in checks
        else "good"
    )
    headline = {"good": "All systems normal", "warning": "Needs attention",
                "critical": "Something is wrong"}[overall]

    # Data age is the dashboard's own failure mode: a stale page that looks
    # green is worse than no page. So it is stated in the headline, and goes
    # critical on its own if the collector has stopped.
    stale = "good" if age < 900 else "critical"

    def series(k):
        return [r[k] for r in hist][-72:]

    tiles = "\n".join([
        tile("Disk", f"{cur['disk']:.0f}", "%", f"{cur['disk_free_gb']} GB free",
             state("disk", cur["disk"]), series("disk")),
        tile("Memory", f"{cur['mem']:.0f}", "%",
             f"{cur['mem_mb']} / {cur['mem_total_mb']} MB",
             state("mem", cur["mem"]), series("mem")),
        tile("Temperature", f"{cur['temp']:.0f}", "°C",
             "throttled" if cur["throttled"] != "0x0" else "no throttling",
             state("temp", cur["temp"]), series("temp")),
        tile("Load", f"{cur['load']:.2f}", "", "4 cores",
             state("load", cur["load"]), series("load")),
    ])

    app_rows = []
    for name, a in sorted(cur.get("apps", {}).items()):
        st = "good" if (a["unit"] == "active" and a["http"] == "200") else "critical"
        usage = (f"{a.get('cpu','—')} CPU · "
                 f"{a.get('mem','—')} RAM ({a.get('mem_pct','—')} of cap) · "
                 f"{a.get('disk','—')} disk")
        app_rows.append(row(name, f"{a['unit']} · HTTP {a['http']}", usage, st))

    # NOT `age` — that name is already the dashboard's own data age above, and
    # the HTML template below renders "Updated {human_dt(age)} ago" from it.
    # Shadowing it here made the page report the backup's age as its own
    # freshness: a stale-looking page that was in fact seconds old, which is
    # the exact class of confidently-wrong signal this row exists to prevent.
    bk_age = cur.get("backup_age")
    if bk_age is None:
        bk_val, bk_st = "never", "critical"
        bk_detail = "no completed backup recorded — check backups/backup.log on the Mac"
    else:
        bk_val = f"{human_dt(bk_age)} ago"
        bk_st = ("good" if bk_age < BACKUP_WARN_S
                 else "warning" if bk_age < BACKUP_CRIT_S else "critical")
        bk_detail = "daily 06:00 pull to the Mac; needs the LAN or a live Access session"

    rows = "\n".join(app_rows + [
        row("Last backup", bk_val, bk_detail, bk_st),
        row("cloudflared", cur["tunnel"], "tunnel", "good" if cur["tunnel"] == "active" else "critical"),
        row("Power / thermal", cur["throttled"],
            "0x0 is healthy; anything else means undervoltage or throttling",
            "good" if cur["throttled"] == "0x0" else "warning"),
        row("Uptime", human_dt(cur["uptime"]), "since last boot", "good"),
    ])

    # "all apps answered" per sample, so the figure stays meaningful as apps
    # are added rather than silently tracking only the first one.
    #
    # Samples with no apps recorded are UNJUDGEABLE, not failures — they are
    # left out of both halves of the ratio. Counting them as failures meant a
    # schema change invented four outages that never happened and reported
    # 50% uptime on a service that had not missed a check. A monitor that
    # cries wolf about itself is worse than no monitor.
    judged = [r for r in hist if (r.get("apps") or {})]
    ok_http = sum(
        1 for r in judged if all(v.get("http") == "200" for v in r["apps"].values())
    )
    n = len(judged)
    pct = (100.0 * ok_http / n) if n else 100.0

    return f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>mypi — health</title>
<style>
  :root {{
    color-scheme: light;
    --surface-1:#fcfcfb; --plane:#f9f9f7;
    --text-primary:#0b0b0b; --text-secondary:#52514e; --muted:#898781;
    --grid:#e1e0d9; --border:rgba(11,11,11,0.10);
    --series-1:#2a78d6;
    --good:#0ca30c; --warning:#fab219; --critical:#d03b3b;
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      color-scheme: dark;
      --surface-1:#1a1a19; --plane:#0d0d0d;
      --text-primary:#ffffff; --text-secondary:#c3c2b7; --muted:#898781;
      --grid:#2c2c2a; --border:rgba(255,255,255,0.10);
      --series-1:#3987e5;
    }}
  }}
  * {{ box-sizing:border-box; }}
  body {{
    margin:0; padding:24px 16px 48px;
    background:var(--plane); color:var(--text-primary);
    font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;
  }}
  .wrap {{ max-width:760px; margin:0 auto; }}
  header {{ margin-bottom:20px; }}
  h1 {{ font-size:15px; font-weight:600; margin:0 0 12px; color:var(--text-secondary); }}
  .headline {{ font-size:30px; font-weight:600; letter-spacing:-0.02em; margin:0; }}
  .age {{ margin-top:6px; font-size:14px; color:var(--text-secondary); }}
  .age.critical {{ color:var(--critical); font-weight:600; }}
  .grid {{
    display:grid; grid-template-columns:repeat(auto-fit,minmax(160px,1fr));
    gap:12px; margin:20px 0;
  }}
  .tile {{
    background:var(--surface-1); border:1px solid var(--border);
    border-radius:10px; padding:14px 14px 8px;
  }}
  .tile-label {{ font-size:13px; color:var(--text-secondary); }}
  .tile-value {{ font-size:32px; font-weight:600; letter-spacing:-0.02em; margin:2px 0 0; }}
  .unit {{ font-size:16px; font-weight:400; color:var(--muted); margin-left:2px; }}
  .tile-sub {{ font-size:13px; color:var(--text-secondary); margin-bottom:4px; }}
  .spark {{ width:100%; height:32px; display:block; }}
  .dot {{ font-size:11px; vertical-align:1px; }}
  .dot.good {{ color:var(--good); }}
  .dot.warning {{ color:var(--warning); }}
  .dot.critical {{ color:var(--critical); }}
  .dot.unknown {{ color:var(--muted); }}
  table {{
    width:100%; border-collapse:collapse; background:var(--surface-1);
    border:1px solid var(--border); border-radius:10px; overflow:hidden;
  }}
  th,td {{ text-align:left; padding:11px 14px; font-size:14px;
           border-bottom:1px solid var(--grid); font-weight:400; }}
  tr:last-child th, tr:last-child td {{ border-bottom:none; }}
  th[scope=row] {{ color:var(--text-secondary); width:36%; }}
  .state {{ font-variant-numeric:tabular-nums; }}
  .muted {{ color:var(--muted); font-size:13px; }}
  footer {{ margin-top:18px; font-size:13px; color:var(--muted); }}
</style>
</head><body><div class="wrap">
<header>
  <h1>mypi</h1>
  <p class="headline"><span class="dot {overall}">{ICON[overall]}</span> {headline}</p>
  <p class="age {stale}">Updated {human_dt(age)} ago
    {'— COLLECTOR MAY HAVE STOPPED' if stale != 'good' else ''}</p>
</header>

<div class="grid">
{tiles}
</div>

<table>
  <caption class="visually-hidden"></caption>
  <tbody>
{rows}
  </tbody>
</table>

<footer>
  All public URLs healthy on {ok_http} of {n} checks in the last 24h ({pct:.0f}%).
  Sampled every {INTERVAL_S // 60} minutes.
</footer>
</div></body></html>
"""


def summary(cur, hist):
    """Plain text, so switching to email or a push notification is a small change."""
    # Same rule as the dashboard: unjudgeable samples leave the ratio entirely
    # rather than counting against it.
    judged = [r for r in hist if (r.get("apps") or {})]
    ok = sum(
        1 for r in judged if all(v.get("http") == "200" for v in r["apps"].values())
    )
    total = len(judged)
    return "\n".join([
        f"mypi health — {time.strftime('%Y-%m-%d %H:%M')}",
        f"  disk    {cur['disk']}% ({cur['disk_free_gb']} GB free)",
        f"  memory  {cur['mem']}% ({cur['mem_mb']}/{cur['mem_total_mb']} MB)",
        f"  temp    {cur['temp']}C   throttled={cur['throttled']}",
        f"  load    {cur['load']}",
        *[f"  {n:<7} {a['unit']}, HTTP {a['http']}, "
          f"{a.get('cpu','—')} cpu, {a.get('mem','—')} ram, {a.get('disk','—')} disk"
          for n, a in sorted(cur.get("apps", {}).items())],
        f"  tunnel  {cur['tunnel']}",
        f"  backup  {human_dt(cur['backup_age']) + ' ago' if cur.get('backup_age') is not None else 'NEVER'}",
        f"  uptime24 {ok}/{total} samples all-green",
        f"  uptime  {human_dt(cur['uptime'])}",
    ]) + "\n"


def main():
    WWW.mkdir(parents=True, exist_ok=True)
    cur = sample()

    with SAMPLES.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(cur) + "\n")

    hist = load_history()
    SAMPLES.write_text("".join(json.dumps(r) + "\n" for r in hist), encoding="utf-8")

    # Write via a temp file and rename: a reader mid-refresh gets the old page
    # whole rather than half of the new one.
    tmp = WWW / ".index.html.tmp"
    tmp.write_text(render(cur, hist), encoding="utf-8")
    os.replace(tmp, WWW / "index.html")
    (ROOT / "summary.txt").write_text(summary(cur, hist), encoding="utf-8")


if __name__ == "__main__":
    main()
