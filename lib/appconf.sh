# Shared accessors for apps/*.conf. Source this; don't execute it.
#
# The conf files are plain shell so they can be sourced directly and a
# multi-line ENV_TEMPLATE needs no escaping. Every consumer goes through here,
# so there is one definition of where an app's data and env file live.

SERVICE_USER="${SERVICE_USER:-podsvc}"

# The backup script sources this from macOS, which has no getent. The Pi's
# layout is fixed, so the fallback path is safe.
_svc_home() {
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$SERVICE_USER" | cut -d: -f6
  else
    printf '/home/%s' "$SERVICE_USER"
  fi
}

# Directory holding apps/*.conf, resolved relative to this file so it works
# from /opt/rpi, from a checkout, or from a script one level down.
appconf_dir() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  printf '%s/apps' "$here"
}

# Names of every configured app, one per line.
appconf_list() {
  local d; d="$(appconf_dir)"
  [ -d "$d" ] || return 0
  for f in "$d"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
}

# Load one app's config into the current shell and derive the paths every
# consumer needs, so nothing downstream reconstructs them by hand.
appconf_load() {
  local app="$1" f
  f="$(appconf_dir)/${app}.conf"
  [ -f "$f" ] || { echo "no config: $f" >&2; return 2; }
  # shellcheck disable=SC1090
  . "$f"

  APP="$app"
  SVC_HOME="$(_svc_home)"
  CHECKOUT="${SVC_HOME}/apps/${app}"

  # One deploy key per app, not one shared key. This is forced rather than
  # chosen: GitHub refuses to register the same public key as a deploy key on a
  # second repository, so a single key stops working the moment there are two
  # private repos. It is also the better arrangement: one app's key cannot read
  # another's source.
  #
  # GIT_SSH_COMMAND rather than a Host alias in ~/.ssh/config, so REPO stays a
  # real, copy-pasteable GitHub URL and there is no second file to keep in sync.
  DEPLOY_KEY="${SVC_HOME}/.ssh/id_ed25519_${app}"
  GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY} -o IdentitiesOnly=yes"
  DATA_DIR="${SVC_HOME}/data/${DATA_SUBDIR}"
  ENV_FILE="${SVC_HOME}/.config/${app}.env"
  HEALTH_URL="http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH}"
  PUBLIC_URL="https://${HOSTNAME}${HEALTH_PATH}"
}
