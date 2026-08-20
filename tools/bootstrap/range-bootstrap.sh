#!/usr/bin/env bash
# =============================================================================
# range-bootstrap.sh - stand up a remote build host that STAYS reachable.
#
# *** OFFLINE-FIRST BY DESIGN ***
# This installer does NOT expect to download anything. Every artifact must be
# staged in a directory beside this script (default ./offline/). That is the whole
# point: on a restricted network the download endpoints are precisely what is
# blocked, so an installer that fetches at run time fails on site, with no egress
# and nobody to fix it.
#
# Downloading is a LAST RESORT, only attempted when --allow-download is passed.
# Without that flag a missing artifact is a hard error naming exactly what is
# missing and how to obtain it.
#
# STAGE THE BUNDLE BEFOREHAND, on a network that works:
#   mkdir -p offline && cd offline
#   apt-get download tailscale wireguard-tools jq ethtool git
#   curl -fsSLO https://deb.nodesource.com/setup_22.x        # or: apt-get download nodejs
#   npm pack @anthropic-ai/claude-code                        # -> claude-code-<ver>.tgz
#   # optional, enables the wg-over-TLS rung:
#   curl -fsSL -o wstunnel.tar.gz https://github.com/erebe/wstunnel/releases/latest/download/wstunnel_linux_amd64.tar.gz
#
# Installs: Tailscale, WireGuard, Node + Claude Code, claude-connect launcher,
#           linkwatch watchdog, phone-home beacon, netladder egress prober.
#
# WHY THIS SHAPE - a real outage on 2026-08-19:
#   A remote build host lost its lab NIC three times in one day. Tailscale went
#   flat-dead (Online:False, LastHandshake never, rx 0) at an exact hour boundary.
#   With one path there was no way in AND no way to see why.
#
# Targets: Debian 12/13, Ubuntu 22.04/24.04, Proxmox VE 8.4/9.x host, LXC or VM.
#
# Usage:
#   sudo ./range-bootstrap.sh --check
#   sudo TS_AUTHKEY=tskey-auth-xxx HOME_TS_IP=100.x.y.z ./range-bootstrap.sh
#   sudo ./range-bootstrap.sh --allow-download          # permit network fetches
#
# Idempotent: safe to re-run.
# =============================================================================
set -uo pipefail

CHECK_ONLY=0
ALLOW_DL=0
WG_CONF=""
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname)}"
HOME_TS_IP="${HOME_TS_IP:-}"
HOME_PROXY_PORT="${HOME_PROXY_PORT:-3128}"
HOME_PUBLIC="${HOME_PUBLIC:-}"
CUSTOM_DERP="${CUSTOM_DERP:-}"
LOG=/var/log/range-bootstrap.log
HERE="$(cd "$(dirname "$0")" && pwd)"
OFFLINE_DIR="${OFFLINE_DIR:-$HERE/offline}"

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    --allow-download) ALLOW_DL=1; shift ;;
    --offline-dir) OFFLINE_DIR="$2"; shift 2 ;;
    --with-wireguard) WG_CONF="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1"; exit 2 ;;
  esac
done

say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG"; }
have(){ command -v "$1" >/dev/null 2>&1; }
run(){ if [ "$CHECK_ONLY" = 1 ]; then echo "   WOULD RUN: $*"; else "$@"; fi; }
MISSING=""
need_artifact(){ MISSING="$MISSING\n     $1 - $2"; }
# Return the first matching staged artifact, or empty.
staged(){ ls "$OFFLINE_DIR"/$1 2>/dev/null | head -1; }

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
touch "$LOG" 2>/dev/null

say "=== range-bootstrap starting (check=$CHECK_ONLY allow_download=$ALLOW_DL) ==="
. /etc/os-release 2>/dev/null || true
say "host=$(hostname) os=${PRETTY_NAME:-unknown} kernel=$(uname -r)"

