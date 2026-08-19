#!/usr/bin/env bash
# =============================================================================
# linkwatch - connectivity watchdog with ESCALATING recovery.
#
# The failure this exists to survive: a remote host loses its network, stays
# powered, and nobody can reach it or see why. Escalation is deliberate - each
# stage is more disruptive than the last, so cheap fixes are tried first and a
# reboot is opt-in rather than default.
#
# Stage 0  probe          every 60s, multiple targets, no DNS dependency
# Stage 1  NIC reset      after N failures: bounce carrier on down interfaces
# Stage 2  tailscale kick after M failures: restart tailscaled, re-up
# Stage 3  reboot         only if FAIL_BEFORE_REBOOT > 0. Default: never.
#
# Config: /etc/default/linkwatch
# Selftest: linkwatch --selftest   (runs one cycle verbosely, changes nothing)
# =============================================================================
set -uo pipefail

. /etc/default/linkwatch 2>/dev/null
PROBE_TARGETS="${PROBE_TARGETS:-1.1.1.1 8.8.8.8 9.9.9.9}"
FAIL_BEFORE_NIC_RESET="${FAIL_BEFORE_NIC_RESET:-3}"
FAIL_BEFORE_TS_RESTART="${FAIL_BEFORE_TS_RESTART:-5}"
FAIL_BEFORE_REBOOT="${FAIL_BEFORE_REBOOT:-0}"
INTERVAL="${INTERVAL:-60}"
SELFTEST=0
[ "${1:-}" = "--selftest" ] && SELFTEST=1

log(){ logger -t linkwatch "$*"; [ "$SELFTEST" = 1 ] && echo "   $*"; }

probe(){
  # Returns 0 if ANY target answers. Uses raw IPs so a broken resolver cannot
  # masquerade as a dead link - that misdiagnosis wastes hours.
  local t
  for t in $PROBE_TARGETS; do
    if ping -c1 -W2 "$t" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

probe_tailscale(){ tailscale status >/dev/null 2>&1; }

reset_nics(){
  # Bounce carrier on every physical interface that is not UP. Skips virtual
  # bridges and tailscale's own tun - resetting those is never the fix.
  local i
  for i in $(ls /sys/class/net); do
    case "$i" in lo|tailscale*|wg*|vmbr*|veth*|docker*|br-*) continue ;; esac
    [ -e "/sys/class/net/$i/device" ] || continue      # physical only
    if [ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" != "up" ]; then
      log "stage1: bouncing $i"
      ip link set "$i" down 2>/dev/null; sleep 2; ip link set "$i" up 2>/dev/null
    fi
  done
}

kick_tailscale(){
  log "stage2: restarting tailscaled"
  systemctl restart tailscaled 2>/dev/null
  sleep 5
  tailscale up --accept-dns=false --accept-routes=false >/dev/null 2>&1
}

beacon(){
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -s -m 10 -H "Title: [LINKWATCH] $(hostname)" -d "$1" \
    "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null 2>&1
}

if [ "$SELFTEST" = 1 ]; then
  echo "linkwatch selftest - no changes will be made"
  echo "   targets      : $PROBE_TARGETS"
  echo "   thresholds   : nic=$FAIL_BEFORE_NIC_RESET ts=$FAIL_BEFORE_TS_RESTART reboot=$FAIL_BEFORE_REBOOT"
  probe && echo "   internet     : REACHABLE" || echo "   internet     : DOWN"
  probe_tailscale && echo "   tailscale    : UP" || echo "   tailscale    : DOWN"
  echo "   physical nics:"
  for i in $(ls /sys/class/net); do
    case "$i" in lo|tailscale*|wg*|vmbr*|veth*|docker*|br-*) continue ;; esac
    [ -e "/sys/class/net/$i/device" ] || continue
    echo "     $i $(cat /sys/class/net/$i/operstate 2>/dev/null)"
  done
  echo "   beacon topic : ${NTFY_TOPIC:-<unset>}"
  exit 0
fi

fails=0
ts_fails=0
last_state="unknown"
log "started: targets='$PROBE_TARGETS' interval=${INTERVAL}s"

while true; do
  if probe; then
    if [ "$last_state" != "up" ]; then
      log "link RESTORED after $fails failed cycles"
      beacon "link restored after $((fails*INTERVAL))s down"
      last_state="up"
    fi
    fails=0
  else
    fails=$((fails+1))
    [ "$last_state" != "down" ] && { log "link DOWN"; last_state="down"; }
    log "failed cycle $fails"

    [ "$fails" -eq "$FAIL_BEFORE_NIC_RESET" ] && reset_nics
    [ "$fails" -eq "$FAIL_BEFORE_TS_RESTART" ] && kick_tailscale
    if [ "$FAIL_BEFORE_REBOOT" -gt 0 ] && [ "$fails" -ge "$FAIL_BEFORE_REBOOT" ]; then
      log "stage3: rebooting after $fails failed cycles"
      beacon "REBOOTING after $((fails*INTERVAL))s with no connectivity"
      sleep 2; systemctl reboot
    fi
  fi

  # Tailscale can be down while the internet is fine - treat it separately, or a
  # working WAN masks an unreachable host. That is exactly how a host goes dark
  # while looking healthy from its own console.
  if probe_tailscale; then ts_fails=0; else
    ts_fails=$((ts_fails+1))
    [ "$ts_fails" -eq "$FAIL_BEFORE_TS_RESTART" ] && kick_tailscale
  fi

  sleep "$INTERVAL"
done
