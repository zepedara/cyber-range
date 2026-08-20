#!/usr/bin/env bash
# =============================================================================
# range-setup.sh - THE single entry point. Run this one script.
#
# Walks the whole sequence, GATED: each phase must pass before the next starts,
# because a half-installed host on a restricted network is worse than no host.
#
#   PHASE 1  preflight    root, offline bundle present, disk space
#   PHASE 2  install      every tool, each VERIFIED before moving on   <- GATE
#   PHASE 3  discover     find every working path out to home
#   PHASE 4  measure      rank the working paths by latency + throughput
#   PHASE 5  pin route    select the best, prove Anthropic is reachable  <- GATE
#   PHASE 6  auth         confirm the subscription credential is valid   <- GATE
#   PHASE 7  launch       start Claude in bypass mode on the pinned route
#
# NOTHING IS DOWNLOADED. Every artifact must already be in ./offline/ beside this
# script. On a restricted network the download endpoints are exactly what is
# blocked, so a fetch-at-runtime installer fails on site with no way to recover.
#
# TARGET: Debian 12/13, Ubuntu, or a Proxmox VE 8.4/9.x host (incl. the C240 M4).
#
# Usage:
#   sudo ./range-setup.sh                    full gated run, ends by launching Claude
#   sudo ./range-setup.sh --check            verify readiness, change nothing
#   sudo ./range-setup.sh --no-launch        do everything except start Claude
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OFFLINE_DIR="${OFFLINE_DIR:-$HERE/offline}"
CHECK=0; NOLAUNCH=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --no-launch) NOLAUNCH=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
  esac
done

