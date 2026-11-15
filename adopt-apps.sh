#!/usr/bin/env bash
#
# adopt-apps.sh — make a new apps/<name>.conf take effect without anyone
# logging in. Run as root by rpi-selfupdate, after the tunnel config is
# rendered.
#
#     /opt/rpi/adopt-apps.sh
#
# For every configured app it does two things, both safe to repeat:
#
#   1. Enables autodeploy@<app>.timer. auto-deploy.sh then makes the FIRST
#      deploy as well as every later one, so pushing a conf is enough.
#   2. If the conf says DNS="auto", points the hostname at this tunnel.
#
# DNS is opt-in per app because a DNS record is what makes a hostname public.
# An app that must sit behind a Cloudflare Access policy leaves DNS unset, and
# its record is still created by hand, after the policy exists.
#
# One app's failure does not stop the others; the exit status reports it.

set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"

FAILED=0

# The tunnel is named by its credentials file, as in render-config.sh.
CRED=$(ls -1 /etc/cloudflared/*.json 2>/dev/null | head -1)
UUID=""
[ -n "$CRED" ] && UUID=$(basename "$CRED" .json)

for APP in $(appconf_list); do
  appconf_load "$APP" || { FAILED=1; continue; }

  if [ -f /etc/systemd/system/autodeploy@.timer ]; then
    if ! systemctl is-enabled --quiet "autodeploy@${APP}.timer" 2>/dev/null; then
      if systemctl enable --now "autodeploy@${APP}.timer" >/dev/null 2>&1; then
        echo "${APP}: enabled autodeploy@${APP}.timer"
      else
        echo "${APP}: could not enable autodeploy@${APP}.timer" >&2
        FAILED=1
      fi
    fi
  else
    echo "${APP}: autodeploy@.timer is not installed; run systemd/install-units.sh" >&2
    FAILED=1
  fi

  if [ "${DNS:-}" = "auto" ]; then
    if [ -z "$UUID" ]; then
      echo "${APP}: no tunnel credentials in /etc/cloudflared, so no DNS record" >&2
      FAILED=1
    # Says "already configured" and succeeds when the record already points
    # here. Without --overwrite-dns it refuses to replace a record that points
    # somewhere else, which is the behaviour wanted: that needs a person.
    elif OUT=$(TUNNEL_ORIGIN_CERT=/root/.cloudflared/cert.pem \
        cloudflared tunnel route dns "$UUID" "$HOSTNAME" 2>&1); then
      echo "${APP}: DNS ${HOSTNAME} — $(printf '%s' "$OUT" | tail -1)"
    else
      echo "${APP}: could not route ${HOSTNAME} to the tunnel:" >&2
      printf '%s\n' "$OUT" | tail -3 | sed 's/^/   /' >&2
      FAILED=1
    fi
  fi
done

exit "$FAILED"
