#!/usr/bin/env bash
# =============================================================================
# make-offline-bundle.sh - build the offline/ directory that range-bootstrap uses.
#
# RUN THIS AT HOME, on a network that works. Then carry the whole tools/bootstrap
# directory (scripts + offline/) to the restricted host on a USB stick or via the
# tunnel, and run range-bootstrap.sh there with no egress at all.
#
# Match the TARGET's Debian codename, not this machine's:
#   PVE 8.4 -> bookworm      PVE 9.x -> trixie
#   Ubuntu 22.04 -> jammy    Ubuntu 24.04 -> noble
# A .deb built for the wrong codename will refuse to install, and the error is
# not always obvious.
#
# Usage:
#   ./make-offline-bundle.sh                  # for THIS machine's codename
#   ./make-offline-bundle.sh bookworm         # explicitly for PVE 8.4
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/offline"
CODENAME="${1:-$( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-bookworm}" )}"
mkdir -p "$OUT"
cd "$OUT" || exit 1

say(){ printf '  %s\n' "$*"; }
ok(){ printf '  [ OK ] %s\n' "$*"; }
bad(){ printf '  [FAIL] %s\n' "$*"; }

echo "building offline bundle for codename: $CODENAME"
echo "output: $OUT"
echo

# --- 1. Debian packages ------------------------------------------------------
# apt-get download fetches the .deb WITHOUT installing it. Dependencies are NOT
# pulled in, which is fine for these because they are either already present on a
# Debian base or genuinely dependency-light. Verify on the target with --check.
say "fetching base .deb packages"
for p in jq git ethtool wireguard-tools; do
  if apt-get download "$p" >/dev/null 2>&1; then ok "$p"; else bad "$p (may already be installed on target)"; fi
done

# --- 2. Tailscale ------------------------------------------------------------
say "fetching tailscale for $CODENAME"
if ! apt-get download tailscale >/dev/null 2>&1; then
  # Not in the local apt cache - pull it straight from Tailscale's pool.
  TSURL="https://pkgs.tailscale.com/stable/debian/pool"
  if curl -fsSL "https://pkgs.tailscale.com/stable/debian/dists/$CODENAME/main/binary-amd64/Packages" 2>/dev/null \
     | awk '/^Filename: /{print $2}' | grep -E 'tailscale_[0-9]' | sort -V | tail -1 > /tmp/tsfile 2>/dev/null \
     && [ -s /tmp/tsfile ]; then
    F=$(cat /tmp/tsfile)
    curl -fsSL -o "$(basename "$F")" "https://pkgs.tailscale.com/stable/debian/$F" && ok "$(basename "$F")" || bad "tailscale download"
  else
    bad "tailscale - add its apt repo first, or download the .deb manually"
  fi
else
  ok "tailscale (from apt cache)"
fi

# --- 3. Node.js --------------------------------------------------------------
# The static tarball is far more portable than the NodeSource .deb: no repo
# needed, no codename coupling, works on any glibc x64 Debian/Ubuntu.
say "fetching Node.js static tarball (portable across codenames)"
NODEV="v22.14.0"
if curl -fsSL -o "node-$NODEV-linux-x64.tar.xz" \
     "https://nodejs.org/dist/$NODEV/node-$NODEV-linux-x64.tar.xz" 2>/dev/null; then
  ok "node-$NODEV-linux-x64.tar.xz"
else
  bad "node tarball - check https://nodejs.org/dist for a current version"
fi

# --- 4. Claude Code ----------------------------------------------------------
# npm pack downloads the published tarball without installing it. This is the
# LATEST version at bundle-build time - rebuild the bundle to update.
say "packing @anthropic-ai/claude-code (latest)"
if command -v npm >/dev/null 2>&1; then
  if npm pack @anthropic-ai/claude-code@latest >/dev/null 2>&1; then
    ok "$(ls -1 anthropic-ai-claude-code-*.tgz claude-code-*.tgz 2>/dev/null | head -1)"
    # range-bootstrap looks for claude-code-*.tgz; npm names it with the scope.
    for f in anthropic-ai-claude-code-*.tgz; do
      [ -e "$f" ] && cp -f "$f" "claude-code-${f##*-}" 2>/dev/null
    done
  else
    bad "npm pack failed"
  fi
else
  bad "npm not available here - run this on a machine with node/npm"
fi

# --- 5. wstunnel (optional) --------------------------------------------------
say "fetching wstunnel (optional, enables the WireGuard-over-TLS rung)"
if curl -fsSL -o wstunnel.tar.gz \
   "https://github.com/erebe/wstunnel/releases/download/v10.1.9/wstunnel_10.1.9_linux_amd64.tar.gz" 2>/dev/null; then
  ok "wstunnel.tar.gz"
else
  bad "wstunnel (optional - the rung will report skip)"
fi

# --- report ------------------------------------------------------------------
echo
echo "bundle contents:"
ls -lh "$OUT" | awk 'NR>1{printf "  %-52s %s\n",$9,$5}'
echo
TOTAL=$(du -sh "$OUT" 2>/dev/null | cut -f1)
echo "total: ${TOTAL:-unknown}"
echo
echo "NEXT: copy the whole $(dirname "$OUT") directory to the target, then run:"
echo "  sudo ./range-bootstrap.sh --check          # confirm it finds everything"
echo "  sudo TS_AUTHKEY=... HOME_TS_IP=... ./range-bootstrap.sh"
echo
echo "The target needs NO internet for the install. It needs connectivity only"
echo "afterwards, for Tailscale to come up and for Claude to reach the API."