RED=''; GRN=''; YEL=''; RST=''
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'; fi
phase(){ printf '\n=== PHASE %s ===\n' "$*"; }
ok(){   printf '  %s[ OK ]%s %s\n' "$GRN" "$RST" "$*"; }
bad(){  printf '  %s[FAIL]%s %s\n' "$RED" "$RST" "$*"; }
warn(){ printf '  %s[WARN]%s %s\n' "$YEL" "$RST" "$*"; }
note(){ printf '         %s\n' "$*"; }
die(){  printf '\n%sGATE FAILED:%s %s\n' "$RED" "$RST" "$*"; printf 'Fix this before continuing - it is not recoverable on site.\n'; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
staged(){ ls "$OFFLINE_DIR"/$1 2>/dev/null | head -1; }

# =============================================================================
phase "1 - PREFLIGHT"
# =============================================================================
[ "$(id -u)" -eq 0 ] || die "must run as root (sudo ./range-setup.sh)"
ok "running as root"

. /etc/os-release 2>/dev/null || true
note "host: $(hostname)   os: ${PRETTY_NAME:-unknown}   kernel: $(uname -r)"

IS_PVE=0
if have pveversion; then
  IS_PVE=1
  ok "Proxmox VE detected: $(pveversion 2>/dev/null | head -1)"
  # PVE 8.4 = bookworm, PVE 9.x = trixie. Staged .debs must match or dpkg refuses.
  note "Debian base: ${VERSION_CODENAME:-unknown} - staged .deb files must match this"
  if grep -rqs 'enterprise\.proxmox\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
     && ! grep -rqs 'pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    warn "enterprise repo enabled with no no-subscription repo - apt installs will 401"
    note "this does not matter if every artifact is staged, which is the intent"
  fi
fi

[ -d "$OFFLINE_DIR" ] || die "no offline bundle at $OFFLINE_DIR
  Everything must be pre-staged. Build it at home with:
    ./make-offline-bundle.sh ${VERSION_CODENAME:-bookworm}
  then copy the whole directory across."
ok "offline bundle present: $OFFLINE_DIR"
ls -1 "$OFFLINE_DIR" 2>/dev/null | sed 's/^/         /' | head -12

FREE_MB=$(df -Pm / | awk 'NR==2{print $4}')
[ "${FREE_MB:-0}" -gt 800 ] && ok "disk space: ${FREE_MB}MB free" || die "only ${FREE_MB}MB free on / - need ~800MB"

# =============================================================================
phase "2 - INSTALL (gated: every tool verified before proceeding)"
# =============================================================================
apt_local(){ # install a staged .deb, no network
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-download --fix-broken "$@" >/dev/null 2>&1 || \
  DEBIAN_FRONTEND=noninteractive dpkg -i "$@" >/dev/null 2>&1
}

# --- base utilities ---
MISSING_BASE=""
for c in curl jq; do have "$c" || MISSING_BASE="$MISSING_BASE $c"; done
if [ -n "$MISSING_BASE" ]; then
  D=$(ls "$OFFLINE_DIR"/*.deb 2>/dev/null | tr '\n' ' ')
  if [ -n "$D" ] && [ "$CHECK" = 0 ]; then apt_local $D; fi
fi
for c in curl jq; do
  have "$c" && ok "$c present" || { [ "$CHECK" = 1 ] && bad "$c MISSING" || die "$c is required and not installed. Stage its .deb in $OFFLINE_DIR"; }
done

# --- tailscale ---
if have tailscale; then
  ok "tailscale present: $(tailscale version 2>/dev/null | head -1)"
else
  TS=$(staged 'tailscale*.deb')
  [ -n "$TS" ] || die "tailscale not installed and no tailscale*.deb in $OFFLINE_DIR"
  if [ "$CHECK" = 0 ]; then
    note "installing $(basename "$TS")"
    apt_local "$TS"
    have tailscale || die "tailscale install FAILED from $(basename "$TS")"
    ok "tailscale installed: $(tailscale version 2>/dev/null | head -1)"
  else
    warn "would install $(basename "$TS")"
  fi
fi
if [ "$CHECK" = 0 ] && have tailscale; then
  systemctl enable --now tailscaled >/dev/null 2>&1
  systemctl is-active tailscaled >/dev/null 2>&1 && ok "tailscaled running" || die "tailscaled will not start"
fi

# --- node ---
if have node; then
  ok "node present: $(node -v 2>/dev/null)"
else
  NT=$(staged 'node-v*-linux-x64.tar.xz'); ND=$(staged 'nodejs*.deb')
  if [ "$CHECK" = 0 ]; then
    if [ -n "$NT" ]; then note "unpacking $(basename "$NT")"; tar -xJf "$NT" -C /usr/local --strip-components=1
    elif [ -n "$ND" ]; then note "installing $(basename "$ND")"; apt_local "$ND"
    else die "node not installed and no node tarball or .deb in $OFFLINE_DIR"; fi
    have node || die "node install FAILED"
    ok "node installed: $(node -v)"
  else
    [ -n "$NT$ND" ] && warn "would install node" || bad "node artifact MISSING"
  fi
fi

# --- claude code ---
if have claude; then
  ok "claude present: $(claude --version 2>/dev/null | head -1)"
else
  CC=$(staged 'claude-code-*.tgz'); [ -n "$CC" ] || CC=$(staged 'anthropic-ai-claude-code-*.tgz')
  if [ "$CHECK" = 0 ]; then
    [ -n "$CC" ] || die "claude not installed and no claude-code-*.tgz in $OFFLINE_DIR
  Build it at home with: npm pack @anthropic-ai/claude-code"
    note "installing $(basename "$CC")"
    npm install -g "$CC" >/dev/null 2>&1
    have claude || die "claude install FAILED from $(basename "$CC")"
    ok "claude installed: $(claude --version 2>/dev/null | head -1)"
  else
    [ -n "$CC" ] && warn "would install $(basename "$CC")" || bad "claude-code tarball MISSING"
  fi
fi

# --- helper scripts ---
for s in netladder.sh linkwatch.sh claude-connect; do
  n=$(basename "$s" .sh)
  if [ -f "$HERE/$s" ]; then
    [ "$CHECK" = 0 ] && install -m 755 "$HERE/$s" "/usr/local/bin/$n"
    ok "$n staged"
  else
    bad "$s missing beside this script"
  fi
done

[ "$CHECK" = 1 ] && { printf '\n--check complete: review any FAIL above.\n'; exit 0; }

# =============================================================================
phase "3 - DISCOVER PATHS OUT"
# =============================================================================
. /etc/default/netladder 2>/dev/null
HOME_TS_IP="${HOME_TS_IP:-}"
HOME_PROXY_PORT="${HOME_PROXY_PORT:-3128}"

if ! tailscale status >/dev/null 2>&1; then
  if [ -n "${TS_AUTHKEY:-}" ]; then
    note "bringing tailscale up with the pre-authorised key"
    tailscale up --authkey "$TS_AUTHKEY" --hostname "$(hostname)" \
                 --accept-dns=false --accept-routes=false >/dev/null 2>&1
  fi
fi
if tailscale status >/dev/null 2>&1; then
  ok "tailscale up: $(tailscale ip -4 2>/dev/null | head -1)"
else
  warn "tailscale is NOT up - the home path will be unavailable"
  note "if this needed a login, the auth key was missing or not pre-approved"
fi

CANDIDATES=""
probe(){ # probe <label> <curl-args...>
  local lbl="$1"; shift
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 12 "$@" https://api.anthropic.com/v1/models 2>/dev/null)
  case "$code" in
    200|401|403) ok "$lbl reachable (HTTP $code)"; CANDIDATES="$CANDIDATES $lbl"; return 0 ;;
    *) bad "$lbl unreachable (HTTP ${code:-000})"; return 1 ;;
  esac
}
probe "direct"
[ -n "$HOME_TS_IP" ] && probe "home-proxy" -x "http://${HOME_TS_IP}:${HOME_PROXY_PORT}"
[ -z "$CANDIDATES" ] && die "no path reaches api.anthropic.com.
  Run 'netladder --full' for a complete rung-by-rung diagnosis.
  If HTTPS egress exists but nothing tunnels, a DERP server on your own domain
  (rung 4) is the intended answer - build it before you travel."

# =============================================================================
phase "4 - MEASURE AND RANK"
# =============================================================================
# Pick the BEST path, not merely the first that answers. Latency dominates
# interactive use; throughput matters for large responses. Measured against the
# real endpoint, because a path can be reachable and still be unusable.
BEST=""; BEST_SCORE=999999
for c in $CANDIDATES; do
  ARGS=""
  [ "$c" = "home-proxy" ] && ARGS="-x http://${HOME_TS_IP}:${HOME_PROXY_PORT}"
  T=$(curl -s -o /dev/null -w '%{time_total} %{speed_download}' --max-time 20 $ARGS \
       https://api.anthropic.com/v1/models 2>/dev/null)
  LAT=$(echo "$T" | awk '{printf "%.0f", $1*1000}')
  BW=$(echo  "$T" | awk '{printf "%.0f", $2/1024}')
  [ -z "$LAT" ] && LAT=99999
  printf '  %-12s latency %5sms   throughput %6s KB/s\n' "$c" "$LAT" "${BW:-0}"
  if [ "$LAT" -lt "$BEST_SCORE" ]; then BEST_SCORE="$LAT"; BEST="$c"; fi
done
ok "best path: $BEST (${BEST_SCORE}ms)"

# =============================================================================
phase "5 - PIN THE ROUTE"
# =============================================================================
if [ "$BEST" = "home-proxy" ]; then
  PROXY="http://${HOME_TS_IP}:${HOME_PROXY_PORT}"
  cat > /etc/profile.d/claude-route.sh <<EOF
export HTTPS_PROXY=$PROXY
export HTTP_PROXY=$PROXY
export NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10
EOF
  ok "route pinned: via home proxy $PROXY"
else
  rm -f /etc/profile.d/claude-route.sh 2>/dev/null
  ok "route pinned: direct (no proxy)"
fi
note "claude-connect re-verifies this at every launch, so a stale route cannot strand you"

# =============================================================================
phase "6 - AUTH (subscription, gated)"
# =============================================================================
CREDS_SRC=$(staged 'credentials.json'); CREDS="$HOME/.claude/.credentials.json"
if [ -n "$CREDS_SRC" ] && [ ! -f "$CREDS" ]; then
  install -m 600 -D "$CREDS_SRC" "$CREDS"
  note "staged subscription credentials from the bundle"
fi
[ -r "$CREDS" ] || die "no subscription credentials at $CREDS
  Copy ~/.claude/.credentials.json from a machine where you are signed in,
  or place it in the bundle as offline/credentials.json (mode 600).
  Without it Claude will demand a login this host cannot perform."

RT=$(sed -n 's/.*"refreshTokenExpiresAt"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' "$CREDS" | head -1)
SUB=$(sed -n 's/.*"subscriptionType"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CREDS" | head -1)
if [ -n "$RT" ]; then
  H=$(( (RT - $(date -u +%s)000 ) / 3600000 ))
  if [ "$H" -le 0 ]; then
    die "subscription refresh token EXPIRED. Re-authenticate at home and re-stage."
  elif [ "$H" -lt 24 ]; then
    warn "subscription (${SUB:-?}) refresh token expires in ${H}h - re-stage before it lapses"
  else
    ok "subscription (${SUB:-?}) valid ~$((H/24))d $((H%24))h"
  fi
fi
mkdir -p "$HOME/.claude"
[ -f "$HOME/.claude/settings.json" ] || \
  printf '{ "permissions": { "defaultMode": "bypassPermissions" } }\n' > "$HOME/.claude/settings.json"
ok "bypass permissions preset"

# =============================================================================
phase "7 - LAUNCH"
# =============================================================================
systemctl enable --now linkwatch >/dev/null 2>&1 && ok "linkwatch watchdog running"
if [ "$NOLAUNCH" = 1 ]; then
  ok "setup complete - launch with: claude-connect"
  exit 0
fi
ok "starting Claude on the pinned route, bypass mode, subscription auth"
exec /usr/local/bin/claude-connect
