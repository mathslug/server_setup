#!/usr/bin/env bash
#
# bootstrap.sh — bring a fresh Raspberry Pi OS install to the state this
# project expects. Idempotent: safe to run repeatedly, and safe to run on a
# machine that is already half-configured.
#
# Run as a user with sudo (e.g. mathslug), ON the Pi or over ssh:
#     ssh mypi 'bash -s' < bootstrap.sh
#     ssh mypi 'bash -s -- --swap-mb 8192' < bootstrap.sh
#
# Swap and log persistence depend on what root is on: an SD card gets neither,
# because both trade card life for something this machine does not need. Pass
# --swap-mb to size the swapfile; the default leaves it alone.
#
# Assumes: Raspberry Pi OS / Debian 13 (trixie) or newer, arm64.
# On Debian 12 (bookworm) podman is 4.3, which has no Quadlet support — the
# script warns but continues, since everything else still applies.

set -euo pipefail

SERVICE_USER="podsvc"
SERVICE_UID_RANGE_START=165536
SERVICE_UID_RANGE_SIZE=65536
REBOOT_NEEDED=0
SWAP_MB=""
REPO_URL="https://github.com/mathslug/server_setup.git"
# Set rather than copied from the provisioning host: the images ship en_GB, so
# copying would propagate whatever the last rebuild happened to inherit.
LOCALE="en_US.UTF-8"

while [ $# -gt 0 ]; do
  case "$1" in
    --swap-mb)  SWAP_MB="${2:?--swap-mb needs a value}"; shift 2 ;;
    --repo-url) REPO_URL="${2:?--repo-url needs a value}"; shift 2 ;;
    --locale)   LOCALE="${2:?--locale needs a value}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Everything that trades away disk writes is conditioned on this.
case "$(findmnt -no SOURCE /)" in
  /dev/mmcblk*) ON_SD=1 ;;
  *)            ON_SD=0 ;;
esac

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

# A fresh image carries package lists from the day it was built, and the
# versions they name are gone from the mirrors, so the first install 404s.
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update
ok "package lists updated"

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
say "Journald"
# ---------------------------------------------------------------------------
# On an SD card journald is the dominant source of writes (~1GB/day) and the
# journal lives in tmpfs, so logs do not survive a reboot. Anywhere else, keep
# them: a post-mortem needs the logs from before the reboot that lost them.
sudo mkdir -p /etc/systemd/journald.conf.d
if [ "$ON_SD" = "1" ]; then
  sudo tee /etc/systemd/journald.conf.d/00-storage.conf >/dev/null <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=64M
RuntimeMaxFileSize=16M
EOF
  sudo rm -rf /var/log/journal
  ok "volatile, capped at 64M (root is on an SD card)"
else
  sudo tee /etc/systemd/journald.conf.d/00-storage.conf >/dev/null <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=2G
MaxRetentionSec=1month
EOF
  sudo rm -f /etc/systemd/journald.conf.d/00-volatile.conf
  sudo install -d -m 2755 -o root -g systemd-journal /var/log/journal
  ok "persistent, capped at 2G for a month"
fi
sudo systemctl restart systemd-journald

# ---------------------------------------------------------------------------
say "Swap"
# ---------------------------------------------------------------------------
# A safety valve, not a fix: this machine has never swapped a page. Sized past
# about one times RAM the return is not diminishing but zero — it would thrash
# into uselessness long before filling it. Never on an SD card.
if [ -z "$SWAP_MB" ]; then
  ok "unchanged (pass --swap-mb to set it)"
elif [ "$ON_SD" = "1" ]; then
  ok "SKIPPED: root is on an SD card"
