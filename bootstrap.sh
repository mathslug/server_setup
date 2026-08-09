#!/usr/bin/env bash
#
# bootstrap.sh — bring a fresh Raspberry Pi OS install to the state this
# project expects. Idempotent: safe to run repeatedly, and safe to run on a
# machine that is already half-configured.
#
# Run as a user with sudo (e.g. mathslug), ON the Pi or over ssh:
#     ssh mypi 'bash -s' < bootstrap.sh
#
# Assumes: Raspberry Pi OS / Debian 13 (trixie) or newer, arm64.
# On Debian 12 (bookworm) podman is 4.3, which has no Quadlet support — the
# script warns but continues, since everything else still applies.

set -euo pipefail

SERVICE_USER="podsvc"
SERVICE_UID_RANGE_START=165536
SERVICE_UID_RANGE_SIZE=65536
REBOOT_NEEDED=0

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

# ---------------------------------------------------------------------------
say "Preflight"
# ---------------------------------------------------------------------------
. /etc/os-release
ok "OS: ${PRETTY_NAME}"
ok "Kernel: $(uname -r)  Arch: $(dpkg --print-architecture)"

if [ "${VERSION_ID:-0}" -lt 13 ] 2>/dev/null; then
  ok "WARNING: Debian ${VERSION_ID} ships podman < 4.4, which has no Quadlet."
  ok "         Quadlet units in this repo will not work until you reach trixie."
fi

# ---------------------------------------------------------------------------
say "Removing desktop / peripheral services not wanted on a server"
# ---------------------------------------------------------------------------
# wayvnc in particular listens on 0.0.0.0:5900 on a stock desktop image.
PURGE=""
for p in realvnc-vnc-server wayvnc libneatvnc0 libvncclient1 \
         cups cups-browsed cups-daemon cups-common modemmanager; do
  dpkg -l "$p" 2>/dev/null | grep -q "^ii" && PURGE="$PURGE $p"
done
if [ -n "$PURGE" ]; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y purge $PURGE >/dev/null
  sudo DEBIAN_FRONTEND=noninteractive apt-get -y autoremove --purge >/dev/null
  ok "purged:$PURGE"
else
  ok "nothing to purge"
fi

for svc in bluetooth.service hciuart.service; do
  if systemctl is-enabled "$svc" >/dev/null 2>&1; then
    sudo systemctl disable --now "$svc" >/dev/null 2>&1 || true
    ok "disabled $svc"
  fi
done

# ---------------------------------------------------------------------------
say "Logging to RAM (SD card wear)"
# ---------------------------------------------------------------------------
# Journald is the dominant source of SD card writes (~1GB/day), so the journal
# lives in tmpfs. Logs do not survive a reboot.
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/00-volatile.conf >/dev/null <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=16M
EOF
if [ -d /var/log/journal ]; then
  sudo rm -rf /var/log/journal
  ok "removed persistent journal directory"
fi
sudo systemctl restart systemd-journald
ok "journald: Storage=volatile, capped at 64M"

# ---------------------------------------------------------------------------
say "Unattended security upgrades"
# ---------------------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install unattended-upgrades >/dev/null
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
sudo systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "enabled"

# ---------------------------------------------------------------------------
say "Memory cgroup controller"
# ---------------------------------------------------------------------------
# The Pi firmware prepends cgroup_disable=memory to the kernel command line — it
# is not in cmdline.txt. Without overriding it, container memory limits are
# silently ignored. A later parameter wins, so appending is sufficient.
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
if grep -q "cgroup_enable=memory" "$CMDLINE" 2>/dev/null; then
  ok "already present in $CMDLINE"
else
  sudo cp "$CMDLINE" "${CMDLINE}.bak.$(date +%Y%m%d%H%M%S)"
  # Append to the FIRST line only — cmdline.txt is a single logical line and
  # any parameter pushed onto a second line is silently ignored by the kernel.
  sudo sed -i '1 s/$/ cgroup_enable=memory cgroup_memory=1/' "$CMDLINE"
  ok "appended to $CMDLINE (backup alongside)"
