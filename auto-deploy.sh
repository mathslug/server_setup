#!/usr/bin/env bash
#
# auto-deploy.sh — redeploy an app if its branch has moved, or for an image
# app, if its unit in this repo differs from the one installed. A new app gets
# its first deploy here too.
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

# An app that has never been deployed here is deployed now, so that pushing
# apps/<name>.conf is all it takes to add one. The exception is a rebuilt
# machine, where EVERY app is undeployed and bootstrap.sh owns the order: it
# checks for existing data, deploys, then restores. Deploying an app from here
# first would start it with an empty database, and bootstrap.sh would then see
# data and skip the restore.
#
# The backup tells the two cases apart. An app that has been backed up but has
# no data directory on this disk is being rebuilt, so it is left for
# bootstrap.sh. (A data directory means a deploy was already attempted here,
# so this is not a fresh disk and retrying is safe.) If the backup disk cannot
# be read there is no way to tell, and the safe answer is to wait.
BACKUP_LATEST=/srv/backup/pi/latest
first_deploy() {
  if [ ! -d "$BACKUP_LATEST" ]; then
    echo "${APP}: not deployed, and ${BACKUP_LATEST} is not readable, so this cannot tell a new app from a rebuild — run deploy-app.sh"
    exit 0
  fi
  if [ -e "${BACKUP_LATEST}/${APP}/env" ] && [ ! -d "$DATA_DIR" ]; then
    echo "${APP}: not deployed, but it has a backup and no data here — leaving it for bootstrap.sh to deploy and restore"
    exit 0
  fi
  echo "${APP}: new app, first deploy"
  exec "${HERE}/deploy-app.sh" "$APP"
}

# An image app's version lives in its unit's Image= line, and this repo reaches
# /opt/rpi through rpi-selfupdate — so a bump lands within a day. A change only
# under UNITS_DIR is not compared; run deploy-app.sh for that.
if [ -z "${REPO:-}" ]; then
  INSTALLED="${SVC_HOME}/.config/containers/systemd/$(basename "$QUADLET")"
  if [ ! -f "$INSTALLED" ]; then
    first_deploy
  fi
  if cmp -s "${SOURCE_ROOT}/${QUADLET}" "$INSTALLED"; then
    echo "${APP}: up to date ($(sed -n 's/^Image=//p' "$INSTALLED"))"
    exit 0
  fi
  echo "${APP}: ${QUADLET} changed, deploying"
  exec "${HERE}/deploy-app.sh" "$APP"
fi

if [ ! -d "${CHECKOUT}/.git" ]; then
  first_deploy
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
