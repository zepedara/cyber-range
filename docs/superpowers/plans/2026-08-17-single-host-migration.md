# Single-Host Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended)
> or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Collapse the range onto one self-contained Proxmox host, expand the VM estate, and package the
whole environment so it restores onto a Cisco UCS C240 M4 and powers on working with no reconfiguration.

**Architecture:** The environment becomes **address-stable and externally independent**. Every guest keeps
its current IP; the bridges those IPs live on are recreated *internally* on the target, so nothing is
re-addressed and nothing depends on the house LAN. Security Onion moves from l3e7 into cthuwu as a VM,
keeping its address. Transport is a **Proxmox Backup Server removable datastore** on an external drive.
Expansion guests are built now and left `onboot=0` so they cost disk but not RAM until the rack is live.

**Tech Stack:** Proxmox VE 8/9, Proxmox Backup Server (removable datastore), ZFS, Incus, OPNsense,
Security Onion 2.4/3.x, Windows Server 2022 + Windows 10/11, `vzdump`, `qm`, `pct`.

## Global Constraints

- **No guest may change IP address.** Security Onion documents that changing IP after install is
  unsupported; `so-ip-update` is experimental, standalone-only, and reported broken on 2.4.
- **Preserve VLAN segmentation exactly** — 9 VLANs, `.1` on the firewall, both `10.30.x` and `10.31.x`
  editions.
- **Preserve every MAC address.** DHCP reservations, AD computer accounts and licence activation all key
  off them.
- **`/etc/pve` is not in a vzdump backup.** Host network, host firewall, storage definitions and cluster
  config must be captured separately or they are lost.
- **ZFS ARC defaults to 50% of RAM.** On 384 GB that silently reserves 192 GB away from guests; it must be
  capped explicitly.
- **Do not overcommit RAM.** Stage expansion guests powered off rather than relying on overcommit.
- Detection content is retrieved from upstream, never authored. No live malware anywhere.
- Homelab SSH goes through WSL; never inline multi-line scripts through wsl→ssh — write to a file and pipe.

---

## Blocking questions for the operator

These change the plan materially and should be answered before Phase 1.

1. **Which storage controller is in the C240 M4?** The chassis ships with either the *Cisco 12G SAS
   Modular RAID* controller or the *UCSC-SAS12GHBA*. ZFS wants the true HBA. A RAID card in JBOD mode
   works but is not recommended for a 5 TB pool, and cannot be fixed after the data is on it. If it is
   the RAID card, source an HBA before migration day.
2. **"Move the Rick VM out of the PBE image"** — I am reading *PBE* as **PBS**, i.e. exclude the `rick`
   guest from the backup set so it does not travel with the range. Confirm, and confirm whether `rick`
   is a guest on cthuwu at all or the separate physical machine.
3. **Does the rack have external network access**, and should the range reach the internet through it?
   The design works either way, but it decides whether fw01 gets a WAN uplink or a stub.
4. **Windows licensing.** Expansion guests need keys or the estate stays on evaluation media, which
   expires. Evaluation Server 2022 is fine for a lab if you accept re-arm cycles.

---

## File structure

| Path | Responsibility |
|---|---|
| `migration/inventory/` | captured host state — `qm config` per guest, `/etc/network/interfaces`, `pvesm status`, MAC map |
| `migration/hostconfig/` | the parts of `/etc/pve` that vzdump does not carry, plus `zfs.conf` and startup order |
| `migration/runbook-restore.md` | the cold-start procedure performed on the C240 |
| `migration/verify/` | post-restore gates — one script per claim |
| `docs/superpowers/plans/2026-08-17-single-host-migration.md` | this plan |

---

## Phase 0 — Capture reality

### Task 0.1: Inventory both hosts

**Files:**
- Create: `migration/inventory/cthuwu.txt`, `migration/inventory/l3e7.txt`
- Create: `migration/inventory/collect.sh`

- [ ] **Step 1: Write the collector**

