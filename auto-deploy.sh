#!/usr/bin/env bash
#
# auto-deploy.sh — redeploy an app if its branch has moved.
#
# Run from a systemd timer. Cheap by design: the common case is a single
# `git ls-remote` (one SSH round trip, no objects transferred, nothing written
# to disk) followed by an exit. A rebuild only happens when the remote SHA
# differs from what is actually deployed.
#
# GitHub Actions cannot reach this machine — the Cloudflare tunnel only carries
# inbound traffic for the apps, and nothing else connects in. Polling is the
# idiomatic answer for a host behind NAT, rather than exposing a webhook.
#
#     /opt/rpi/auto-deploy.sh whorl

set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: $0 <app>"; exit 2; }

cd /tmp   # sudo -u inherits the caller's cwd; podman fails if it can't chdir

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"
appconf_load "$APP"

if [ ! -d "${CHECKOUT}/.git" ]; then
  echo "${APP}: not deployed yet (${CHECKOUT} missing) — run deploy-app.sh first"
  exit 0
fi

asuser() {
  sudo -u "$SERVICE_USER" env \
    HOME="$SVC_HOME" GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$@"
}

DEPLOYED=$(asuser git -C "$CHECKOUT" rev-parse HEAD)
REMOTE=$(asuser git -C "$CHECKOUT" ls-remote origin "refs/heads/${BRANCH}" | cut -f1)

if [ -z "$REMOTE" ]; then
  echo "${APP}: could not reach origin — leaving the running version alone"
  exit 1
fi

if [ "$DEPLOYED" = "$REMOTE" ]; then
  echo "${APP}: up to date (${DEPLOYED:0:7})"
  exit 0
fi

echo "${APP}: ${DEPLOYED:0:7} -> ${REMOTE:0:7}, deploying"
exec "${HERE}/deploy-app.sh" "$APP"
