#!/usr/bin/env bash
# =============================================================================
# netladder - try EVERY way out, in order of what survives hostile perimeters.
#
# The problem: on a restricted network you do not know in advance what is
# blocked. Guessing wastes the one thing you have least of - a person on site.
# So probe every method, report exactly which ones work, and bring up the best
# one automatically.
#
# THE LADDER (rungs are ordered by likelihood of success, not by speed):
#
#   0  baseline        raw IP reachability + DNS + captive-portal detection
#   1  ts-direct       Tailscale peer-to-peer, UDP 41641        fast, often blocked
#   2  ts-derp         Tailscale relay over HTTPS/TCP 443       usually works
#   3  ts-proxy        Tailscale control via corporate proxy    works behind proxy
#   4  ts-customderp   self-hosted DERP on YOUR domain :443     beats SNI filtering
#   5  wg-udp          WireGuard to home, UDP                   fast, blocked often
#   6  wg-tcp443       WireGuard wrapped in TLS via wstunnel    looks like HTTPS
#   7  ssh443          SSH to home on TCP 443                   very commonly open
#   8  https-beacon    ntfy/HTTPS POST to a generic host        near-universal
#   9  doh             DNS-over-HTTPS reachability              last-resort signal
#
# Rungs 0-2 and 7-9 need no extra infrastructure. 3-6 need setup at home first;
# they are probed anyway so you learn whether they WOULD work.
#
# Usage:
#   netladder                 probe everything, report, bring up the best rung
#   netladder --probe-only    probe and report, change nothing
#   netladder --json          machine-readable result
#
# Config: /etc/default/netladder  (see EXAMPLE block at the bottom of this file)
# =============================================================================
set -uo pipefail

. /etc/default/netladder 2>/dev/null
HOME_TS_IP="${HOME_TS_IP:-}"          # tailnet IP of a home host
HOME_PUBLIC="${HOME_PUBLIC:-}"        # public hostname of home (for ssh443 / wstunnel)
SSH443_PORT="${SSH443_PORT:-443}"
CUSTOM_DERP="${CUSTOM_DERP:-}"        # your own DERP hostname, if you run one
NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-}"
PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
TIMEOUT="${TIMEOUT:-8}"

PROBE_ONLY=0; JSON=0
for a in "$@"; do
  case "$a" in
    --probe-only) PROBE_ONLY=1 ;;
    --json) JSON=1; PROBE_ONLY=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
  esac
done

declare -A R      # rung -> ok|fail|skip
declare -A NOTE

ok(){ R[$1]=ok;   NOTE[$1]="${2:-}"; }
no(){ R[$1]=fail; NOTE[$1]="${2:-}"; }
sk(){ R[$1]=skip; NOTE[$1]="${2:-}"; }