```bash
#!/bin/bash
# Runs ON a Proxmox host. Read-only. Everything a restore needs to be reproducible.
echo "### $(hostname) $(date -u +%FT%TZ)"
pveversion; uname -r
lscpu | grep -E '^(Model name|Socket|Core|Thread|CPU\(s\))'
free -g
echo "--- guests"
qm list; pct list
for id in $(qm list | awk 'NR>1{print $1}'); do
  echo "=== VM $id"; qm config "$id"
done
for id in $(pct list | awk 'NR>1{print $1}'); do
  echo "=== CT $id"; pct config "$id"
done
echo "--- storage"; pvesm status; zpool list; zfs list
echo "--- network"; cat /etc/network/interfaces; ip -br link
echo "--- MACs (must be preserved)"
for id in $(qm list | awk 'NR>1{print $1}'); do
  qm config "$id" | grep -E '^net[0-9]+:' | sed "s/^/VM$id /"
done
echo "--- host firewall"; cat /etc/pve/firewall/cluster.fw 2>/dev/null
echo "--- startup order"; grep -H . /etc/pve/qemu-server/*.conf 2>/dev/null | grep -E 'onboot|startup'
```

- [ ] **Step 2: Run it against both hosts and commit the output**

```bash
for H in root@<CTHUWU_IP> root@<L3E7_IP>; do
  ssh "$H" 'cat > /tmp/collect.sh' < migration/inventory/collect.sh
  ssh "$H" 'bash /tmp/collect.sh' > "migration/inventory/$(echo $H | cut -d@ -f2).txt"
done
```

- [ ] **Step 3: Verify the capture is complete**

Expected: every running guest appears with a `net0:` line containing a `macaddr=`. If any guest has no
MAC recorded, the restore will generate a new one and break its DHCP reservation.

```bash
grep -c 'macaddr' migration/inventory/*.txt
```

- [ ] **Step 4: Commit**

```bash
git add migration/inventory && git commit -m "Migration: capture current host and guest inventory"
```

### Task 0.2: Size the target

**Files:** Create `migration/inventory/sizing.md`

- [ ] **Step 1: Compute committed vs available RAM**

```bash
awk '/^memory:/{s+=$2} END{print "configured guest RAM (MB):", s}' migration/inventory/*.txt
```

- [ ] **Step 2: Write the budget**

Record, for the 384 GB target:

| Consumer | Allocation |
|---|---|
| ZFS ARC (capped, see Task 5.2) | 32 GB |
| Proxmox host + overhead | 8 GB |
| **Available to guests** | **~344 GB** |

- [ ] **Step 3: Commit**

---

## Phase 1 — Make the environment self-contained

The range currently depends on things that will not exist in the rack: the house LAN, l3e7, and any
house-side DNS/NTP/remote-access endpoints baked into the golden image.

### Task 1.1: Find every external dependency

**Files:** Create `migration/inventory/external-deps.md`

- [ ] **Step 1: Search guests for house-side addresses**

```bash
# on cthost01, across all containers
for c in $(incus list -c n --format csv); do
  incus exec "$c" -- grep -rlE '192\.168\.1\.|100\.(1[0-9]{2})\.' /etc 2>/dev/null </dev/null \
    | sed "s|^|$c |"
done
```

- [ ] **Step 2: Check the Windows guests**

```powershell
# resolv/DNS, NTP, and any remote-access agent pointing at house infrastructure
Get-DnsClientServerAddress | Format-Table -Auto
w32tm /query /peers
Get-Service | Where-Object { $_.Name -match 'rustdesk|teamviewer|tailscale' }
```

- [ ] **Step 3: Record each finding as keep / re-point / remove**

Known from build history: the golden image carried house DNS, RustDesk, Elastic and GHOSTS endpoints.
Anything still pointing at `192.168.1.x` that is *not* so01 must be re-pointed at a range-internal
service or removed.

- [ ] **Step 4: Commit**

### Task 1.2: Re-point internal services at range-internal addresses

- [ ] **Step 1: Set DNS on every guest to the range DC**

Container edition → `10.30.10.10`. VM edition → `10.31.10.10`.

- [ ] **Step 2: Set NTP to fw01**

The time chain must root inside the environment, not on a house appliance:

```powershell
w32tm /config /manualpeerlist:"10.31.5.1" /syncfromflags:manual /update
w32tm /resync
```

