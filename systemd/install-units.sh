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
# This exists because the units were originally copied into place by hand and
# then never again. /opt/rpi tracked git, /etc/systemd/system did not, and the
# two drifted silently: rpi-selfupdate.service gained a third ExecStart that
# regenerates the tunnel ingress, the installed copy kept running with two, and
# the symptom was a new app never appearing in the tunnel config — with no
# error anywhere, because the machine was faithfully running the old unit it
# had been given.
#
# Run from rpi-selfupdate.service itself, which is safe in the way it looks
# like it should not be: this only writes files and reloads. systemd keeps
# executing the already-loaded version of the running unit, so a self-update
# that rewrites its own unit finishes under the old definition and the new one
# takes effect on the next run.

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

  # Re-enable timers that are already enabled, so a changed [Install] section
  # takes effect. Deliberately does NOT enable anything new — turning on a
  # timer nobody asked for is worse than leaving it off, and the enable is
  # part of deploying an app, not of syncing units.
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