# --- 0. Proxmox VE detection and guards --------------------------------------
# Installing onto a HYPERVISOR is different: mistakes take down every guest.
IS_PVE=0
if have pveversion; then
  IS_PVE=1
  say "PROXMOX VE DETECTED: $(pveversion 2>/dev/null | head -1)"
  say "  base: ${PRETTY_NAME:-unknown} (${VERSION_CODENAME:-unknown})"
  # PVE 8.x = Debian 12 bookworm, PVE 9.x = Debian 13 trixie. Staged .deb files
  # must match the codename or dpkg will refuse them.

  # TRAP: the enterprise repo ships enabled and 401s without a subscription, so
  # `apt-get update` returns non-zero on a perfectly healthy host. Unhandled,
  # that reads as a broken network.
  if grep -rqs '^deb.*enterprise\.proxmox\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    if grep -rqs 'pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
      say "  note: enterprise repo will 401 (expected). no-subscription repo present."
      say "        A non-zero apt-get update here is NOT a network fault."
    else
      say "  WARN: enterprise repo enabled and NO no-subscription repo. apt installs will fail."
      say "        Add: deb http://download.proxmox.com/debian/pve ${VERSION_CODENAME} pve-no-subscription"
    fi
  fi
  # TRAP: PVE spiceproxy already owns *:3128 - never bind a local proxy there.
  ss -ltn 2>/dev/null | grep -q ':3128' && \
    say "  note: :3128 already in use here (PVE spiceproxy). Do not bind a local proxy to it."
  say "  guard: watchdog auto-reboot stays DISABLED on a hypervisor."
fi

# --- 0b. offline bundle inventory --------------------------------------------
say "--- offline bundle"
if [ -d "$OFFLINE_DIR" ]; then
  say "bundle: $OFFLINE_DIR"
  ls -1 "$OFFLINE_DIR" 2>/dev/null | sed 's/^/     /' | head -12
else
  if [ "$ALLOW_DL" = 1 ]; then
    say "no bundle at $OFFLINE_DIR - downloads permitted, will fetch as needed"
  else
    say "ERROR: no offline bundle at $OFFLINE_DIR and downloads are not permitted."
    say "       Stage the artifacts there (see the header of this script) or pass --allow-download."
    exit 3
  fi
fi

# --- 1. base packages --------------------------------------------------------
say "--- base packages"
NEED=""
for p in curl jq git ethtool wireguard-tools iproute2 ca-certificates; do
  dpkg -s "$p" >/dev/null 2>&1 || NEED="$NEED $p"
done
if [ -z "$NEED" ]; then
  say "base packages already present"
