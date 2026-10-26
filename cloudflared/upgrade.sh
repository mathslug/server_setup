#!/usr/bin/env bash
#
# upgrade.sh — bring cloudflared up to the latest GitHub release.
#
#     sudo /opt/rpi/cloudflared/upgrade.sh
#
# Run by rpi-selfupdate. install.sh only installs cloudflared when it is
# missing, and the .deb comes from GitHub rather than an apt repo, so nothing
# else ever upgrades it — the Pi sat on 2026.7.3 through Cloudflare's October
# 2026 advisory (compromised emSign intermediates, fixed in 2026.10.2).
#
# Restarting the tunnel drops every connection through it, ssh included, for a
# few seconds. It only happens when there is a new release.

set -euo pipefail

die() { echo "cloudflared/upgrade.sh: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run with sudo"

# /releases/latest redirects to /releases/tag/<version>; following it avoids
# the API and its rate limit.
LATEST=$(curl -fsSIL -o /dev/null -w '%{url_effective}' \
  https://github.com/cloudflare/cloudflared/releases/latest) \
  || die "could not reach GitHub — leaving the running version alone"
LATEST="${LATEST##*/}"
[[ "$LATEST" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+$ ]] || die "unexpected release tag '${LATEST}'"

INSTALLED=$(dpkg-query -W -f='${Version}' cloudflared 2>/dev/null || true)
if [ "$INSTALLED" = "$LATEST" ]; then
  echo "cloudflared up to date (${INSTALLED})"
  exit 0
fi

DEB=$(mktemp --suffix=.deb)
trap 'rm -f "$DEB"' EXIT
curl -fsSL -o "$DEB" \
  "https://github.com/cloudflare/cloudflared/releases/download/${LATEST}/cloudflared-linux-arm64.deb"
dpkg -i "$DEB" >/dev/null

# The running process keeps the old binary in memory, so if the new one rejects
# the config, not restarting leaves the tunnel — and the way back in — up.
if ! cloudflared tunnel ingress validate >/dev/null 2>&1; then
  echo "cloudflared ${LATEST} rejects the config — NOT restarting" >&2
  cloudflared tunnel ingress validate || true
  exit 1
fi
systemctl try-restart cloudflared
echo "cloudflared ${INSTALLED:-none} -> ${LATEST}, $(systemctl is-active cloudflared)"
