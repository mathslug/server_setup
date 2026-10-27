#!/usr/bin/env python3
"""
Read SMART from every disk that has it and write a receipt the dashboard renders.

    sudo python3 /opt/rpi/monitor/check-disks.py

Run daily by rpi-disk-check.timer. Never wakes a sleeping disk (-n standby);
a disk asleep at check time keeps its previous reading.

Link health comes from the SATA phy event counters, which count CRC failures
between drive and adapter and reset at power-on, so a rise since the previous
check is what alarms. Attribute 199 is not used: on the boot SSD it is a
vendor-packed value that moves without meaning. Kernel I/O errors since the
previous check are counted too: the backup disk's failure on 2026-10-26 was on
the USB side, where SMART cannot see it.
"""

import json
import subprocess
import time
from pathlib import Path

RECEIPT = Path("/var/lib/rpi-health/disks.json")
# SATA phy event counters that are CRC failures on the drive's link.
PHY_CRC_IDS = (0x1, 0xF, 0x12)
TEMP_WARN_C = 60


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def disks():
    """Whole disks that can carry SMART: not SD cards, zram or loop devices."""
    tree = json.loads(run(["lsblk", "-J", "-o", "NAME,PATH,TYPE,TRAN,LABEL,MOUNTPOINTS"]))
    for d in tree["blockdevices"]:
        if d["type"] != "disk" or d["name"].startswith(("mmcblk", "zram", "loop", "ram")):
            continue
        parts = d.get("children") or []
        labels = {p.get("label") for p in parts}
        mounts = {m for p in parts for m in (p.get("mountpoints") or []) if m}
        name = ("Boot disk" if "/" in mounts
                else "Backup disk" if "pi-backup" in labels
                else d["name"])
        yield name, d["path"], d.get("tran")


def io_errors_since(dev, since):
    if not since:
        return 0
    log = run(["journalctl", "-k", "--since", f"@{since}", "--no-pager", "-o", "cat"])
    return sum(1 for line in log.splitlines() if f"I/O error, dev {dev.rsplit('/', 1)[1]}," in line)


def check(name, dev, tran, by_serial, by_name, since):
    cmd = ["smartctl", "-j", "-n", "standby", "-i", "-H", "-A", "-l", "sataphy", dev]
    if tran == "usb":
        cmd[2:2] = ["-d", "sat"]
    j = json.loads(run(cmd) or "{}")
    serial = j.get("serial_number")
    # Asleep, smartctl stops before reading the identity, so fall back to name.
    prev = by_serial.get(serial) or by_name.get(name)
    out = {"name": name, "serial": serial or (prev or {}).get("serial"), "model": j.get("model_name", "?")}

    if j.get("smartctl", {}).get("exit_status", 0) & 2 and "STANDBY" in json.dumps(j).upper():
        if prev:
            return prev | {"asleep": True}
        return out | {"state": "unknown", "value": "asleep", "detail": "asleep at check, not yet read"}
    if "smart_status" not in j:
        msgs = "; ".join(m["string"] for m in j.get("smartctl", {}).get("messages", []))[:120]
        return out | {"state": "warning", "value": "SMART unreadable",
                      "detail": msgs or "smartctl returned nothing — adapter back on UAS?"}

    table = j.get("ata_smart_attributes", {}).get("table", [])
    attrs = {a["id"]: a["raw"]["value"] for a in table}
    # 241 is GiB written on the SSD but LBAs on the HDD; show it only as GiB.
    gib = next((a["raw"]["value"] for a in table if a["id"] == 241 and "GiB" in a["name"]), None)
    phy = {p["id"]: p["value"] for p in j.get("sata_phy_event_counters", {}).get("table", [])}
    crc = sum(phy.get(i, 0) for i in PHY_CRC_IDS)
    prev_crc = (prev or {}).get("phy_crc")
    # The counters restart at power-on, so a lower value means a reset.
    crc_new = crc if prev_crc is None or crc < prev_crc else crc - prev_crc
    io = io_errors_since(dev, since)
    temp = (j.get("temperature") or {}).get("current")
    hours = (j.get("power_on_time") or {}).get("hours")

    problems, warnings = [], []
    if not j["smart_status"].get("passed", True):
        problems.append("SMART says FAILING")
    for aid, what in ((197, "pending"), (198, "unreadable")):
        if attrs.get(aid, 0) > 0:
            problems.append(f"{attrs[aid]} {what} sectors")
    if attrs.get(5, 0) > 0:
        warnings.append(f"{attrs[5]} reallocated sectors")
    if attrs.get(187, 0) > 0:
        warnings.append(f"{attrs[187]} uncorrectable errors reported")
    if 231 in attrs and attrs[231] < 10:
        warnings.append(f"{attrs[231]}% life left")
    if crc_new:
        warnings.append(f"{crc_new} new link CRC errors")
    if io:
        warnings.append(f"{io} kernel I/O errors since last check")
    if temp is not None and temp >= TEMP_WARN_C:
        warnings.append(f"{temp} °C")

    facts = [f"{temp} °C" if temp is not None else None,
             f"{hours:,} h on" if hours is not None else None,
             f"{attrs[231]}% life left" if 231 in attrs else None,
             f"{gib:,} GiB written" if gib is not None else None]
    detail = ", ".join(problems + warnings) or "no bad sectors or link errors"
    detail += " · " + " · ".join(f for f in facts if f)
    state = "critical" if problems else "warning" if warnings else "good"
    return out | {"state": state, "value": "FAILING" if problems else "needs a look" if warnings else "healthy",
                  "detail": f"{out['model']} — {detail}", "phy_crc": crc}


def main():
    try:
        old = json.loads(RECEIPT.read_text())
    except (OSError, ValueError):
        old = {}
    by_serial = {d.get("serial"): d for d in old.get("disks", []) if d.get("serial")}
    by_name = {d.get("name"): d for d in old.get("disks", [])}
    since = old.get("checked")
    seen = [check(name, dev, tran, by_serial, by_name, since) for name, dev, tran in disks()]
    RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    tmp = RECEIPT.with_suffix(".tmp")
    tmp.write_text(json.dumps({"checked": int(time.time()), "disks": seen}, indent=1))
    tmp.replace(RECEIPT)
    for r in seen:
        print(f"{r['name']}: {r['state']} — {r['value']} — {r['detail']}")


if __name__ == "__main__":
    main()