- [ ] **Step 3: Verify no guest resolves via a house address**

```bash
# expect zero hits
grep -rE '192\.168\.1\.(1|2|175|191)' migration/inventory/external-deps.md
```

- [ ] **Step 4: Commit**

---

## Phase 2 — Consolidate Security Onion onto cthuwu

so01 is a VM on l3e7. It moves as a VM, keeping `192.168.1.146`, onto a bridge that carries that subnet
internally.

### Task 2.1: Create the sensor-management bridge on cthuwu

**Files:** Modify `/etc/network/interfaces` on cthuwu

- [ ] **Step 1: Add an internal bridge carrying so01's existing subnet**

```ini
# so01 keeps 192.168.1.146. This bridge provides that subnet INTERNALLY so the
# address survives the move to a rack where the house LAN does not exist.
auto vmbr1
iface vmbr1 inet static
    address 192.168.1.2/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```

- [ ] **Step 2: Apply and verify**

```bash
ifreload -a && ip -br addr show vmbr1
```

Expected: `vmbr1 UP 192.168.1.2/24`

- [ ] **Step 3: Commit the interfaces file to `migration/hostconfig/`**

### Task 2.2: Move so01 with a full backup/restore

- [ ] **Step 1: Stop so01 cleanly**

```bash
ssh root@<L3E7_IP> 'qm shutdown 170 --timeout 300'
```

Security Onion does not enjoy hard power-offs; Elasticsearch wants a clean stop.

- [ ] **Step 2: Back it up to the external drive**

```bash
ssh root@<L3E7_IP> 'vzdump 170 --dumpdir /mnt/external --mode stop --compress zstd'
```

- [ ] **Step 3: Restore onto cthuwu, preserving the VM ID and MAC**

```bash
ssh root@<CTHUWU_IP> 'qmrestore /mnt/external/vzdump-qemu-170-*.vma.zst 170 --storage local-zfs'
ssh root@<CTHUWU_IP> 'qm config 170 | grep -E "^net|^memory|^cores"'
```

Expected: the `macaddr=` matches what Task 0.1 recorded. If it does not, set it explicitly:
`qm set 170 --net0 virtio=<ORIGINAL_MAC>,bridge=vmbr1`

- [ ] **Step 4: Attach both NICs — management on vmbr1, monitor on vmbr91**

```bash
qm set 170 --net0 virtio=<ORIGINAL_MAC>,bridge=vmbr1
qm set 170 --net1 virtio=<ORIGINAL_MON_MAC>,bridge=vmbr91
qm start 170
```

- [ ] **Step 5: Verify Security Onion came up on its original address**

```bash
ssh socadmin@192.168.1.146 'sudo so-status' 
```

Expected: all services `OK`. Any service failing here is an IP-related breakage and must be resolved
before proceeding — this is the single riskiest step in the plan.

- [ ] **Step 6: Verify telemetry still lands**

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_count?q=@timestamp:[now-10m%20TO%20now]"
```

Expected: a non-zero count that grows on repeat.

- [ ] **Step 7: Commit the runbook notes**

### Task 2.3: Collapse the VXLAN span path

With both ends on one host, the VXLAN tunnel to l3e7 is no longer needed — `vmbr91` is now local.

- [ ] **Step 1: Remove the vxlan91 interface from cthuwu's config**

- [ ] **Step 2: Verify the mirror still delivers**

```bash
tcpdump -i spanmir -c 20 -e -nn
```

Expected: tagged frames from multiple VLANs. **This is the gate** — if the mirror breaks here, Zeek goes
blind and every downstream metric silently drops.

- [ ] **Step 3: Confirm Zeek still sees multiple VLANs**

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
  "query":{"bool":{"filter":[{"term":{"event.dataset":"zeek.conn"}},
    {"range":{"@timestamp":{"gte":"now-15m"}}}]}},
  "aggs":{"v":{"terms":{"field":"network.vlan.id","size":12}}}}'
```

Expected: several distinct VLAN IDs.

- [ ] **Step 4: Commit**

---

## Phase 3 — Expand the VM estate

Build now, run later. Each new guest is created, configured, verified, then set `onboot=0` and stopped.

