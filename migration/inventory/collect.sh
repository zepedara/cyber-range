#!/bin/bash
# Runs ON a Proxmox host. READ-ONLY. Captures everything a restore needs to be reproducible.
# /etc/pve is NOT in a vzdump backup, so host network / storage / firewall / startup order must be
# captured here or they are lost on restore.
echo "### $(hostname) $(date -u +%FT%TZ)"
pveversion 2>/dev/null | head -1; uname -r
lscpu | grep -E '^(Model name|Socket|Core\(s\)|Thread|CPU\(s\)):'
echo "--- memory (GB)"; free -g | head -2
echo "--- guests"
qm list 2>/dev/null; pct list 2>/dev/null
for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  echo "=== VM $id"; qm config "$id" 2>/dev/null
done
for id in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
  echo "=== CT $id"; pct config "$id" 2>/dev/null
done
echo "--- storage"; pvesm status 2>/dev/null; zpool list 2>/dev/null; zfs list 2>/dev/null | head -30
echo "--- disks"; lsblk -dno NAME,SIZE,MODEL 2>/dev/null
echo "--- network"; cat /etc/network/interfaces 2>/dev/null; echo; ip -br link
echo "--- MACs (must be preserved)"
for id in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
  qm config "$id" 2>/dev/null | grep -E '^net[0-9]+:' | sed "s/^/VM$id /"
done
echo "--- host firewall"; cat /etc/pve/firewall/cluster.fw 2>/dev/null
echo "--- startup order"; grep -H . /etc/pve/qemu-server/*.conf 2>/dev/null | grep -E 'onboot|startup'
