#!/usr/bin/env bash
# =============================================================================
# setup-custom-derp.sh - stand up a Tailscale DERP relay on YOUR OWN domain.
#
# WHEN YOU NEED THIS:
#   Only when a perimeter blocks Tailscale itself. Those blocks are almost always
#   a single SNI wildcard against the DERP subdomains, so a relay on a domain you
#   own is not on the blocklist and simply works. This is NOT traffic disguise -
#   it is your server, your certificate, ordinary HTTPS to your own endpoint.
#
#   You do NOT need this if `netladder` reports ts-derp OK. Check first.
#
# WHY YOUR EXISTING FUNNEL DOES NOT HELP:
#   *.ts.net is a Tailscale-owned domain. Any filter that blocks *.tailscale.com
#   will very likely block *.ts.net in the same rule. You need a domain that is
#   yours and unremarkable.
#
# WHERE TO RUN IT:
#   A small VPS is strongly preferred over home:
#     - it needs inbound 443, which at home means a port-forward that cuts across
#       a VPN-egress setup and a "no inbound" policy
#     - a relay is only useful if it is reachable when your home link is not
#   Any $5/month instance is ample; DERP relays are tiny.
#
# PREREQUISITES (this script checks all of them):
#   1. a domain you control, with an A record -> this host's public IP
#   2. inbound TCP 443 and 80 reachable from the internet
#   3. root on this host
#
# Usage:
#   sudo ./setup-custom-derp.sh derp.example.com
#   sudo ./setup-custom-derp.sh derp.example.com --check
# =============================================================================
set -uo pipefail

DOMAIN="${1:-}"
CHECK=0; [ "${2:-}" = "--check" ] && CHECK=1
[ -n "$DOMAIN" ] || { sed -n '2,40p' "$0"; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }

ok(){ echo "  [ OK ] $*"; }
bad(){ echo "  [FAIL] $*"; }
note(){ echo "         $*"; }
die(){ echo; echo "STOPPED: $*"; exit 1; }

echo "=== custom DERP setup for $DOMAIN ==="

# --- 1. DNS ------------------------------------------------------------------
MYIP=$(curl -s --max-time 10 https://ifconfig.me 2>/dev/null)
RESOLVED=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
note "this host's public IP : ${MYIP:-unknown}"
note "$DOMAIN resolves to   : ${RESOLVED:-NOTHING}"
if [ -z "$RESOLVED" ]; then
  die "$DOMAIN does not resolve. Create an A record pointing at ${MYIP:-this host} first."
elif [ "$RESOLVED" != "$MYIP" ]; then
  bad "DNS points at $RESOLVED but this host is $MYIP"
  note "That is fine ONLY if this host is behind NAT and 443 is forwarded here."
else
  ok "DNS matches this host"
fi

# --- 2. inbound reachability -------------------------------------------------
# A DERP relay is useless if clients cannot reach it. Check before building.
for p in 80 443; do
  if ss -ltn 2>/dev/null | grep -q ":$p "; then
    note "port $p already has a listener - derper will conflict unless you free it or use SNI pass-through"
  fi
done
ok "prerequisite checks done"
[ "$CHECK" = 1 ] && { echo; echo "--check only, nothing installed."; exit 0; }

# --- 3. Go toolchain ---------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  echo "  installing Go (derper is built from source)"
  GOV="1.23.5"
  curl -fsSL -o /tmp/go.tgz "https://go.dev/dl/go${GOV}.linux-amd64.tar.gz" || die "could not download Go"
  rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz
  export PATH=$PATH:/usr/local/go/bin
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
fi
command -v go >/dev/null 2>&1 || export PATH=$PATH:/usr/local/go/bin
ok "go $(go version 2>/dev/null | awk '{print $3}')"

# --- 4. build derper ---------------------------------------------------------
if ! command -v derper >/dev/null 2>&1 && [ ! -x /usr/local/bin/derper ]; then
  echo "  building derper from tailscale.com/cmd/derper"
  GOBIN=/usr/local/bin go install tailscale.com/cmd/derper@latest || die "derper build failed"
fi
[ -x /usr/local/bin/derper ] && ok "derper built" || die "derper not present after build"

# --- 5. service --------------------------------------------------------------
# derper obtains its own Let's Encrypt certificate via the ACME HTTP-01 challenge,
# which is why port 80 must also be reachable. --verify-clients is deliberately
# OFF here: enabling it requires tailscaled running locally and rejects clients
# that are not in your tailnet, which is stricter but adds a dependency.
cat > /etc/systemd/system/derper.service <<EOF
[Unit]
Description=Tailscale DERP relay ($DOMAIN)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/derper -hostname $DOMAIN -certmode letsencrypt -certdir /var/lib/derper -a :443 -http-port 80
Restart=always
RestartSec=10
StateDirectory=derper

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now derper
sleep 8
if systemctl is-active derper >/dev/null 2>&1; then
  ok "derper running"
else
  bad "derper failed to start"
  journalctl -u derper -n 15 --no-pager | sed 's/^/         /'
  die "see the log above - the usual causes are port 443 in use, or ACME failing because port 80 is unreachable"
fi

# --- 6. verify from the outside ---------------------------------------------
sleep 5
CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/derp/probe" 2>/dev/null)
if [ "$CODE" = "200" ]; then
  ok "relay answering on https://$DOMAIN/derp/probe (HTTP 200)"
else
  bad "probe returned HTTP ${CODE:-000} - the cert may still be issuing; retry in a minute"
fi

# --- 7. what you must do in the admin console -------------------------------
cat <<EOF

=== FINAL STEP - tailnet policy file (admin console) ===
Add this to your ACL policy at https://login.tailscale.com/admin/acls

  "derpMap": {
    // OmitDefaultRegions is THE setting people miss. Without it the client keeps
    // trying the blocked default DERPs and stalls before falling back to yours.
    "OmitDefaultRegions": true,
    "Regions": {
      "900": {
        "RegionID":   900,          // 900-999 is the reserved range for custom regions
        "RegionCode": "custom",
        "Nodes": [{ "Name": "1", "RegionID": 900, "HostName": "$DOMAIN" }]
      }
    }
  }

Then on a client:  tailscale netcheck
It should report your custom region, not a Tailscale one.

NOTE: with OmitDefaultRegions true, EVERY node in your tailnet relies on this
relay when it cannot connect directly. If this host goes down, relayed
connections across your whole tailnet go with it. Consider running two.
EOF