t(){ timeout "$TIMEOUT" "$@" >/dev/null 2>&1; }
tcp(){ timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/$2" >/dev/null 2>&1; }

# --- rung 0: baseline --------------------------------------------------------
# Use RAW IPs. A broken resolver must never be mistaken for a dead link - that
# misdiagnosis has cost this project hours more than once.
BASE_OK=0
for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
  if t ping -c1 -W2 "$ip"; then BASE_OK=1; break; fi
done
[ "$BASE_OK" = 1 ] && ok baseline-icmp || no baseline-icmp "ICMP blocked or no route"

# TCP 443 to a well-known host is the single most predictive probe there is.
if tcp 1.1.1.1 443; then ok baseline-443; else no baseline-443 "outbound 443 blocked"; fi

# Try three resolvers before declaring DNS broken. getent alone gives false
# negatives (notably under WSL), and a wrong "resolver broken" verdict sends you
# chasing DNS when the real fault is elsewhere.
DNS_OK=0
t getent hosts one.one.one.one && DNS_OK=1
[ $DNS_OK = 0 ] && command -v nslookup >/dev/null 2>&1 && t nslookup one.one.one.one && DNS_OK=1
[ $DNS_OK = 0 ] && command -v host >/dev/null 2>&1 && t host one.one.one.one && DNS_OK=1
# Last resort: if curl can resolve a name, DNS demonstrably works.
[ $DNS_OK = 0 ] && t curl -s -o /dev/null --max-time 6 https://one.one.one.one && DNS_OK=1
[ $DNS_OK = 1 ] && ok baseline-dns || no baseline-dns "no resolver answered"

# Captive portal / interception: an unexpected redirect or non-204 means someone
# is in the middle. Detect it explicitly rather than being confused by it later.
CODE=$(timeout "$TIMEOUT" curl -s -o /dev/null -w '%{http_code}' http://cp.cloudflare.com/generate_204 2>/dev/null)
if [ "$CODE" = "204" ]; then ok baseline-noportal
elif [ -n "$CODE" ] && [ "$CODE" != "000" ]; then no baseline-noportal "captive portal/proxy: HTTP $CODE"
else no baseline-noportal "no HTTP egress"; fi

# --- rung 1/2/3: tailscale ---------------------------------------------------
if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    # Distinguish direct from relayed - the difference tells you what is filtered.
    SELF=$(tailscale status --json 2>/dev/null | grep -o '"Relay":"[^"]*"' | head -1 | cut -d'"' -f4)
    if tailscale status 2>/dev/null | grep -q 'direct '; then
      ok ts-direct "peer-to-peer established"
    else
      no ts-direct "no direct peers (UDP likely filtered)"
    fi
    [ -n "$SELF" ] && ok ts-derp "relaying via DERP region '$SELF'" || ok ts-derp "up"
  else
    no ts-direct "tailscale not up"
    # Can we even reach the control plane and a DERP? Probe the transport itself.
    tcp controlplane.tailscale.com 443 && ok ts-derp "control plane reachable, not logged in" \
                                       || no ts-derp "controlplane.tailscale.com:443 blocked"
  fi
  if [ -n "$PROXY" ]; then
    ph=$(echo "$PROXY" | sed -E 's#^https?://##; s#/.*##; s#.*@##')
    tcp "${ph%%:*}" "${ph##*:}" && ok ts-proxy "proxy $ph reachable" || no ts-proxy "proxy unreachable"
  else
    sk ts-proxy "no HTTPS_PROXY set"
  fi
else
  no ts-direct "tailscale not installed"; no ts-derp "tailscale not installed"; sk ts-proxy
fi

# --- rung 4: custom DERP -----------------------------------------------------
if [ -n "$CUSTOM_DERP" ]; then
  tcp "$CUSTOM_DERP" 443 && ok ts-customderp "$CUSTOM_DERP:443 reachable" \
                         || no ts-customderp "$CUSTOM_DERP:443 blocked"
else
  sk ts-customderp "no CUSTOM_DERP configured - the answer if *.tailscale.com is SNI-blocked"
fi

# --- rung 5/6: wireguard -----------------------------------------------------
if [ -f /etc/wireguard/wg0.conf ]; then
  if wg show wg0 >/dev/null 2>&1; then
    HS=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    NOW=$(date +%s)
    if [ -n "$HS" ] && [ "$HS" -gt 0 ] && [ $((NOW-HS)) -lt 300 ]; then
      ok wg-udp "handshake $((NOW-HS))s ago"
    else
      no wg-udp "interface up but NO recent handshake (UDP filtered)"
    fi
  else
    no wg-udp "wg0 not up"
  fi
else
  sk wg-udp "no wg0.conf"
fi
if command -v wstunnel >/dev/null 2>&1 && [ -n "$HOME_PUBLIC" ]; then
  tcp "$HOME_PUBLIC" 443 && ok wg-tcp443 "wstunnel target reachable" || no wg-tcp443 "blocked"
else
  sk wg-tcp443 "wstunnel not installed / HOME_PUBLIC unset - wraps WG in TLS so it looks like HTTPS"
fi

# --- rung 7: ssh over 443 ----------------------------------------------------
if [ -n "$HOME_PUBLIC" ]; then
  if tcp "$HOME_PUBLIC" "$SSH443_PORT"; then
    BANNER=$(timeout "$TIMEOUT" bash -c "exec 3<>/dev/tcp/$HOME_PUBLIC/$SSH443_PORT; head -c 40 <&3" 2>/dev/null)
    case "$BANNER" in
      SSH-*) ok ssh443 "SSH banner on :$SSH443_PORT" ;;
      *)     no ssh443 "port open but not SSH (proxy intercepting?)" ;;
    esac
  else
    no ssh443 "$HOME_PUBLIC:$SSH443_PORT blocked"
  fi
else
  sk ssh443 "HOME_PUBLIC unset - sshd on 443 at home is one of the most reliable rungs"
fi

# --- rung 8: https beacon ----------------------------------------------------
if [ -n "$NTFY_TOPIC" ]; then
  C=$(timeout "$TIMEOUT" curl -s -o /dev/null -w '%{http_code}' -d "netladder probe" \
      "$NTFY_URL/$NTFY_TOPIC" 2>/dev/null)
  [ "$C" = "200" ] && ok https-beacon "POST $NTFY_URL ok" || no https-beacon "HTTP ${C:-000}"
else
  sk https-beacon "no NTFY_TOPIC"
fi

# --- rung 9: DNS-over-HTTPS --------------------------------------------------
C=$(timeout "$TIMEOUT" curl -s -o /dev/null -w '%{http_code}' \
    -H 'accept: application/dns-json' \
    'https://cloudflare-dns.com/dns-query?name=example.com&type=A' 2>/dev/null)
[ "$C" = "200" ] && ok doh "DoH reachable" || no doh "HTTP ${C:-000}"

# --- report ------------------------------------------------------------------
ORDER="baseline-icmp baseline-443 baseline-dns baseline-noportal ts-direct ts-derp ts-proxy ts-customderp wg-udp wg-tcp443 ssh443 https-beacon doh"

if [ "$JSON" = 1 ]; then
  printf '{"host":"%s","ts":"%s","rungs":{' "$(hostname)" "$(date -u +%FT%TZ)"
  first=1
  for k in $ORDER; do
    [ $first = 1 ] || printf ','
    printf '"%s":{"state":"%s","note":"%s"}' "$k" "${R[$k]:-skip}" "${NOTE[$k]:-}"
    first=0
  done
  printf '}}\n'
  exit 0
