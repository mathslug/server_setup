#!/usr/bin/env bash
#
# install.sh — install cloudflared and point it at an existing tunnel.
#
#     sudo ./install.sh /path/to/credentials-dir
#
# The directory holds what backup/pull-backups.sh saves under host/cloudflared:
# config.yml, cert.pem, and <tunnel-uuid>.json. Those credentials are issued
# once by Cloudflare and never reissued, so this only ever copies them in — it
# cannot create them.
#
# Run on the Pi, or against a mounted image via chroot (provision-rescue.sh).
# cloudflared is not in Debian and its apt repo has no trixie suite, so the
# .deb comes from GitHub.

set -euo pipefail

SRC="${1:?usage: $0 <credentials-dir>}"
DEB_URL="${2:-https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb}"
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

die() { echo "cloudflared/install.sh: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"
[ -f "${SRC}/cert.pem" ] || die "no cert.pem in ${SRC}"
CRED=$(ls -1 "${SRC}"/*.json 2>/dev/null | head -1)
[ -n "$CRED" ] || die "no tunnel credentials (*.json) in ${SRC}"

if ! command -v cloudflared >/dev/null 2>&1; then
  curl -fsSL -o /tmp/cloudflared.deb "$DEB_URL"
  dpkg -i /tmp/cloudflared.deb >/dev/null
  rm -f /tmp/cloudflared.deb
fi

id cloudflared >/dev/null 2>&1 \
  || useradd --system --no-create-home --shell /usr/sbin/nologin cloudflared

install -d -m 0755 /etc/cloudflared /root/.cloudflared
install -m 0600 "${SRC}/cert.pem" /root/.cloudflared/cert.pem
install -o cloudflared -g cloudflared -m 0400 "$CRED" "/etc/cloudflared/$(basename "$CRED")"
[ -f "${SRC}/config.yml" ] && install -m 0644 "${SRC}/config.yml" /etc/cloudflared/config.yml

install -m 0644 "${HERE}/cloudflared.service" /etc/systemd/system/cloudflared.service

# Inside a mounted image there is no running systemd, and systemctl answers
# "Running in chroot, ignoring request" — which is a no-op, not an error, so
# the unit would silently never be enabled. Make the symlink by hand instead.
if [ -d /run/systemd/system ]; then
  systemctl daemon-reload
  systemctl enable --now cloudflared
  printf 'cloudflared: %s, tunnel %s\n' \
    "$(systemctl is-active cloudflared)" "$(basename "$CRED" .json)"
else
  install -d /etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/cloudflared.service \
         /etc/systemd/system/multi-user.target.wants/cloudflared.service
  printf 'cloudflared: enabled for next boot, tunnel %s\n' "$(basename "$CRED" .json)"
fi