else
  say "missing:$NEED"
  LOCAL_DEBS=$(ls "$OFFLINE_DIR"/*.deb 2>/dev/null | tr '\n' ' ')
  if [ -n "$LOCAL_DEBS" ]; then
    say "installing staged .deb files from the bundle"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $LOCAL_DEBS
  elif [ "$ALLOW_DL" = 1 ]; then
    run env DEBIAN_FRONTEND=noninteractive apt-get update -qq
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $NEED
  else
    need_artifact "*.deb" "apt-get download$NEED"
  fi
fi

# --- 2. Tailscale ------------------------------------------------------------
say "--- tailscale"
if have tailscale; then
  say "present: $(tailscale version 2>/dev/null | head -1)"
else
  TSDEB=$(staged 'tailscale*.deb')
  if [ -n "$TSDEB" ]; then
    say "installing from bundle: $(basename "$TSDEB")"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$TSDEB"
  elif [ "$ALLOW_DL" = 1 ]; then
    say "downloading tailscale installer"
    run bash -c 'curl -fsSL https://tailscale.com/install.sh | sh'
  else
    need_artifact "tailscale*.deb" "apt-get download tailscale"
  fi
fi
if [ "$CHECK_ONLY" = 0 ] && have tailscale; then
  systemctl enable --now tailscaled >/dev/null 2>&1
  if tailscale status >/dev/null 2>&1; then
    say "tailscale up as $(tailscale ip -4 2>/dev/null | head -1)"
  elif [ -n "$TS_AUTHKEY" ]; then
    # --accept-dns=false: never let tailscale rewrite resolv.conf on a range host;
    # it fights the internal resolver and looks like broken DNS.
    tailscale up --authkey "$TS_AUTHKEY" --hostname "$TS_HOSTNAME" \
      --accept-dns=false --accept-routes=false >/dev/null 2>&1 && \
      say "tailscale up as $(tailscale ip -4 2>/dev/null | head -1)" || \
      say "WARN: tailscale up failed - check the auth key"
  else
    say "WARN: no TS_AUTHKEY and not logged in. Run: tailscale up"
  fi
fi

# --- 3. WireGuard (second path; UDP-only, so it dies on strict perimeters) ----
say "--- wireguard"
if [ -n "$WG_CONF" ] && [ -f "$WG_CONF" ]; then
  run install -m 600 "$WG_CONF" /etc/wireguard/wg0.conf
  run systemctl enable --now wg-quick@wg0
  say "configured from $WG_CONF"
elif [ -f /etc/wireguard/wg0.conf ]; then
  say "already configured"
else
  WGC=$(staged '*.conf')
  if [ -n "$WGC" ]; then
    say "installing tunnel from bundle: $(basename "$WGC")"
    run install -m 600 "$WGC" /etc/wireguard/wg0.conf
    run systemctl enable --now wg-quick@wg0
  else
    say "no profile supplied - SKIPPED (WireGuard is UDP-only and will not survive a strict perimeter anyway)"
  fi
fi

# --- 4. Node.js + Claude Code ------------------------------------------------
say "--- node + claude code"
if ! have node; then
  NODEDEB=$(staged 'nodejs*.deb')
  NODETGZ=$(staged 'node-v*-linux-x64.tar.xz')
  if [ -n "$NODEDEB" ]; then
    say "installing node from bundle: $(basename "$NODEDEB")"
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$NODEDEB"
  elif [ -n "$NODETGZ" ]; then
    say "unpacking node tarball: $(basename "$NODETGZ")"
    run tar -xJf "$NODETGZ" -C /usr/local --strip-components=1
  elif [ "$ALLOW_DL" = 1 ]; then
    say "downloading Node.js 22 (NodeSource)"
    run bash -c 'curl -fsSL https://deb.nodesource.com/setup_22.x | bash -'
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs
  else
    need_artifact "nodejs*.deb OR node-v*-linux-x64.tar.xz" "apt-get download nodejs"
  fi
else
  say "node present: $(node -v 2>/dev/null)"
fi

if have claude; then
  say "claude present: $(claude --version 2>/dev/null | head -1)"
else
  CCTGZ=$(staged 'claude-code-*.tgz')
  if [ -n "$CCTGZ" ]; then
    say "installing claude from bundle: $(basename "$CCTGZ")"
    run npm install -g "$CCTGZ"
  elif [ "$ALLOW_DL" = 1 ]; then
    say "installing latest @anthropic-ai/claude-code from npm"
    run npm install -g @anthropic-ai/claude-code@latest
  else
    need_artifact "claude-code-*.tgz" "npm pack @anthropic-ai/claude-code"
  fi
fi

# Bypass permissions preset: an unattended session must not block on approval
# prompts nobody is present to answer. Only written when absent, so an existing
# operator policy is never overwritten.
if [ "$CHECK_ONLY" = 0 ]; then
  for H in /root $(getent passwd 1000 2>/dev/null | cut -d: -f6); do
    [ -d "$H" ] || continue
    mkdir -p "$H/.claude"
    if [ ! -f "$H/.claude/settings.json" ]; then
      printf '{ "permissions": { "defaultMode": "bypassPermissions" } }\n' > "$H/.claude/settings.json"
      say "bypassPermissions preset for $H"
    fi
  done
fi

# --- 5. helper scripts -------------------------------------------------------
say "--- helpers"
for s in linkwatch.sh netladder.sh claude-connect; do
  n=$(basename "$s" .sh)
  if [ -f "$HERE/$s" ]; then
    run install -m 755 "$HERE/$s" "/usr/local/bin/$n"
    say "installed /usr/local/bin/$n"
  else
    say "WARN: $s not found beside this script"
  fi
done
WSTUN=$(staged 'wstunnel*')
if [ -n "${WSTUN:-}" ] && [ "$CHECK_ONLY" = 0 ]; then
  case "$WSTUN" in
    *.tar.gz) tar -xzf "$WSTUN" -C /tmp wstunnel 2>/dev/null && install -m 755 /tmp/wstunnel /usr/local/bin/wstunnel ;;
    *) install -m 755 "$WSTUN" /usr/local/bin/wstunnel 2>/dev/null ;;
  esac
  have wstunnel && say "wstunnel installed"
fi

# --- 6. configuration -------------------------------------------------------
if [ "$CHECK_ONLY" = 0 ]; then
  cat > /etc/default/netladder <<EOF
# Written by range-bootstrap.
HOME_TS_IP=$HOME_TS_IP
HOME_PROXY_PORT=$HOME_PROXY_PORT
HOME_PUBLIC=$HOME_PUBLIC
SSH443_PORT=443
CUSTOM_DERP=$CUSTOM_DERP
NTFY_URL=$NTFY_URL
NTFY_TOPIC=$NTFY_TOPIC
TIMEOUT=8
EOF
  cat > /etc/default/linkwatch <<EOF
NTFY_URL=$NTFY_URL
NTFY_TOPIC=$NTFY_TOPIC
PROBE_TARGETS="1.1.1.1 8.8.8.8 9.9.9.9"
FAIL_BEFORE_NIC_RESET=3
FAIL_BEFORE_TS_RESTART=5
# 0 = never auto-reboot. On a HYPERVISOR leave this at 0 permanently: rebooting
# to fix the host's own connectivity takes every guest down with it.
FAIL_BEFORE_REBOOT=0
EOF
  say "wrote /etc/default/{netladder,linkwatch}"

  # linkwatch service
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
  # netladder timer - jittered, because a fixed cadence is the primary C2
  # beaconing indicator and this tool must not look like malware.
  cat > /etc/systemd/system/netladder.service <<'EOF'
[Unit]
Description=Probe egress paths and pivot to the best one
After=network-online.target tailscaled.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/netladder
EOF
  cat > /etc/systemd/system/netladder.timer <<'EOF'
[Unit]
Description=Re-probe egress paths (jittered)
[Timer]
OnBootSec=3min
OnUnitActiveSec=30min
RandomizedDelaySec=900
AccuracySec=60
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now linkwatch >/dev/null 2>&1 && say "linkwatch running"
  systemctl enable --now netladder.timer >/dev/null 2>&1 && say "netladder.timer enabled (30m +/-15m)"
fi

# --- 7. report ---------------------------------------------------------------
say "=== summary ==="
printf '   %-16s %s\n' "tailscale"      "$(have tailscale && (tailscale status >/dev/null 2>&1 && echo "UP $(tailscale ip -4 2>/dev/null|head -1)" || echo "installed, not up") || echo MISSING)"
printf '   %-16s %s\n' "wireguard"      "$([ -f /etc/wireguard/wg0.conf ] && echo configured || echo 'not configured')"
printf '   %-16s %s\n' "node"           "$(have node && node -v || echo MISSING)"
printf '   %-16s %s\n' "claude"         "$(have claude && claude --version 2>/dev/null | head -1 || echo MISSING)"
printf '   %-16s %s\n' "claude-connect" "$(have claude-connect && echo installed || echo MISSING)"
printf '   %-16s %s\n' "netladder"      "$(have netladder && echo installed || echo MISSING)"
printf '   %-16s %s\n' "linkwatch"      "$(systemctl is-active linkwatch 2>/dev/null || echo inactive)"

if [ -n "$MISSING" ]; then
  say ""
  say "MISSING ARTIFACTS - stage these in $OFFLINE_DIR then re-run:"
  printf "%b\n" "$MISSING"
  say "(or re-run with --allow-download to fetch them, if this network permits it)"
  exit 4
fi

say ""
say "NEXT: launch Claude with 'claude-connect', NOT bare 'claude'."
say "      Claude reads HTTPS_PROXY at process start, so the launcher picks and"
say "      VERIFIES the working route each time and clears stale settings."
say "      Check the current decision with: claude-connect --route"
say "=== done ==="