fi

echo "netladder - $(hostname) - $(date -u +%FT%TZ)"
echo
for k in $ORDER; do
  s="${R[$k]:-skip}"
  case "$s" in
    ok)   m="  OK  " ;;
    fail) m=" FAIL " ;;
    *)    m=" skip " ;;
  esac
  printf '  [%s] %-16s %s\n' "$m" "$k" "${NOTE[$k]:-}"
done
echo

# Verdict: name the best working rung, because THAT is the actionable output.
BEST=""
for k in ts-direct ts-derp ts-customderp wg-udp wg-tcp443 ssh443 https-beacon; do
  [ "${R[$k]:-}" = "ok" ] && { BEST="$k"; break; }
done
if [ -n "$BEST" ]; then
  echo "  BEST WORKING PATH: $BEST"
else
  echo "  NO TUNNEL PATH WORKS."
  if [ "${R[https-beacon]:-}" = "ok" ] || [ "${R[doh]:-}" = "ok" ]; then
    echo "  But HTTPS egress EXISTS - so a custom DERP on your own domain (rung 4)"
    echo "  or sshd on 443 at home (rung 7) would very likely work. Set those up."
  else
    echo "  No HTTPS egress at all. Check for a mandatory proxy: HTTPS_PROXY."
  fi
fi

# Beacon the result - a probe nobody sees is wasted.
if [ -n "$NTFY_TOPIC" ] && [ "${R[https-beacon]:-}" = "ok" ]; then
  SUM=$(for k in $ORDER; do printf '%s=%s ' "$k" "${R[$k]:-skip}"; done)
  curl -s -m 10 -H "Title: [NETLADDER] $(hostname)" -d "best=${BEST:-none}
$SUM" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1
fi

[ "$PROBE_ONLY" = 1 ] && exit 0

# --- act: bring up the best available rung -----------------------------------
if [ "${R[ts-derp]:-}" = "ok" ] && ! tailscale status >/dev/null 2>&1; then
  echo "  bringing tailscale up..."
  tailscale up --accept-dns=false --unattended 2>/dev/null || tailscale up --accept-dns=false
fi
if [ "${R[wg-udp]:-}" = "fail" ] && [ -f /etc/wireguard/wg0.conf ]; then
  echo "  restarting wg0 (no recent handshake)..."
  systemctl restart wg-quick@wg0 2>/dev/null
fi

# --- PIVOT: once ANY path is up, egress through home ------------------------
# This is the point of the whole exercise. The restricted network's egress is
# blocked and slow; home egress is unrestricted and fast. So as soon as a tunnel
# exists, send Claude's API traffic through home rather than out the local
# perimeter - which is also what makes it work when api.anthropic.com is blocked
# locally. Nothing else is redirected: this is a per-application pivot, not an
# exit node, so the lab subnet stays directly reachable.
if [ -n "$HOME_TS_IP" ] && tailscale status >/dev/null 2>&1; then
  if tcp "$HOME_TS_IP" "${HOME_PROXY_PORT:-3128}"; then
    P="http://$HOME_TS_IP:${HOME_PROXY_PORT:-3128}"
    echo "  home proxy reachable - pivoting egress to $P"
    cat > /etc/profile.d/claude-proxy.sh <<EOF
# Written by netladder. Claude's API traffic egresses via home, not this network.
export HTTPS_PROXY=$P
export HTTP_PROXY=$P
export NO_PROXY=localhost,127.0.0.1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10
EOF
    chmod 644 /etc/profile.d/claude-proxy.sh
    # Prove the pivot actually reaches Anthropic, rather than assuming it.
    AC=$(timeout 15 curl -s -o /dev/null -w '%{http_code}' -x "$P" https://api.anthropic.com/v1/models 2>/dev/null)
    case "$AC" in
      401|403) echo "  VERIFIED: api.anthropic.com reachable via home (HTTP $AC = auth required, transport works)" ;;
      200)     echo "  VERIFIED: api.anthropic.com reachable via home (HTTP 200)" ;;
      000|"")  echo "  WARN: proxy is up but api.anthropic.com did NOT respond through it" ;;
      *)       echo "  api.anthropic.com via home returned HTTP $AC" ;;
    esac
    echo "  NOTE: new shells pick this up. For the current one: . /etc/profile.d/claude-proxy.sh"
  else
    echo "  home proxy $HOME_TS_IP:${HOME_PROXY_PORT:-3128} not reachable"
    echo "  set one up at home (tinyproxy bound to its TAILNET address only) - see README option 2"
  fi
fi

: <<'EXAMPLE'
# /etc/default/netladder
HOME_TS_IP=100.x.y.z                 # a home host on the tailnet
HOME_PUBLIC=home.example.com         # public name of home, for ssh443 / wstunnel
SSH443_PORT=443                      # run sshd on 443 at home - very commonly open
CUSTOM_DERP=derp.example.com         # your own DERP; beats *.tailscale.com SNI blocks
NTFY_URL=https://ntfy.sh
NTFY_TOPIC=yourtopic
TIMEOUT=8
EXAMPLE