### Task 3.1: Decide the target estate

**Files:** Create `migration/inventory/target-estate.md`

- [ ] **Step 1: Write the table**

A realistic enterprise shape for the RAM budget, in addition to what exists:

| Role | Count | RAM each | VLAN | Notes |
|---|---:|---:|---:|---|
| Windows 10/11 workstations | 8 | 4 GB | 20 | **fixes the Prefetch gap** — see below |
| Windows Server (member) | 3 | 6 GB | 10 | print, app, secondary file |
| Second domain controller | 1 | 6 GB | 10 | makes DC replication telemetry real |
| Linux servers | 4 | 4 GB | 10/30 | git, CI, jump, log |
| Branch workstations | 3 | 4 GB | 60 | |
| Analyst workstation | 1 | 8 GB | 5 | where a student actually sits |

Approximate additional commitment: ~110 GB — comfortable inside the ~344 GB budget alongside the
existing estate.

- [ ] **Step 2: Note the Prefetch fix explicitly**

The existing "workstations" are Server 2022, on which `SysMain` deletes `EnablePrefetcher` at service
start, so `C:\Windows\Prefetch` can never populate. Building the new workstations from **Windows 10/11
media** restores Prefetch and the rest of the workstation-only artifact set. This is the cheapest moment
to fix it, because the guests do not exist yet.

- [ ] **Step 3: Commit**

### Task 3.2: Build one workstation and prove the pattern

- [ ] **Step 1: Create the guest**

```bash
qm create 220 --name ws03 --memory 4096 --cores 2 --ostype win11 \
  --scsihw virtio-scsi-single --scsi0 local-zfs:60 \
  --net0 virtio,bridge=vmbr61,tag=20 \
  --cdrom local:iso/Win11.iso --ide2 local:iso/virtio-win.iso \
  --agent enabled=1 --balloon 2048
```

`--balloon` is set because Windows only releases memory through the balloon driver, and the driver must
be installed from the virtio ISO for it to do anything.

- [ ] **Step 2: Install Windows, the virtio drivers and the guest agent**

- [ ] **Step 3: Join the domain and confirm**

```powershell
Add-Computer -DomainName lab.local -Credential (Get-Credential LAB\Administrator) -Restart
```

- [ ] **Step 4: Verify Prefetch actually works on this SKU** *(the whole reason for Win10/11)*

```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters').EnablePrefetcher
Restart-Service SysMain; Start-Sleep 10
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters').EnablePrefetcher
(Get-ChildItem C:\Windows\Prefetch -Filter *.pf).Count
```

Expected: `EnablePrefetcher` still `3` **after** the SysMain restart (on Server it is deleted), and a
non-zero `.pf` count within a few minutes of use. **If this fails, the SKU is wrong — stop and check the
media.**

- [ ] **Step 5: Install the telemetry stack — Sysmon, audit policy, Elastic Agent**

Follow `docs/BUILD_FROM_SCRATCH.md` §10 verbatim.

- [ ] **Step 6: Verify the guest reports into so01**

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_count?q=host.name:ws03"
```

Expected: non-zero. Remember `host.name` is lowercase in Elasticsearch.

- [ ] **Step 7: Stage it powered-off**

```bash
qm set 220 --onboot 0
qm shutdown 220
```

- [ ] **Step 8: Commit**

### Task 3.3: Clone the remaining guests from the verified template

- [ ] **Step 1: Convert ws03 into a template after sysprep**

```powershell
C:\Windows\System32\Sysprep\sysprep.exe /generalize /oobe /shutdown
```

- [ ] **Step 2: Create linked clones**

```bash
qm template 220
for i in 221 222 223 224 225 226 227; do
  qm clone 220 $i --name ws$((i-200)) --full 0
  qm set $i --onboot 0
