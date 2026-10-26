# Reaching the Pi from the laptop. Source this; the caller defines log and
# fail. pick_pi sets PI: PI_HOST if given, else the LAN, else the tunnel.

# `timeout`, not just ConnectTimeout: with an expired Access login
# `cloudflared access ssh` blocks on a browser login nobody answers.
#
# Each failure logs ssh's own last line. A run once failed on the tunnel in
# under a second without reaching the Pi, and with the error discarded there
# was nothing to say why.
try_host() {
  local err rc
  err=$(timeout 30 ssh -o ConnectTimeout=10 -o BatchMode=yes "$1" true 2>&1) && return 0
  rc=$?
  [ "$rc" = 124 ] && err="no answer in 30s"
  log "  ${1}: $(printf '%s' "$err" | tail -1)"
  return 1
}

pick_pi() {
  PI="${PI_HOST:-}"
  if [ -n "$PI" ]; then
    try_host "$PI" || fail "cannot reach ${PI} over ssh"
    return 0
  fi
  # Three rounds: one dropped tunnel handshake should not cost a run.
  local round candidate
  for round in 1 2 3; do
    for candidate in mypi mypi-remote; do
      if try_host "$candidate"; then PI="$candidate"; return 0; fi
    done
    [ "$round" = 3 ] || sleep 20
  done
  # Off the LAN, the usual cause is the 30-day Access login lapsing.
  fail "cannot reach the Pi on the LAN (mypi) or the tunnel (mypi-remote) — if the Access login expired, \`ssh mypi-remote true\` renews it"
}
