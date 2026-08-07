#!/usr/bin/env bash
#
# deploy-app.sh — clone or update an app, build its image, and start it under
# rootless podman + systemd.
#
#     /opt/rpi/deploy-app.sh whorl
#
# Idempotent. First run clones and starts; later runs pull, rebuild, restart.
# Application state under ~/data/<app> is never touched, so a redeploy cannot
# destroy anything that isn't in git.

set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: $0 <app>"; exit 2; }

# Run from somewhere every account can read. `sudo -u podsvc` inherits the
# caller's working directory, and podman refuses to start if it cannot chdir
# into it — which it can't, if you invoked this from the admin user's home.
cd /tmp

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck disable=SC1091
. "${HERE}/lib/appconf.sh"
appconf_load "$APP"

SVC_UID=$(id -u "$SERVICE_USER")

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

# XDG_RUNTIME_DIR is what makes `systemctl --user` and podman find the right
# socket; without it both fail in confusing ways.
asuser() {
  sudo -u "$SERVICE_USER" env \
    HOME="$SVC_HOME" \
    XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
    "$@"
}

# ---------------------------------------------------------------------------
say "Source: ${REPO}"
# ---------------------------------------------------------------------------
if sudo test -d "${CHECKOUT}/.git"; then
  asuser git -C "$CHECKOUT" fetch --quiet origin "$BRANCH"
  asuser git -C "$CHECKOUT" reset --quiet --hard "origin/${BRANCH}"
  ok "updated to $(asuser git -C "$CHECKOUT" rev-parse --short HEAD)"
else
  asuser git clone --quiet --branch "$BRANCH" "$REPO" "$CHECKOUT"
  ok "cloned at $(asuser git -C "$CHECKOUT" rev-parse --short HEAD)"
fi

# ---------------------------------------------------------------------------
say "State and configuration"
# ---------------------------------------------------------------------------
asuser mkdir -p "$DATA_DIR"
ok "data: ${DATA_DIR} ($(sudo du -sh "$DATA_DIR" 2>/dev/null | cut -f1)) — untouched by deploys"

if sudo test -f "$ENV_FILE"; then
  ok "env: ${ENV_FILE} (existing, left alone)"
else
  printf '%s\n' "$ENV_TEMPLATE" | asuser tee "$ENV_FILE" >/dev/null
  asuser chmod 600 "$ENV_FILE"
  ok "env: ${ENV_FILE} CREATED FROM TEMPLATE — edit it, real secrets are not in git"
fi

# ---------------------------------------------------------------------------
say "Build ${IMAGE}:latest"
# ---------------------------------------------------------------------------
# Built natively on the target so architecture-specific dependencies (sharp,
# better-sqlite3, esbuild) resolve for the host it will actually run on. This
# is also what makes moving an app to an x86 droplet a non-event.
asuser podman build --quiet -t "${IMAGE}:latest" "$CHECKOUT" >/dev/null
ok "built $(asuser podman image inspect "${IMAGE}:latest" --format '{{.Id}}' | cut -c1-12)"

# ---------------------------------------------------------------------------
say "Install unit and start"
# ---------------------------------------------------------------------------
asuser install -m 0644 "${CHECKOUT}/${QUADLET}" \
  "${SVC_HOME}/.config/containers/systemd/$(basename "$QUADLET")"
asuser systemctl --user daemon-reload
asuser systemctl --user restart "${SERVICE}.service"
ok "$(asuser systemctl --user is-active "${SERVICE}.service") — ${SERVICE}.service"

# ---------------------------------------------------------------------------
say "Health"
# ---------------------------------------------------------------------------
# Fail loudly rather than leaving a broken deploy looking successful.
for i in $(seq 1 30); do
  if curl -sf --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    ok "healthy after ${i}s — ${HEALTH_URL}"
    exit 0
  fi
  sleep 1
done

echo "   UNHEALTHY after 30s. Recent logs:"
asuser journalctl --user -u "${SERVICE}.service" -n 40 --no-pager | sed 's/^/     /'
exit 1