fi
if ! grep -q memory /sys/fs/cgroup/cgroup.controllers; then
  REBOOT_NEEDED=1
  ok "NOT active in the running kernel — reboot required"
else
  ok "active: $(cat /sys/fs/cgroup/cgroup.controllers)"
fi

# ---------------------------------------------------------------------------
say "Podman (rootless)"
# ---------------------------------------------------------------------------
sudo DEBIAN_FRONTEND=noninteractive apt-get -y install \
  podman uidmap passt netavark aardvark-dns git >/dev/null
ok "podman $(podman --version | awk '{print $3}')"

# ---------------------------------------------------------------------------
say "Service account: ${SERVICE_USER}"
# ---------------------------------------------------------------------------
# No sudo, no password. Under rootless podman a container's uid 0 maps to this
# account, so a container escape lands on a user that cannot escalate.
if id "$SERVICE_USER" >/dev/null 2>&1; then
  ok "exists"
else
  sudo useradd --create-home --shell /bin/bash \
       --comment "Podman rootless service account" "$SERVICE_USER"
  ok "created"
fi
sudo passwd -l "$SERVICE_USER" >/dev/null 2>&1 || true

if ! grep -q "^${SERVICE_USER}:" /etc/subuid 2>/dev/null; then
  END=$((SERVICE_UID_RANGE_START + SERVICE_UID_RANGE_SIZE - 1))
  sudo usermod --add-subuids "${SERVICE_UID_RANGE_START}-${END}" \
               --add-subgids "${SERVICE_UID_RANGE_START}-${END}" "$SERVICE_USER"
fi
ok "subuid: $(grep "^${SERVICE_USER}:" /etc/subuid)"

# Without lingering, the user manager stops at logout and takes the containers
# with it — so nothing would come back after a power cut.
sudo loginctl enable-linger "$SERVICE_USER"
ok "linger: $(loginctl show-user "$SERVICE_USER" --property=Linger)"

SVC_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
sudo -u "$SERVICE_USER" mkdir -p \
  "${SVC_HOME}/.config/containers/systemd" \
  "${SVC_HOME}/apps" \
  "${SVC_HOME}/data"
ok "layout: ${SVC_HOME}/{apps,data,.config/containers/systemd}"

# Health-collector state: the backup receipt the Mac writes, and the job
# receipts the apps write. Must be under /var/lib rather than /run, which is
# tmpfs — a receipt there would vanish on reboot and read as "never backed up".
sudo install -d -m 0755 /var/lib/rpi-health
# Job receipts come from the apps' scheduled jobs, which run as the service
# account, so it must own this one.
sudo install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" /var/lib/rpi-health/jobs
ok "state: /var/lib/rpi-health (backup receipt, job receipts)"

# ---------------------------------------------------------------------------
say "SSH known_hosts for github.com"
# ---------------------------------------------------------------------------
# Deploy keys are NOT generated here — GitHub refuses the same public key on a
# second repository, so deploy-app.sh generates one per app. All this does is
# pin github.com, so the first clone does not block on a prompt nobody answers.
sudo -u "$SERVICE_USER" mkdir -p "${SVC_HOME}/.ssh"
sudo -u "$SERVICE_USER" chmod 700 "${SVC_HOME}/.ssh"
sudo -u "$SERVICE_USER" ssh-keyscan -H github.com 2>/dev/null \
  | sudo -u "$SERVICE_USER" tee -a "${SVC_HOME}/.ssh/known_hosts" >/dev/null
sudo -u "$SERVICE_USER" sort -u -o "${SVC_HOME}/.ssh/known_hosts" "${SVC_HOME}/.ssh/known_hosts"
ok "github.com pinned in ${SVC_HOME}/.ssh/known_hosts"

# ---------------------------------------------------------------------------
say "Done"
# ---------------------------------------------------------------------------
if [ "$REBOOT_NEEDED" = "1" ]; then
  echo "   REBOOT REQUIRED for the memory cgroup controller: sudo reboot"
else
  echo "   No reboot required."
fi
echo "   Next: ./deploy-app.sh <app>"