done
```

Linked clones keep the disk cost of eight workstations close to one, which matters for the 5 TB pool and
for the size of the backup you carry.

- [ ] **Step 3: Verify each clone has a UNIQUE MAC**

```bash
for i in 220 221 222 223 224 225 226 227; do qm config $i | grep -oE 'macaddr=[0-9A-F:]+'; done | sort | uniq -d
```

Expected: **no output.** Duplicate MACs will produce two guests fighting over one DHCP lease, which
presents as intermittent network loss and is miserable to diagnose.

- [ ] **Step 4: Commit**

---

## Phase 4 — More host telemetry

The rack has RAM to spare; use it for signal, not just for more idle guests.

### Task 4.1: Bring Sysmon volume into band on the existing guests

This is the outstanding Step 3 gate: measured 24 h volume is 24,391 on ws01 against a 5,000–10,000 target,
and the live config is SwiftOnSecurity's `sysmonconfig-swift.xml`.

- [ ] **Step 1: Deploy an upstream config UNMODIFIED to one host only**

sysmon-modular ships prebuilt configs — use one as published rather than hand-selecting modules:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/olafhartong/sysmon-modular/master/sysmonconfig.xml -OutFile sysmonconfig-modular.xml
.\Sysmon64.exe -c sysmonconfig-modular.xml
.\Sysmon64.exe -c        # confirm which config is live
```

- [ ] **Step 2: Wait a full 24 h, then measure that host only**

```bash
sudo bash tools/audit/sysmon-volume-gate.sh
```

- [ ] **Step 3: Compare and decide**

If modular is also over budget, the honest conclusion is that **this range's endpoints are busier than the
published enterprise baseline** — they run simulated users ten hours a day — and the gate should be
re-based against a measured idle-endpoint figure rather than tuned into compliance by removing coverage.
Record whichever conclusion the data supports.

- [ ] **Step 4: Commit the measurement**

### Task 4.2: Add the telemetry the extra RAM makes affordable

- [ ] **Step 1: Give so01 more heap now that it is not sharing a host**

```bash
qm set 170 --memory 65536
```

- [ ] **Step 2: Verify Elasticsearch actually took the memory**

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/_cat/nodes?h=name,heap.percent,ram.percent"
```

- [ ] **Step 3: Commit**

---

## Phase 5 — Package for export

### Task 5.1: Stand up PBS with a removable datastore

**Files:** Create `migration/runbook-restore.md`

- [ ] **Step 1: Install PBS as a guest on cthuwu**

```bash
qm create 400 --name pbs01 --memory 8192 --cores 4 --ostype l26 \
  --scsi0 local-zfs:64 --net0 virtio,bridge=vmbr1 --cdrom local:iso/pbs.iso
```

- [ ] **Step 2: Pass the external drive through to it**

```bash
ls -l /dev/disk/by-id/          # identify the external drive by STABLE id, never /dev/sdX
qm set 400 --scsi1 /dev/disk/by-id/<EXTERNAL_DRIVE_ID>
```

Use `by-id`. Device names reorder between boots — this has already caused an outage in this project once.

- [ ] **Step 3: Create it as a removable datastore in the PBS UI**

*Datastore → Add → Removable*, backed by the passed-through disk.

- [ ] **Step 4: Verify it mounts and is writable**

```bash
proxmox-backup-manager datastore list
```

- [ ] **Step 5: Commit**

### Task 5.2: Capture what vzdump does NOT carry

- [ ] **Step 1: Archive the host configuration**

```bash
tar czf /mnt/external/hostconfig-$(date +%F).tgz \
  /etc/network/interfaces /etc/pve/firewall /etc/pve/storage.cfg \
  /etc/modprobe.d/zfs.conf /etc/hosts /etc/resolv.conf \
  /etc/systemd/system/span*.service /root/.ssh/config
