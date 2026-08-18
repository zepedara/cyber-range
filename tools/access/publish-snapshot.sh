#!/bin/bash
# Runs ON cthuwu. Read-only. Emits a SANITIZED environment snapshot to stdout.
# Redaction: house LAN (192.168.x), tailnet (100.x) and public IPs are masked.
# Range-internal 10.30/10.31/10.20 addressing is KEPT - it is the whole point.
RED='s/192\.168\.[0-9]\+\.[0-9]\+/<house-ip>/g; s/100\.[0-9]\+\.[0-9]\+\.[0-9]\+/<tailnet-ip>/g'
r(){ sed -e "$RED"; }

echo "## Hypervisor"
echo '```'
pveversion 2>/dev/null | head -1
uname -r
lscpu 2>/dev/null | grep -E '^Model name|^CPU\(s\)|^Thread\(s\)|^Core\(s\)|^Socket' | sed 's/  */ /g'
free -g 2>/dev/null | awk '/^Mem/{print "RAM: total="$2"G used="$3"G available="$7"G"}'
echo '```'
echo
echo "## Guests"
echo '```'
qm list 2>/dev/null | r
echo '```'
echo
echo "## Bridges"
echo '```'
ip -br link show type bridge 2>/dev/null | awk '{printf "%-10s %s\n",$1,$2}'
echo '```'
echo
echo "## SPAN bridge discipline (load-bearing - see AUDIT_AND_LESSONS 4.2)"
echo '```'
echo "vmbr91 ageing_time=$(cat /sys/class/net/vmbr91/bridge/ageing_time 2>/dev/null)"
for p in /sys/class/net/vmbr91/brif/*; do
  [ -e "$p" ] || continue
  echo "port $(basename $p) learning=$(cat $p/learning 2>/dev/null)"
done
echo '```'
echo
echo "## Storage"
echo '```'
pvesm status 2>/dev/null
zpool list 2>/dev/null
awk '/^size/ {printf "ARC size=%.1f GiB\n", $3/1073741824}' /proc/spl/kstat/zfs/arcstats 2>/dev/null
echo '```'
echo
echo "## Containers (cthost01)"
echo '```'
ssh -o BatchMode=yes -o ConnectTimeout=20 cthost01 'incus list -c ns4 --format csv' 2>/dev/null | r || echo "unreachable"
echo '```'
