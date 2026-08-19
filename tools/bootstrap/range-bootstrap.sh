#!/usr/bin/env bash
# =============================================================================
# range-bootstrap.sh - stand up a remote build host that STAYS reachable.
#
# Installs, in dependency order:
#   1. base tooling (curl, jq, git, wireguard-tools, ethtool)
#   2. Tailscale          - primary path. Outbound-only, traverses CGNAT via DERP.
#   3. WireGuard          - SECOND, independent path to the home network.
#   4. Node.js + Claude Code
#   5. linkwatch          - connectivity watchdog with escalating recovery
#   6. phone-home         - ntfy heartbeat, works when SSH does not
#
# WHY THIS SHAPE - learned the hard way on 2026-08-19:
#   A remote build host lost its lab NIC three times in one day. Tailscale went
#   flat-dead (Online:False, LastHandshake never, rx 0) at an exact hour boundary.
#   With one path there was no way in AND no way to see why. Every design choice
#   below exists to prevent one of those two failures.
#
# Targets: Debian 12/13, Ubuntu 22.04/24.04, Proxmox VE 8/9 host, or an LXC/VM.
# Windows: see README.md - the same design, different installers.
#
# Usage:
#   sudo ./range-bootstrap.sh --check                 # report state, change nothing
#   sudo TS_AUTHKEY=tskey-auth-xxxx ./range-bootstrap.sh
#   sudo TS_AUTHKEY=... NTFY_TOPIC=mytopic ./range-bootstrap.sh --with-wireguard /path/wg0.conf
#
# Idempotent: safe to re-run. Every step checks before acting.
# =============================================================================
set -uo pipefail