```

- [ ] **Step 2: Write the ZFS ARC cap into that archive**

```bash
cat > /etc/modprobe.d/zfs.conf <<'EOF'
# 384 GB host: cap ARC at 32 GB so it does not silently reserve 192 GB (the 50% default)
# away from guests. Raise deliberately if the pool proves read-heavy.
options zfs zfs_arc_max=34359738368
EOF
update-initramfs -u
```

- [ ] **Step 3: Record the startup order** — the environment must come up in dependency order

```bash
qm set 300 --onboot 1 --startup order=1,up=60      # fw01: gateway, DHCP, DNS
qm set 150 --onboot 1 --startup order=2,up=90      # dc01: directory and time
qm set 310 --onboot 1 --startup order=3,up=60      # cthost01: containers
qm set 170 --onboot 1 --startup order=4,up=120     # so01: sensor
# workstations and expansion guests stay onboot=0 until you want them
```

Firewall first, then the DC, then everything that authenticates against it. Without ordering, guests boot
before DHCP and DNS exist and come up misconfigured.

- [ ] **Step 4: Verify the order is recorded**

```bash
grep -H -E 'onboot|startup' /etc/pve/qemu-server/*.conf
```

- [ ] **Step 5: Commit**

### Task 5.3: Full backup of every guest

- [ ] **Step 1: Back up everything to the removable datastore**

```bash
vzdump --all 1 --storage pbs-removable --mode snapshot --notes-template '{{guestname}} pre-migration'
```

- [ ] **Step 2: Exclude what should not travel**

Per the operator's note, the `rick` guest is excluded:

```bash
vzdump --all 1 --exclude <RICK_VMID> --storage pbs-removable --mode snapshot
```

- [ ] **Step 3: VERIFY the backups — do not skip this**

```bash
proxmox-backup-client list --repository <REPO>
proxmox-backup-manager verify <DATASTORE>
```

Expected: every guest present, verification clean. **An unverified backup is not a backup**, and this one
is the only copy that crosses the room.

- [ ] **Step 4: Record a manifest to check against after restore**

```bash
qm list > /mnt/external/MANIFEST-guests.txt
pct list >> /mnt/external/MANIFEST-guests.txt
sha256sum /mnt/external/hostconfig-*.tgz >> /mnt/external/MANIFEST-guests.txt
```

- [ ] **Step 5: Commit**

---

## Phase 6 — Restore on the C240

### Task 6.1: Prepare the target host

- [ ] **Step 1: Confirm the storage controller presents raw disks**

```bash
lsblk -o NAME,SIZE,TYPE,MODEL
ls -l /dev/disk/by-id/
```

Expected: individual physical disks, not a single RAID virtual disk. If you see one big VD, the RAID
controller is not in JBOD/HBA mode — fix that **before** creating the pool.

- [ ] **Step 2: Install Proxmox VE to the 1 TB OS drive**

- [ ] **Step 3: Create the ZFS pool on the remaining disks**

```bash
zpool create -o ashift=12 tank raidz2 /dev/disk/by-id/<ID1> ... 
zfs set compression=lz4 tank
```

- [ ] **Step 4: Apply the ARC cap before restoring anything**

```bash
tar xzf /mnt/external/hostconfig-*.tgz -C / etc/modprobe.d/zfs.conf
update-initramfs -u && reboot
```

- [ ] **Step 5: Verify the cap took**

```bash
cat /sys/module/zfs/parameters/zfs_arc_max      # expect 34359738368
```

### Task 6.2: Recreate the network before restoring guests

- [ ] **Step 1: Map old NIC names to new**

```bash
ip -br link                # the C240's NICs will NOT be named like cthuwu's
```

- [ ] **Step 2: Restore the interfaces file and edit only the physical port names**

```bash
tar xzf /mnt/external/hostconfig-*.tgz -C /tmp etc/network/interfaces
# copy in, then replace the old uplink name with the C240's actual one
```

Every `vmbr*` definition transfers unchanged — that is what preserves segmentation and lets every guest
keep its address.

- [ ] **Step 3: Apply and verify all bridges exist**

```bash
ifreload -a
ip -br link show type bridge
```

Expected: `vmbr0 vmbr1 vmbr5 vmbr10 vmbr20 vmbr30 vmbr40 vmbr45 vmbr60 vmbr61 vmbr70 vmbr91 vmbr99`

- [ ] **Step 4: Restore the span systemd unit and confirm the mirror**

### Task 6.3: Restore the guests

- [ ] **Step 1: Mount the removable datastore and add it as storage**

- [ ] **Step 2: Restore in dependency order, preserving VM IDs**

```bash
for id in 300 150 310 170; do
  qmrestore <backup-for-$id> $id --storage tank
done
```

- [ ] **Step 3: Verify MACs survived**

```bash
for id in $(qm list | awk 'NR>1{print $1}'); do qm config $id | grep -oE 'macaddr=[0-9A-F:]+'; done \
  | sort > /tmp/macs-new.txt
diff <(grep -oE 'macaddr=[0-9A-F:]+' migration/inventory/cthuwu.txt | sort) /tmp/macs-new.txt
```

Expected: **no differences.** Any change breaks a DHCP reservation and possibly an AD computer account.

- [ ] **Step 4: Boot in order and verify each tier before the next**

```bash
qm start 300 && sleep 60     # fw01 - then check it serves DHCP and DNS
qm start 150 && sleep 90     # dc01 - then check it answers LDAP
qm start 310 && sleep 60     # cthost01 - then check containers start
qm start 170 && sleep 120    # so01 - then check so-status
```

---

## Phase 7 — Post-restore verification

### Task 7.1: Run the gates

**Files:** Create `migration/verify/post-restore.sh`

- [ ] **Step 1: Write the gate script**

Each condition named separately with explicit PASS/FAIL — a single summary verdict hides a gate that
passed for the wrong reason.

```bash
#!/bin/bash
# Runs ON the restored host. Every claim gets its own PASS/FAIL.
fail=0
chk(){ if eval "$2" >/dev/null 2>&1; then echo "[PASS] $1"; else echo "[FAIL] $1"; fail=1; fi; }

chk "all expected bridges exist"       "[ \$(ip -br link show type bridge | wc -l) -ge 13 ]"
chk "fw01 running"                      "qm status 300 | grep -q running"
chk "dc01 running"                      "qm status 150 | grep -q running"
chk "cthost01 running"                  "qm status 310 | grep -q running"
chk "so01 running"                      "qm status 170 | grep -q running"
chk "ZFS ARC capped"                    "[ \$(cat /sys/module/zfs/parameters/zfs_arc_max) -le 34359738368 ]"
chk "no duplicate guest MACs"           "! (for i in \$(qm list|awk 'NR>1{print \$1}'); do qm config \$i|grep -oE 'macaddr=[0-9A-F:]+'; done | sort | uniq -d | grep -q .)"
chk "span interface present"            "ip link show spanmir"
exit $fail
```

- [ ] **Step 2: Verify the estate is actually functioning, not just running**

```bash
# DNS resolves inside the range
ssh <A_CONTAINER> 'nslookup fs01.range.lan 10.30.10.10'
# a domain logon works
ssh <A_WINDOWS_GUEST> 'nltest /dsgetdc:lab.local'
# telemetry is flowing again
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
  "https://localhost:9200/logs-*/_count?q=@timestamp:[now-15m%20TO%20now]"