else
  # Not on a Lite image, and it owns both the file and its regeneration, so it
  # is worth having rather than hand-rolling fallocate/mkswap/fstab.
  command -v dphys-swapfile >/dev/null 2>&1 \
    || sudo DEBIAN_FRONTEND=noninteractive apt-get -y install dphys-swapfile >/dev/null
  sudo sed -i "s/^#\?CONF_SWAPSIZE=.*/CONF_SWAPSIZE=${SWAP_MB}/" /etc/dphys-swapfile
  sudo sed -i "s/^#\?CONF_MAXSWAP=.*/CONF_MAXSWAP=${SWAP_MB}/" /etc/dphys-swapfile
  grep -q '^CONF_MAXSWAP=' /etc/dphys-swapfile \
    || echo "CONF_MAXSWAP=${SWAP_MB}" | sudo tee -a /etc/dphys-swapfile >/dev/null
  sudo dphys-swapfile swapoff >/dev/null 2>&1 || true
  sudo dphys-swapfile setup >/dev/null
  sudo dphys-swapfile swapon >/dev/null
  ok "$(free -h | awk '/^Swap:/{print $2}')"
fi

# ---------------------------------------------------------------------------
say "Locale"
# ---------------------------------------------------------------------------
if [ "$(. /etc/default/locale 2>/dev/null; echo "${LANG:-}")" = "$LOCALE" ]; then
  ok "$LOCALE"
else
  sudo sed -i "s/^# *\(${LOCALE}\)/\1/" /etc/locale.gen
  sudo locale-gen >/dev/null 2>&1
  sudo update-locale LANG="$LOCALE"
  ok "${LOCALE} (takes effect on the next login)"
fi

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

# The dashboard container bind-mounts /run/rpi-health/www, and /run is tmpfs.
# The collector creates it, but the dashboard may well start first — on a fresh
# disk the collector is not even installed yet — and a bind mount whose source
# is missing fails the unit. tmpfiles.d settles it on every boot, whoever wins.
sudo tee /etc/tmpfiles.d/rpi-health.conf >/dev/null <<'EOF'
d /run/rpi-health     0755 root root -
d /run/rpi-health/www 0755 root root -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/rpi-health.conf
ok "runtime: /run/rpi-health/www (recreated each boot)"

# ---------------------------------------------------------------------------
say "This repo, at /opt/rpi"
# ---------------------------------------------------------------------------
# Everything after this point runs from /opt/rpi — deploys, the tunnel config,
# the units. Cloning it here rather than by hand is what keeps a rebuild
# reproducible: a step performed once over ssh is a step that does not survive
# the next disk. Public, so no credential.
if [ -d /opt/rpi/.git ]; then
  ok "already present at $(sudo git -C /opt/rpi rev-parse --short HEAD)"
else
  sudo git clone -q "$REPO_URL" /opt/rpi
  ok "cloned $(sudo git -C /opt/rpi rev-parse --short HEAD) from ${REPO_URL}"
fi

# ---------------------------------------------------------------------------
say "Health dashboard"
# ---------------------------------------------------------------------------
# Platform furniture rather than an app, so deploy-app.sh does not install it.
# Until this existed it was placed by hand, which meant the collector kept
# writing pages after a rebuild and nothing served them.
SVC_UID=$(id -u "$SERVICE_USER")
sudo install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0644 \
  /opt/rpi/monitor/dashboard.container \
  "${SVC_HOME}/.config/containers/systemd/dashboard.container"
sudo -u "$SERVICE_USER" env HOME="$SVC_HOME" \
  XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
  systemctl --user daemon-reload

# Only start it once the memory cgroup is live. The unit sets --memory, and
# crun fails with "opening file memory.max: No such file or directory" when the
# controller is absent — which it is until the reboot enabled above. Lingering
# plus WantedBy=default.target brings it up on that reboot regardless.
if grep -q memory /sys/fs/cgroup/cgroup.controllers; then
  sudo -u "$SERVICE_USER" env HOME="$SVC_HOME" \
    XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
    systemctl --user start dashboard.service
  ok "dashboard: $(sudo -u "$SERVICE_USER" env XDG_RUNTIME_DIR="/run/user/${SVC_UID}" systemctl --user is-active dashboard.service)"
else
  ok "dashboard: installed; starts on the reboot the memory cgroup needs"
fi

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
