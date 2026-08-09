#!/usr/bin/env bash
#
# install-units.sh — sync systemd/*.{service,timer} from this repo into
# /etc/systemd/system and reload.
#
#     sudo /opt/rpi/systemd/install-units.sh
#
# These are SYSTEM units, run as root: the self-update, the health collector,
# and the per-app auto-deploy. (An app's own units are user units owned by the
# service account, installed by deploy-app.sh from the app's repo.)
#
# Without this /opt/rpi tracks git and /etc/systemd/system does not, so a
# changed unit is pulled and then silently ignored.
#
# Run from rpi-selfupdate.service itself, which is safe despite appearances:
# this only writes files and reloads. systemd keeps executing the already-loaded
# version of a running unit, so rewriting its own unit finishes under the old
# definition and the new one takes effect next run.

set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
DEST=/etc/systemd/system
CHANGED=0

for SRC in "${HERE}"/*.service "${HERE}"/*.timer; do
  [ -e "$SRC" ] || continue
  NAME="$(basename "$SRC")"
  if ! cmp -s "$SRC" "${DEST}/${NAME}"; then
    install -m 0644 "$SRC" "${DEST}/${NAME}"
    echo "installed ${NAME}"
    CHANGED=1
  fi
done

if [ "$CHANGED" = "1" ]; then
  systemctl daemon-reload
  echo "daemon-reload"

  # Re-enable already-enabled timers so a changed [Install] section takes
  # effect. Does NOT enable anything new — that is part of deploying an app.
  for T in "${HERE}"/*.timer; do
    [ -e "$T" ] || continue
    NAME="$(basename "$T")"
    case "$NAME" in *@*) continue ;; esac   # templates are enabled per instance
    if systemctl is-enabled --quiet "$NAME" 2>/dev/null; then
      systemctl reenable --quiet "$NAME"
    fi
  done
else
  echo "units already in sync"
fi