```

- [ ] **Step 3: Compare against the pre-migration manifest**

```bash
diff /mnt/external/MANIFEST-guests.txt <(qm list; pct list)
```

- [ ] **Step 4: Commit the results**

### Task 7.2: Power on the expansion estate

- [ ] **Step 1: Bring the staged guests up in batches, watching RAM**

```bash
for id in 220 221 222 223; do qm start $id; sleep 30; free -g; done
```

- [ ] **Step 2: Stop if free memory drops below 32 GB** and re-plan rather than overcommitting.

- [ ] **Step 3: Set the ones you want permanently running to `onboot=1`**

- [ ] **Step 4: Re-run the Sysmon and traffic gates with the larger estate**

- [ ] **Step 5: Commit**

---

## Self-review notes

- **Spec coverage.** Consolidation (Phase 2), expansion (Phase 3), segmentation (Tasks 2.1/6.2), more
  telemetry (Phase 4), external-drive packaging (Phase 5), restore-and-power-on (Phases 6–7). The `rick`
  exclusion is Task 5.3 Step 2 and is flagged as needing confirmation.
- **Known risk concentration.** Task 2.2 (moving Security Onion while keeping its IP) is the single most
  likely step to fail. It is deliberately early so that a failure there is discovered while the old
  environment still exists and can be rolled back to.
- **Not covered on purpose.** Atomic Red Team stays deferred behind the benign-baseline order. JA4+
  licensing remains an operator decision.
