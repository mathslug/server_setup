#!/usr/bin/env bash
#
# deploy-app.sh — clone or update an app on the Pi, build its image, and start
# it under rootless podman + systemd.
#
#     ./deploy-app.sh whorl          # on the Pi
#     ssh mypi 'bash -s' -- whorl < deploy-app.sh   # ...or over ssh
#
# Idempotent. First run clones and starts; later runs pull, rebuild, restart.
# Application state under ~/data/<app> is never touched.
#
# Config comes from apps/<name>.conf, which is expected next to this script.
# When piping over ssh, the config is inlined by run.sh instead.

set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: $0 <app>"; exit 2; }

SERVICE_USER="podsvc"
SVC_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
SVC_UID=$(id -u "$SERVICE_USER")

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   %s\n' "$*"; }

# Run a command as the service account with a usable systemd user session.
# XDG_RUNTIME_DIR is what makes `systemctl --user` and podman find the right
# socket; without it both fail in confusing ways.
asuser() {
  sudo -u "$SERVICE_USER" env \
    HOME="$SVC_HOME" \
    XDG_RUNTIME_DIR="/run/user/${SVC_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${SVC_UID}/bus" \
    "$@"
}

CONF="$(dirname "$0")/apps/${APP}.conf"
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
elif [ -n "${REPO:-}" ]; then
  ok "using inlined config"
else
  echo "no config: $CONF"; exit 2
fi

CHECKOUT="${SVC_HOME}/apps/${APP}"
DATA_DIR="${SVC_HOME}/data/${DATA_SUBDIR}"
ENV_FILE="${SVC_HOME}/.config/${APP}.env"

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
# Built natively on the Pi so architecture-specific dependencies (sharp,
# better-sqlite3, esbuild) resolve to arm64 binaries.
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
