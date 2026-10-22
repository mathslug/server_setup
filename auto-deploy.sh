#!/usr/bin/env bash
#
# auto-deploy.sh — redeploy an app if its branch has moved, or for an image
# app, if its unit in this repo differs from the one installed.
#
# Run from a systemd timer. The common case is one `git ls-remote` and an exit;
# a rebuild only happens when the remote SHA differs from what is deployed.
#
# Polled rather than pushed because nothing can reach this machine from outside
# — the tunnel carries inbound traffic for the apps and nothing else.
#
#     /opt/rpi/auto-deploy.sh <app>

set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: $0 <app>"; exit 2; }

cd /tmp   # sudo -u inherits the caller's cwd; podman fails if it can't chdir

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"
appconf_load "$APP"

# An image app's version lives in its unit's Image= line, and this repo reaches
# /opt/rpi through rpi-selfupdate — so a bump lands within a day. A change only
# under UNITS_DIR is not compared; run deploy-app.sh for that.
if [ -z "${REPO:-}" ]; then
  INSTALLED="${SVC_HOME}/.config/containers/systemd/$(basename "$QUADLET")"
  if [ ! -f "$INSTALLED" ]; then
    echo "${APP}: not deployed yet (${INSTALLED} missing) — run deploy-app.sh first"
    exit 0
  fi
  if cmp -s "${SOURCE_ROOT}/${QUADLET}" "$INSTALLED"; then
    echo "${APP}: up to date ($(sed -n 's/^Image=//p' "$INSTALLED"))"
    exit 0
  fi
  echo "${APP}: ${QUADLET} changed, deploying"
  exec "${HERE}/deploy-app.sh" "$APP"
fi

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
