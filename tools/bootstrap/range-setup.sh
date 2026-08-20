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
  # *** THE TRAP THAT NEARLY SHIPPED ***
  # The published @anthropic-ai/claude-code package is a ~28KB WRAPPER. The real
  # ~320MB binary arrives as an optionalDependency (claude-code-linux-x64), and
  # postinstall merely copies it out. So `npm pack` alone stages a stub that fails
  # on first launch with "claude native binary not installed".
  # The correct offline method is a PRE-POPULATED NPM CACHE, which carries the
  # platform package too. Verified: npm --offline against the cache produced the
  # full 320MB binary.
  NPMC="$OFFLINE_DIR/npm-cache"
  if [ "$CHECK" = 0 ]; then
    if [ -d "$NPMC" ]; then
      note "installing claude from the offline npm cache"
      npm install -g @anthropic-ai/claude-code --cache "$NPMC" --offline >/dev/null 2>&1
    else
      CC=$(staged 'claude-code-*.tgz')
      [ -n "$CC" ] || die "claude not installed, and neither an npm-cache/ directory nor a
  claude-code tarball is present in $OFFLINE_DIR.
  Build the bundle at home with ./make-offline-bundle.sh - a bare 'npm pack'
  is NOT sufficient, it omits the platform binary."
      warn "no npm-cache/ - falling back to $(basename "$CC"), which may install only the wrapper"
      npm install -g "$CC" >/dev/null 2>&1
    fi
    have claude || die "claude install FAILED"
    # Prove the NATIVE binary landed, not just the stub - the stub passes a bare
    # 'command -v claude' check and then fails at runtime.
    NB=$(find /usr/lib/node_modules /usr/local/lib/node_modules -path '*claude-code-*' -name 'claude' -size +1M 2>/dev/null | head -1)
    if [ -n "$NB" ]; then
      ok "claude installed with native binary ($(du -h "$NB" | cut -f1))"
    else
      die "claude installed but the NATIVE BINARY IS MISSING - only the wrapper stub is present.
  It will fail at first launch. Rebuild the bundle with an npm-cache/ directory."
    fi
  else
    [ -d "$NPMC" ] && warn "would install claude from npm-cache/" || bad "npm-cache/ MISSING - claude would install as a broken stub"
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

# --- inbound SSH: the RETURN PATH ---------------------------------------------
# Without this the setup finishes and home still cannot reach in. The whole point
# of the tunnel is bidirectional control: drive this host from home, and reach
# home machines from here. So authorise the staged keys and make sure sshd runs.
AK=$(staged 'authorized_keys')
if [ -n "$AK" ] && [ "$CHECK" = 0 ]; then
  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  while read -r line; do
    case "$line" in ssh-*)
      grep -qF "$line" /root/.ssh/authorized_keys 2>/dev/null || echo "$line" >> /root/.ssh/authorized_keys ;;
    esac
  done < "$AK"
  chmod 600 /root/.ssh/authorized_keys
  ok "authorised $(grep -c '^ssh-' /root/.ssh/authorized_keys) key(s) for inbound SSH"
  systemctl enable --now ssh sshd >/dev/null 2>&1
  if ss -ltn 2>/dev/null | grep -q ':22 '; then
    ok "sshd listening on 22 - home can reach in over the tunnel"
  else
    warn "sshd not listening - inbound control will not work"
  fi
elif [ "$CHECK" = 1 ]; then
  [ -n "$AK" ] && ok "authorized_keys staged (return path will work)" \
               || bad "NO authorized_keys in the bundle - home could not reach in"
fi

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
# SCOPE THE ROUTE TO CLAUDE ONLY, not the whole host.
# An earlier version wrote /etc/profile.d/claude-route.sh, which exports the proxy
# into EVERY new login shell - so apt, git, curl and anything else would also be
# redirected through home. That is far broader than intended and, if the tunnel
# drops, it breaks unrelated tooling in ways that are hard to attribute.
# Instead the decision is recorded in netladder's config and applied by
# claude-connect at launch, in Claude's process environment only.
rm -f /etc/profile.d/claude-route.sh 2>/dev/null
if [ "$BEST" = "home-proxy" ]; then
  PROXY="http://${HOME_TS_IP}:${HOME_PROXY_PORT}"
  grep -q '^CLAUDE_ROUTE=' /etc/default/netladder 2>/dev/null \
    && sed -i "s|^CLAUDE_ROUTE=.*|CLAUDE_ROUTE=$PROXY|" /etc/default/netladder \
    || echo "CLAUDE_ROUTE=$PROXY" >> /etc/default/netladder
  ok "route selected: home proxy $PROXY"
  note "applied to Claude ONLY - system traffic is untouched"
else
  sed -i '/^CLAUDE_ROUTE=/d' /etc/default/netladder 2>/dev/null
  ok "route selected: direct (no proxy)"
fi
note "claude-connect re-verifies at every launch, so a stale route cannot strand you"
note "to bind Claude to a specific WAN instead of a proxy, set CLAUDE_WAN_IF/CLAUDE_WAN_GW"
note "  (per-UID routing via 'ip rule uidrange' - only Claude's uid uses that link)"

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