CHECK_ONLY=0
WG_CONF=""
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
LOG=/var/log/range-bootstrap.log

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --with-wireguard) WG_CONF="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
have(){ command -v "$1" >/dev/null 2>&1; }
run(){ if [ "$CHECK_ONLY" = 1 ]; then echo "   WOULD RUN: $*"; else "$@"; fi; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
touch "$LOG" 2>/dev/null

say "=== range-bootstrap starting (check_only=$CHECK_ONLY) ==="
. /etc/os-release 2>/dev/null || true
say "host=$(hostname) os=${PRETTY_NAME:-unknown} kernel=$(uname -r)"

# --- 1. base tooling ---------------------------------------------------------
say "--- base packages"
NEED=""
for p in curl jq git ethtool wireguard-tools iproute2 ca-certificates; do
  dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"
done
if [ -n "$NEED" ]; then
  say "installing:$NEED"
  run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $NEED
else
  say "base packages already present"
fi

# --- 2. Tailscale - primary path --------------------------------------------
say "--- tailscale"
if have tailscale; then
  say "tailscale present: $(tailscale version 2>/dev/null | head -1)"
else
  say "installing tailscale from upstream"
  run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
fi
if [ "$CHECK_ONLY" = 0 ]; then
  systemctl enable --now tailscaled >/dev/null 2>&1
  if tailscale status >/dev/null 2>&1; then
    say "tailscale already up as: $(tailscale ip -4 2>/dev/null | head -1)"
  elif [ -n "$TS_AUTHKEY" ]; then
    # --accept-dns=false: do NOT let tailscale rewrite resolv.conf on a range host,
    # it will fight your internal resolver. Learned on the reference build.
    tailscale up --authkey "$TS_AUTHKEY" --hostname "$TS_HOSTNAME" \
      --accept-dns=false --accept-routes=false && \
      say "tailscale up as $(tailscale ip -4 2>/dev/null | head -1)"
  else
    say "WARN: no TS_AUTHKEY given and tailscale not logged in - run 'tailscale up' manually"
  fi
fi

# --- 3. WireGuard - second, independent path --------------------------------
say "--- wireguard (second path)"
if [ -n "$WG_CONF" ] && [ -f "$WG_CONF" ]; then
  run install -m 600 "$WG_CONF" /etc/wireguard/wg0.conf
  run systemctl enable --now wg-quick@wg0
  say "wireguard configured from $WG_CONF"
elif [ -f /etc/wireguard/wg0.conf ]; then
  say "wireguard already configured"
  run systemctl enable --now wg-quick@wg0
else
  say "no wireguard profile supplied - SKIPPED (pass --with-wireguard <file>)"
  say "  NOTE: a second path is the whole point. Add one when you have the profile."
fi

# --- 4. Node.js + Claude Code ------------------------------------------------
say "--- claude code"
if have claude; then
  say "claude present: $(claude --version 2>/dev/null | head -1)"
else
  if ! have node || [ "$(node -v 2>/dev/null | tr -d 'v' | cut -d. -f1)" -lt 18 ] 2>/dev/null; then
    say "installing Node.js 22 (NodeSource)"
    run bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  fi
  say "installing @anthropic-ai/claude-code"
  run npm install -g @anthropic-ai/claude-code
fi

# --- 5. linkwatch - the watchdog --------------------------------------------
say "--- linkwatch watchdog"
if [ "$CHECK_ONLY" = 0 ]; then
  install -m 755 "$(dirname "$0")/linkwatch.sh" /usr/local/bin/linkwatch 2>/dev/null || \
    say "WARN: linkwatch.sh not found beside this script - copy it manually"

  cat > /etc/default/linkwatch <<EOF
# Written by range-bootstrap. Edit freely.
NTFY_URL=$NTFY_URL
NTFY_TOPIC=$NTFY_TOPIC
# Space-separated probe targets. Use addresses that do NOT depend on your DNS.
PROBE_TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
# How many consecutive failed cycles before escalating each stage.
FAIL_BEFORE_NIC_RESET=3
FAIL_BEFORE_TS_RESTART=5
FAIL_BEFORE_REBOOT=0        # 0 = never auto-reboot. Set e.g. 30 to enable.
EOF

  cat > /etc/systemd/system/linkwatch.service <<'EOF'
[Unit]
Description=Connectivity watchdog with escalating recovery
After=network-online.target tailscaled.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/linkwatch
ExecStart=/usr/local/bin/linkwatch
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now linkwatch >/dev/null 2>&1 && say "linkwatch enabled"
fi

# --- 6. phone-home heartbeat -------------------------------------------------
say "--- phone-home heartbeat"
if [ -n "$NTFY_TOPIC" ] && [ "$CHECK_ONLY" = 0 ]; then
  cat > /usr/local/bin/phone-home <<'EOF'
#!/usr/bin/env bash
# Outbound-only status beacon. Survives when SSH does not, because it only needs
# egress. Deliberately NOT a command channel - see README for why.
. /etc/default/linkwatch 2>/dev/null
H=$(hostname)
TS=$(tailscale ip -4 2>/dev/null | head -1)
TSUP=$(tailscale status >/dev/null 2>&1 && echo up || echo DOWN)
WG=$(wg show 2>/dev/null | head -1 | awk '{print $2}')
UP=$(uptime -p 2>/dev/null)
DEF=$(ip route show default 2>/dev/null | head -2 | tr '\n' ';')
LINKS=$(ip -br link 2>/dev/null | awk '$2=="UP"{printf "%s ",$1}')
curl -s -H "Title: [BEACON] $H" -d \
"host=$H
uptime=$UP
tailscale=$TSUP ip=${TS:-none}
wireguard=${WG:-none}
default_routes=$DEF
links_up=$LINKS" "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null
EOF
  chmod 755 /usr/local/bin/phone-home
  cat > /etc/systemd/system/phone-home.service <<'EOF'
[Unit]
Description=Outbound status beacon
[Service]
Type=oneshot
EnvironmentFile=-/etc/default/linkwatch
ExecStart=/usr/local/bin/phone-home
EOF
  cat > /etc/systemd/system/phone-home.timer <<'EOF'
[Unit]
Description=Send status beacon every 15 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now phone-home.timer >/dev/null 2>&1 && say "phone-home enabled (every 15m)"
  /usr/local/bin/phone-home && say "test beacon sent"
else
  [ -z "$NTFY_TOPIC" ] && say "no NTFY_TOPIC set - beacon SKIPPED"
fi

# --- summary -----------------------------------------------------------------
say "=== summary ==="
printf '   %-14s %s\n' "tailscale" "$(have tailscale && (tailscale status >/dev/null 2>&1 && echo "UP $(tailscale ip -4 2>/dev/null|head -1)" || echo "installed, not up") || echo MISSING)"
printf '   %-14s %s\n' "wireguard" "$([ -f /etc/wireguard/wg0.conf ] && systemctl is-active wg-quick@wg0 2>/dev/null || echo 'not configured')"
printf '   %-14s %s\n' "claude" "$(have claude && claude --version 2>/dev/null | head -1 || echo MISSING)"
printf '   %-14s %s\n' "linkwatch" "$(systemctl is-active linkwatch 2>/dev/null || echo inactive)"
printf '   %-14s %s\n' "phone-home" "$(systemctl is-active phone-home.timer 2>/dev/null || echo inactive)"
say "=== done. Verify with: linkwatch --selftest ==="
