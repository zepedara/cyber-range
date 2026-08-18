# Build the Cyber Range on a Cisco UCS C240 M4 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a complete enterprise-mimicking cyber range on a single Cisco UCS C240 M4 (24-thread
Xeon, 384 GB RAM), producing hunt-grade telemetry across network, endpoint, identity and application
tiers into Security Onion.

**Architecture:** One Proxmox host carries three things: a Security Onion sensor/SIEM VM, an OPNsense
firewall VM that owns every VLAN gateway, and a container-host VM running Incus that holds most of
the fake company. Windows guests run as VMs directly on Proxmox. Every VLAN is mirrored to Security
Onion through a dedicated SPAN bridge, so Zeek sees east-west traffic and not just egress.

**Tech Stack:** Proxmox VE 9.x, Incus, OPNsense 25.7, Security Onion 3.2.0 (Zeek, Suricata, Elastic,
Kibana), Elastic Agent + Elastic Defend, Velociraptor (analysis station only), GHOSTS, Windows Server
2022 / Windows 10 LTSC, Python 3, Bash, PowerShell.

---

## READ THIS FIRST — you are Claude Code, and this project has a specific failure mode

This range was built once already. The single largest source of wasted effort was **not** difficult
technology — it was **concluding things from bad measurements**. In the original build, at least
eight confident diagnoses were later proven wrong, and three tasks were marked "complete" without any
measurement at all.

Adopt these rules before you touch anything:

1. **Never mark a step done without a real measurement.** Not "the service is running" — an actual
   query returning actual numbers from Elasticsearch.
2. **Never measure across a change.** If you changed something at 18:22, query `gte 18:25`. Windows
   that straddle a change produced five separate false conclusions in the original build.
3. **A short window is not a small version of a long window.** Cardinality metrics (unique JA3,
   unique user-agents) are *systematically* lower on short windows. Use ≥ 20 minutes, ideally 60, for
   any "how many distinct X" gate. Ratios (percentages) are safe on short windows; counts are not.
4. **When something returns zero, prove the query would have found it.** Run the same query with the
   filter removed. "X is absent" is the single most dangerous claim in this project, and it was wrong
   four times.
5. **A control that does not share the path is not a control.** If host A works and host B does not,
   confirm A and B traverse the same firewall, bridge and NAT before concluding anything about B.
6. **Research the exact error before retrying.** Do not permute flags. Every trap in Appendix A cost
   real time precisely because it looked like a flag problem and was not.

---

## Global Constraints

- **Detection content is RETRIEVED from upstream, never authored by you.** Sysmon config comes from
  `olafhartong/sysmon-modular` or `SwiftOnSecurity/sysmon-config`; Sigma rules from `SigmaHQ/sigma`;
  atomics from `redcanaryco/atomic-red-team`. Record the commit hash you fetched.
- **No live malware.** Adversary emulation uses Atomic Red Team / CALDERA / your own C2 only.
- **Locked tool stack:** Security Onion + Kibana as SIEM, Elastic Agent + Elastic Defend as EDR,
  Velociraptor for forensics. These are training requirements, not choices.
- **Velociraptor is an analysis station only** — no agents on endpoints. Acquire with offline
  collectors, then import. This is deliberate: it forces the analyst to practise real acquisition.
- **The estate should be data, not script content.** Hostnames, addresses, roles, users and domains
  belong in `estate/*.yaml`; scripts read them. The original build violated this and became
  unreproducible. See Part 9.
- **Finish the benign baseline BEFORE any adversary emulation.** An unrealistic baseline lets an
  analyst find attacks by contrast rather than by indicator, which destroys the training value.

---

## Part 0 — What exists in this repository, and what does not

Read these before building. They are the measured record of the first build.

| File | What it gives you |
|---|---|
| `docs/superpowers/specs/2026-08-14-unified-cyber-range-design.md` | The original design and the reasoning behind each decision |
| `docs/VERIFIED_STATUS.md` | **The most valuable file.** Every gate, the number behind it, and explicit corrections where a previous claim was wrong |
| `docs/BUILD_FROM_SCRATCH.md` | Build using native commands and upstream packages |
| `noise/containers/rangenoise.sh` | Diurnal, role-aware traffic generator for Linux containers |
| `noise/windows/domain_noise.ps1` | Windows-side domain activity |
| `tools/ad/*.ps1` | Turn a bare AD into a real HR directory (org chart, names, service-account cleanup, 5136 auditing) |
| `tools/audit/sysmon-volume-gate.sh` | Measures Sysmon volume per host against the enterprise target |
| `tools/db/load-corpdb-from-ad.py` | Builds an HR database from AD so SIEM→HR pivots work |

**Not built, and you will have to create them:** `estate/`, `render/`, `roles/`, `attack/`. The
README describes them; they do not exist on any branch. Part 9 covers building them properly, and you
are in a *better* position to do it than the original build was, because you are starting greenfield.

---

## Part 1 — The C240 M4 itself

### 1.1 The storage controller will waste your afternoon if you skip this

The Cisco 12G SAS Modular RAID controller **does not present disks to the OS as raw devices by
default**, and JBOD **cannot be enabled from CIMC's web UI**. It is a three-step sequence:

1. Delete any existing Virtual Drives.
2. Deleting the VDs leaves the physical disks in **`Unconfigured Good`**.
3. **Enable JBOD in the pre-boot RAID menu (`Ctrl+R` during POST).** ← the step everyone misses

> "JBOD is disabled on the controller by default, and cannot be enabled on the 12G Controller via the
> CIMC, only the pre-boot RAID Configuration menu (CTRL+R)."
> — Cisco, *C-Series: Enable JBOD on Cisco 12G SAS Modular Raid Controller*

**`Unconfigured Good` is NOT JBOD.** In that state the controller still claims the disks, `lsblk` may
show nothing usable, and ZFS will have no disks to build a pool from. This is the classic
"looks finished, isn't" state.

- [ ] **Step 1: Enable JBOD at the controller, then verify from the OS**

```bash
# 1. every data disk appears as a whole raw block device
lsblk -dno NAME,SIZE,MODEL,TRAN

# 2. SMART passes through - proves the disk is not behind a RAID abstraction
smartctl -i /dev/sda              # expect a real model/serial, not a virtual-disk identity
# if that fails, the disk is STILL behind MegaRAID:
smartctl -i -d megaraid,0 /dev/sda

# 3. controller personality
lspci -nn | grep -iE 'raid|sas'
storcli64 /c0 show 2>/dev/null | grep -iE 'JBOD|Personality'
```

If SMART only answers via `-d megaraid,N`, the disks are still behind the RAID layer. ZFS will work
but you lose per-disk SMART, error handling and predictable replacement.

**Do NOT fall back to per-disk single-drive RAID0.** It is the common workaround and it is wrong
here: it masks SMART, interposes the controller cache, and makes disk replacement painful. If JBOD
cannot be enabled, source an HBA (the `UCSC-SAS12GHBA` is the right part for ZFS).

### 1.2 BIOS settings that matter

- [ ] **Step 2: Set and verify virtualization support**

Enable in BIOS: **VT-x**, **VT-d** (needed if you ever pass through a NIC or GPU), and leave
**hyper-threading ON** (you need all 24 threads).

Verify after Proxmox installs:

```bash
lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket'
grep -c -E 'vmx' /proc/cpuinfo        # non-zero = VT-x active
dmesg | grep -iE 'DMAR|IOMMU' | head  # IOMMU present = VT-d active
```

Expected: 24 logical CPUs. The C240 M4 is Xeon E5-2600 v3/v4 — verify the exact model, because
E5 v3 vs v4 changes AES-NI throughput and therefore how much TLS the range can generate.

### 1.3 Remote access

CIMC gives you remote KVM and power control. Configure it on its own management IP and **do not put
it on a range VLAN**. You will need it when a network change locks you out of Proxmox — which will
happen at least once, because you are about to rebuild the host's networking.

---

## Part 2 — Sizing: your hardware inverts the original build's constraints

This is the single most important planning section. **Do not copy the original sizing.**

| | Original host (cthuwu) | **Your C240 M4** |
|---|---|---|
| Threads | 48 | **24** |
| RAM | 125 GB | **384 GB** |
| Bound by | **RAM** | **CPU** |

The original build was RAM-starved and CPU-rich; it shut VMs down to free memory. You are the
opposite. This has concrete consequences:

### 2.1 Containers win even harder for you

45 VMs means 45 kernels, 45 timer interrupts and 45 Elastic Agents all scheduling against **24
threads**. 45 containers share one kernel. **Put as much of the fake company as possible in
containers**, and reserve VMs for what genuinely requires a Windows kernel: the domain controller,
the workstations you want Sysmon/Defend telemetry from, and the firewall.

### 2.2 Recommended allocation

Total 384 GB. Leave the host ~16 GB and cap ZFS ARC explicitly.

| Component | vCPU | RAM | Notes |
|---|---|---|---|
| Proxmox host | — | 16 GB | |
| ZFS ARC cap | — | **32 GB** | Set explicitly; ZFS will eat everything otherwise |
| **Security Onion** | **8** | **64–96 GB** | The heaviest component by far |
| OPNsense (fw01) | 2 | 4 GB | Owns every VLAN gateway |
| Container host (Incus) | 6 | 32–64 GB | Holds 30–100 containers |
| Windows DC | 2 | 6 GB | |
| Windows workstations ×6 | 2 each | 6 GB each | 12 vCPU, 36 GB total |
| Velociraptor station | 2 | 8 GB | Analysis only |
| **Headroom** | — | **~120 GB** | Deliberate — see Part 9 expansion |

**vCPU is oversubscribed on purpose** (that is normal and fine), but watch steal time. If
`%st` in `top` inside guests climbs above ~5%, you have over-committed CPU and must reduce Zeek
workers or container count — *not* RAM.

### 2.3 The Elasticsearch heap trap

**Never set the ES heap above ~31 GB.** Above roughly 32 GB the JVM loses compressed ordinary object
pointers ("compressed oops") and each object reference doubles in size — a 32 GB heap can hold *less*
usable data than a 31 GB one. With 96 GB given to the Security Onion VM, set heap to 31 GB and let
the remaining RAM serve the OS page cache, which is what Lucene actually wants.

- [ ] **Step 1: Set and verify the ES heap**

```bash
# on the Security Onion node
sudo grep -rE '^-Xm[sx]' /opt/so/conf/elasticsearch/jvm.options.d/ 2>/dev/null
# verify what the running process actually got:
ps aux | grep -o '\-Xmx[0-9]*[gm]' | head -1
```

Expected: `-Xmx31g` and `-Xms31g` (equal values — never let the heap resize at runtime).

### 2.4 Zeek workers against 24 threads

Zeek is CPU-bound and is the component most likely to starve your host. Security Onion sizes roughly
one worker per ~200 Mbps–1 Gbps of monitored traffic. A lab range generates far less than a real
enterprise, so **start with 4 workers and measure**, rather than provisioning for line rate.

Critically — see Appendix A — `capture_loss` **cannot** tell you the sensor is starved of traffic; it
only measures gaps in what Zeek *received*. Use Part 8's packet-rate check instead.

---

## Part 3 — Proxmox install, storage, and the network

### 3.1 Install

- [ ] **Step 1: Install Proxmox VE 9.x with ZFS on the OS disk**

Use ZFS RAID1 if you have two OS disks; single-disk ZFS is acceptable for a lab. Then build the data
pool from the JBOD disks:

```bash
# adjust device names from `lsblk` output - ALWAYS use /dev/disk/by-id, never /dev/sdX
ls -l /dev/disk/by-id/ | grep -v part

zpool create -o ashift=12 rangepool \
  mirror /dev/disk/by-id/scsi-XXXX /dev/disk/by-id/scsi-YYYY \
  mirror /dev/disk/by-id/scsi-ZZZZ /dev/disk/by-id/scsi-WWWW

zfs set compression=lz4 rangepool
zfs set atime=off rangepool
```

**Use `/dev/disk/by-id` everywhere.** NVMe and SCSI device names can swap between boots; the original
build hit exactly this and it is why every fstab entry there is UUID-only.

- [ ] **Step 2: Cap the ARC and verify it took**

```bash
echo "options zfs zfs_arc_max=34359738368" | sudo tee /etc/modprobe.d/zfs.conf   # 32 GiB
sudo update-initramfs -u -k all
sudo reboot
# after reboot - verify, do not assume:
cat /sys/module/zfs/parameters/zfs_arc_max
awk '/^size/ {print "ARC now: " $3/1073741824 " GiB"}' /proc/spl/kstat/zfs/arcstats
```

- [ ] **Step 3: Add the Proxmox storage and commit**

```bash
pvesm add zfspool rangestore --pool rangepool --content images,rootdir
pvesm status
```

### 3.2 Networking — the part that will lock you out

The range needs many isolated VLANs plus a mirror path to the sensor. Build it in this order and keep
CIMC KVM open.

- [ ] **Step 4: Create the bridges**

`/etc/network/interfaces` — one uplink bridge, one bridge per range segment, one SPAN bridge:

```
auto lo
iface lo inet loopback

# management / uplink - this is how you reach Proxmox. Do not break it.
auto vmbr0
iface vmbr0 inet static
    address 192.0.2.10/24
    gateway 192.0.2.1
    bridge-ports eno1
    bridge-stp off
    bridge-fd 0

# range segments - NO bridge-ports means isolated, host-only. That is what you want.
auto vmbr10
iface vmbr10 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0

# ... repeat vmbr20, vmbr30, vmbr40, vmbr45, vmbr60, vmbr70, vmbr99 ...

# SPAN bridge - carries mirrored copies of everything to Security Onion
auto vmbr91
iface vmbr91 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up ip link set vmbr91 type bridge ageing_time 0
    post-up ip link set vmbr91 type bridge_slave flood on   || true
    post-up echo 0 > /sys/class/net/vmbr91/bridge/ageing_time
```

**Three hard-won SPAN rules — all three are required or your sensor sees almost nothing:**

1. **Learning must be OFF and ageing_time 0 on the SPAN bridge.** Otherwise the bridge learns MAC
   addresses and stops flooding traffic to the sensor port. In the original build this starved Zeek
   to **3 packets per 10 seconds** while `capture_loss` cheerfully reported **0.0%**.
2. **`tc mirred` to a bridge master does not flood.** Mirroring directly onto the bridge device
   delivers only to the learned port. **Mirror into a veth pair** whose other end is a bridge port.
3. **Jumbo frames must be set `post-up`, not inside the stanza.** Setting MTU in the interface stanza
   on a bridge caused a host-wide outage in the original build. And the sensor's monitor interface
   must be MTU 9000 if any mirrored path uses jumbo, or Zeek silently drops large frames.

- [ ] **Step 5: Verify the SPAN bridge before trusting it**

```bash
# learning must be 0, ageing 0
cat /sys/class/net/vmbr91/bridge/ageing_time
for p in /sys/class/net/vmbr91/brif/*; do
  echo "$p learning=$(cat $p/learning) flood=$(cat $p/flood)"
done
```

Expected: `ageing_time` 0, and every port `flood=1`.

---

## Part 4 — Security Onion

### 4.1 Install

- [ ] **Step 1: Install Security Onion 3.2.0 as a standalone node**

Give it 8 vCPU, 64–96 GB RAM, and **two** NICs: one management (on `vmbr0` or a mgmt VLAN) and one
**monitor** NIC on the SPAN bridge `vmbr91`.

During setup choose **Standalone**, and when asked for the monitor interface pick the SPAN NIC. Do
not give the monitor NIC an IP address.

- [ ] **Step 2: Verify the install is genuinely healthy**

```bash
sudo so-status                       # every service should be OK, not just running
sudo salt-call state.highstate       # converges config; run it after ANY manual change
```

```bash
# Elasticsearch health - note -sSk, its curl.config carries NO CA
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
  "https://localhost:9200/_cluster/health?pretty" | head -12
```

Expected: `"status" : "green"`. Yellow on a standalone node usually means replica shards that can
never allocate — acceptable, but understand *why* before you accept it.

### 4.2 Make the sensor see east-west traffic

A sensor that only sees egress cannot teach lateral-movement hunting. Mirror **every** segment.

- [ ] **Step 3: Mirror each range bridge into the SPAN bridge via veth**

For each range bridge (`vmbrNN`), create a veth pair, put one end in `vmbr91`, and mirror the range
bridge into it:

```bash
NN=10
ip link add span$NN type veth peer name span${NN}p
ip link set span$NN up
ip link set span${NN}p up
ip link set span${NN}p master vmbr91

tc qdisc add dev vmbr$NN ingress
tc filter add dev vmbr$NN parent ffff: matchall \
   action mirred egress mirror dev span$NN
tc qdisc add dev vmbr$NN handle 1: root prio
tc filter add dev vmbr$NN parent 1: matchall \
   action mirred egress mirror dev span$NN
```

Persist these; they do not survive reboot on their own.

- [ ] **Step 4: PROVE the sensor sees all segments — do not assume**

```bash
# on the Security Onion node, count packets per VLAN actually arriving
sudo timeout 30 tcpdump -nni <monitor-if> -e 2>/dev/null | grep -oE 'vlan [0-9]+' | sort | uniq -c
```

Expected: one line per VLAN you built, all non-trivial. **If a VLAN is missing, the mirror for that
bridge is broken — `capture_loss` will NOT tell you.**

---

## Part 5 — The container edition (most of the company)

### 5.1 Container host

- [ ] **Step 1: Build a container-host VM running Incus**

Ubuntu 24.04, 6 vCPU, 32–64 GB RAM, one NIC per VLAN it serves (or a trunk). Install Incus from
upstream, then create one bridge profile per segment so containers land on the right VLAN.

**Trap:** the container host must have its DNS and NTP pointed at *range-internal* servers, not your
house infrastructure. In the original build the container host silently depended on the house router
for DNS and a public NTP pool; both would have vanished on migration. Check with:

```bash
resolvectl status | grep -A2 'DNS Servers'
timedatectl show-timesync --all | grep -E 'ServerName|ServerAddress'
```

### 5.2 The estate

Build roughly this shape — adjust freely, you have RAM to spare:

| Segment | VLAN | Hosts |
|---|---|---|
| MGMT | 20 | jump host, monitoring, backup |
| SERVERS | 10 | DNS/DC, file, database, app, mail, proxy, CA |
| USERS | 20 | workstations |
| DMZ | 30 | web, mail relay |
| VOICE | 40 | PBX, phones |
| OT/IoT | 45 | cameras, badge readers, HVAC |
| BRANCH | 60 | remote-office workstations + file server |
| GUEST/BYOD | 70 | personal devices |
| FAKE-INTERNET | 99 | external sites, update services, the pivot target |

**Design the policy matrix deliberately, and log the denies.** GUEST and OT/IoT should *not* reach
the DMZ or SERVERS. This matters for realism — but see the next warning.

> **The single most instructive bug from the original build.** The traffic generator browsed internal
> sites by *name*, and the guard that suppressed those requests on denied segments tested the **name
> suffix**. But the fake-internet names resolved to the *same* web host as the internal names. So
> ~78% of requests bypassed the guard, and IoT/voice/BYOD containers hammered a DMZ host they were
> correctly denied — generating **4,779 unanswered SYNs per hour** of pure artifact, which showed up
> as a 34.8% "connection failure rate".
>
> **Guard by RESOLVED ADDRESS, never by name shape.** And keep a small trickle (~3%) of denied
> attempts, because real networks do contain devices attempting blocked connections — the flood was
> the artifact, not the existence of denies.

### 5.3 Noise generation

Use `noise/containers/rangenoise.sh` as the starting point. The design lessons that matter:

- **Role-aware, not uniform.** A camera, a PBX and a workstation must not generate the same traffic.
- **Diurnal.** Traffic must follow a working-day curve. The original achieved 5.5× peak-to-trough on
  containers. Verify the curve is not *inverted* — that happened and went unnoticed for a while.
- **Client diversity is per-host configuration, not volume.** See Part 8.4; this is subtle and cost
  the original build several wrong turns.
- **Beware your own tooling as a telemetry source.** The harness, SSH command batches and the
  simulation agent all generate logs. In the original build the GHOSTS agent's own API polling
  became **31% of all plaintext HTTP**, and auditd was **78% self-noise**.

---

## Part 6 — The Windows edition

- [ ] **Step 1: Build a Windows domain controller and 4–6 workstations**

**Use Windows 10 Enterprise LTSC 2021 for workstations, not Server.** The original build used Server
2022 images as "workstations" and consequently **cannot produce Prefetch artifacts at all** (Prefetch
is disabled by default on Server), which removes an entire forensic artifact class from every
exercise. Do not repeat this. Also note Elastic Defend does not support Windows IoT editions.

- [ ] **Step 2: Install Sysmon from an upstream config and record the hash**

```powershell
# RETRIEVE, never author
git clone https://github.com/olafhartong/sysmon-modular
cd sysmon-modular
git rev-parse HEAD                      # record this hash in your notes
.\Merge-SysmonXml.ps1 -AsString | Out-File -Encoding utf8 sysmonconfig.xml
Sysmon64.exe -accepteula -i sysmonconfig.xml
```

- [ ] **Step 3: Install Elastic Agent + Defend and verify enrollment**

```powershell
# the service name has a SPACE in it - Get-Service ElasticAgent returns nothing
Get-Service "Elastic Agent" | Format-List Name,Status,StartType
& "C:\Program Files\Elastic\Agent\elastic-agent.exe" status
```

**Trap:** enrollment tokens are base64 and often end in `=`. **Never parse them with `cut -d=`** —
you will truncate the token and get a confusing auth failure.

- [ ] **Step 4: Make Active Directory look like a real company**

A bare AD with 10 users teaches nothing. Use `tools/ad/*.ps1` from this repo to build a 4-level org
chart with real names, departments and managers, clean up service accounts, and enable
attribute-change auditing (event 5136). Then use `tools/db/load-corpdb-from-ad.py` to build an HR
database, so an analyst can pivot from a SIEM hit to "who is this person, and who is their manager?"

- [ ] **Step 5: Verify Windows telemetry is actually arriving**

```bash
# host.name is LOWERCASE in Elasticsearch
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
 "query":{"bool":{"filter":[
   {"term":{"event.dataset":"windows.sysmon_operational"}},
   {"range":{"@timestamp":{"gte":"now-60m"}}}]}},
 "aggs":{"h":{"terms":{"field":"host.name","size":10}},
         "e":{"terms":{"field":"event.code","size":20}}}}' | python3 -m json.tool | head -40
```

Expected: every workstation present, and a spread of event codes (1, 3, 7, 10, 11, 12, 13, 22).

---

## Part 7 — Volume control: the target is 5,000–10,000 events/endpoint/day

A default Sysmon config on a busy host produces **~440,000 docs/host/day**. That is 40–90× a normal
enterprise endpoint and it will both drown your storage and make hunting unrealistically easy.

- [ ] **Step 1: Measure before tuning**

Use `tools/audit/sysmon-volume-gate.sh`, or directly:

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
 "query":{"bool":{"filter":[
   {"term":{"event.dataset":"windows.sysmon_operational"}},
   {"range":{"@timestamp":{"gte":"now-60m"}}}]}},
 "aggs":{"h":{"terms":{"field":"host.name","size":10}}}}' | python3 -c "
import sys,json
d=json.load(sys.stdin)
for b in d['aggregations']['h']['buckets']:
    print('%-12s %6d/hr  -> %7d/day' % (b['key'], b['doc_count'], b['doc_count']*24))"
```

- [ ] **Step 2: Reduce with the correct lever**

Levers, in order of preference:

1. **Sysmon config exclusions** (upstream sysmon-modular already has good ones) — the right lever.
2. **Generator pacing** — how often simulated users act.
3. **auditd rules on Linux** — `proctitle` and raw `syscall` records were **78% of 3M docs** in the
   original build. Exclude them by msgtype. Note the ordering trap in Appendix A.

> **Do not reduce volume by throttling browsers.** In the original build this worked for volume and
> silently broke a *different* gate: browser TLS diversity collapsed from 79 unique JA3 to 6. See
> Part 8.4 — the correct lever for diversity is more distinct clients, not busier ones.

---

## Part 8 — Verification gates (this is where the value is)

Build these as a script that runs on a timer and appends JSON to a log, so evidence accumulates
without you sitting there. The original build's recorder caught a regression that manual checks
missed.

### 8.1 Use Security Onion's real field names

**Security Onion does not populate stock ECS byte fields on `zeek.conn`.** This wasted real time:

| Wrong (returns 0) | Correct |
|---|---|
| `source.bytes` | `client.bytes` |
| `destination.bytes` | `server.bytes` |
| `source.packets` | `client.packets` |

`event.duration` **is** populated and is in **seconds** — do not divide by 1e9.

The tell that you have the wrong field: **`SF` (cleanly completed) connections also report 0 bytes.**
That is impossible for real traffic, and means the field is absent, not the traffic empty.

### 8.2 Connection health

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
 "track_total_hits":true,
 "query":{"bool":{"filter":[{"term":{"event.dataset":"zeek.conn"}},
   {"term":{"network.transport":"tcp"}},
   {"range":{"@timestamp":{"gte":"now-60m"}}}]}},
 "aggs":{"st":{"terms":{"field":"connection.state","size":15}}}}'
```

**Interpret the states correctly — this is a real trap:**

| State | Meaning | Is it a failure? |
|---|---|---|
| `SF` | Normal establishment and teardown | No |
| `S0` | SYN sent, **no reply** | **YES** |
| `REJ` | Connection refused | **YES** |
| `RSTO`/`RSTR` | **Established, then aborted** | **NO — the session did its work** |

Do **not** gate on "SF ≥ 85%". The original plan did, and it was mis-specified: it counted a
**471 KB / 11,448-packet SMB transfer** that ended in RST as a "failure". Windows legitimately closes
SMB, Kerberos and LDAP with RST, and Logstash's agent input closes idle connections with RST rather
than FIN by design. **Gate on the true failure rate: `(S0 + REJ + RSTOS0 + SH + SHR) / total`.**
Target under ~10%; the original build reached **4.51%**.

### 8.3 Encryption ratio and protocol mix

Real enterprises are mostly encrypted. Check the ratio of `zeek.ssl` to `zeek.http` and make sure it
is not dominated by cleartext, but keep a deliberate cleartext tier so there is something to find.

### 8.4 Client diversity — the subtlest gate

JA3 is a fingerprint of the TLS **ClientHello** (version, cipher list, extensions, curves). It is a
property of **client configuration, not of traffic volume**.

- If your generator picks a TLS profile **per host**, then N hosts can produce at most **N** distinct
  fingerprints — no matter how much traffic they generate. The original build had 31 containers
  sharing a 12-entry profile pool and could never exceed 12. Widening the pool to 80 raised the
  estate from 53 to **67 unique JA3**.
- **Browsers use GREASE**, which randomises extension values per connection, so a single browser can
  inflate JA3 cardinality enormously. That inflation is *not* realism — a browser reusing one
  connection across many page loads (normal keep-alive behaviour) is more realistic and produces
  *fewer* handshakes.
- **TLS session resumption** should be present (~30%+). `curl` cannot do this across processes; you
  need a client that reuses an `SSLContext` and passes the previous `session` object.

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
 "query":{"bool":{"filter":[{"term":{"event.dataset":"zeek.ssl"}},
   {"range":{"@timestamp":{"gte":"now-60m"}}}]}},
 "aggs":{"ja3":{"cardinality":{"field":"hash.ja3"}},
         "top":{"terms":{"field":"hash.ja3","size":1}},
         "res":{"terms":{"field":"ssl.resumed","size":3}}}}'
```

Targets: **≥ 60 unique JA3**, no single fingerprint over **25%**, resumption **≥ 30%**.

### 8.5 Exclude your own control plane from realism gates

Your simulation agent, Elastic Fleet and Logstash ingest are **not part of the company you are
modelling**. In the original build the GHOSTS agent's API polling was 31% of plaintext HTTP and broke
a user-agent diversity gate on its own.

Exclude by **destination** (the control-plane port), and **verify the mapping 1:1 both ways** before
excluding — confirm that all traffic on that port is control plane *and* all control-plane traffic is
on that port. Keep genuinely realistic infrastructure traffic (e.g. `Microsoft-CryptoAPI` CRL fetches
are real Windows behaviour — keep them).

---

## Part 9 — Build the estate as data (do this properly; the original did not)

The original build wrote the enterprise into scripts and host state, so it cannot be reproduced —
only continued. You are greenfield, so do it right from the start.

- [ ] **Step 1: Create `estate/` as the single source of truth**

```yaml
# estate/hosts.yaml
- name: wk01
  role: workstation
  edition: [lxc, pve]
  segment: USERS
  address: {lxc: 10.30.20.101, pve: 10.31.20.101}
  profile: small
- name: dc01
  role: domain-controller
  edition: [pve]
  segment: SERVERS
  address: {pve: 10.31.10.10}
  profile: medium
```

```yaml
# estate/profiles.yaml - named resource profiles, so hardware changes are a re-render
xeon:                 # YOUR host: 24 threads / 384 GB - CPU-bound
  container_default: {cpu: 1, memory: 1GB}
  vm_default:        {cpu: 2, memory: 6GB}
  zeek_workers: 4
  noise_concurrency: 2
cthuwu:               # original host: 48 threads / 125 GB - RAM-bound
  container_default: {cpu: 2, memory: 512MB}
  vm_default:        {cpu: 2, memory: 4GB}
  zeek_workers: 8
  noise_concurrency: 4
```

Also create `estate/segments.yaml` (VLAN, subnet, gateway, policy), `estate/users.yaml` (the org
chart), and `estate/domains.yaml` (the rotating name pool).

- [ ] **Step 2: Write `render/lxc` and `render/pve` that READ the estate**

They must contain no hostnames, addresses or user names — only logic. Test by changing one address in
`estate/hosts.yaml` and confirming the renderer produces the change with no script edit.

- [ ] **Step 3: Prove reproducibility, which is the whole point**

Destroy one container, re-render, and confirm it returns identical. If that works, your range
survives hardware changes as a re-render rather than a rebuild.

---

## Part 10 — Expansion (you have ~120 GB spare; the original had none)

Only after Parts 1–8 pass their gates:

- **More endpoints.** 6 → 15–20 Windows guests is the highest-value expansion for hunting practice,
  but it is **CPU**-bound for you: each Elastic Agent + Defend costs cycles. Add in batches of 4 and
  watch steal time.
- **More container hosts.** RAM-cheap. 100+ containers is realistic on your host.
- **A second AD site / forest trust.** Enables cross-domain lateral movement exercises.
- **Velociraptor station + offline collector workflow.** Required by the locked stack, and it is what
  makes exercises provable rather than just detectable.
- **Adversary emulation, LAST.** Atomic Red Team curated at **TEST level, not technique level**, and
  **never run `-getPrereq` on range hosts** (it downloads real tooling and mutates the estate under
  you). Finish the benign baseline first — otherwise the analyst finds attacks by contrast rather
  than by indicator.

---

# DETAILED BUILD REFERENCE

Parts 0–10 above are the plan and the reasoning. Parts 11–19 below are the concrete build: what to
create, with the actual commands. Work through them in order.

---

## Part 11 — The service catalogue: what the fake company actually contains

The estate must look like a *company*, not a pile of Linux boxes. Every host below has a business
reason to exist, and that reason determines the traffic it generates. **Build the container edition
first** — it is cheap on your hardware and produces most of the network telemetry.

### 11.1 Container edition (~30 hosts minimum; you can afford 60–100)

| Host | Segment | Service | Why it exists (drives its traffic) |
|---|---|---|---|
| `dc01` | SERVERS | dnsmasq/bind + LDAP | Primary resolver. **Every** host queries it. |
| `fs01` | SERVERS | Samba | File shares — generates SMB sessions, 5140/5145 events |
| `sql01` | SERVERS | MariaDB | App backend — steady 3306 connections |
| `app01` | SERVERS | nginx + a small app | Internal business app over TLS |
| `mail01` | SERVERS | Postfix/Dovecot | SMTP/IMAP, the classic phishing delivery path |
| `proxy01` | SERVERS | Squid | Egress proxy — realistic enterprises have one |
| `ca01` | SERVERS | step-ca or OpenSSL CA | **Critical for realism**: issues the internal certs |
| `mon01` | MGMT | Prometheus/Zabbix | Monitoring polls everything on a fixed interval |
| `bk01` | MGMT | restic/rsync target | Nightly backup — big periodic transfers |
| `jump01` | MGMT | OpenSSH | Admin jump host — the box an attacker wants |
| `wk01`–`wk06` | USERS | desktop-ish | Browsing, SMB, mail, DNS |
| `web01` | DMZ | nginx | Public-facing site; hosts the fake-internet names too |
| `mx01` | DMZ | Postfix relay | Inbound mail |
| `pbx01` | VOICE | Asterisk | SIP registrations and calls |
| `phone01`–`03` | VOICE | SIP endpoints | Register to the PBX, place calls |
| `cam01`–`03` | OT/IoT | RTSP/HTTP | Cameras — chatty, low-value, never touch DMZ |
| `badge01` | OT/IoT | HTTP client | Badge reader polling a controller |
| `hvac01` | OT/IoT | Modbus | Building control — Modbus is a great hunting oddity |
| `br-wk01`–`02` | BRANCH | desktop-ish | Remote office over the "WAN" |
| `br-fs01` | BRANCH | Samba | Branch file server |
| `byod01`–`02` | GUEST | phone/laptop-ish | Personal devices, internet-only |
| `ext01`–`04` | FAKE-INTERNET | nginx + certs | The "internet" — news, updates, CDN, SaaS |

**The CA is not optional.** Traffic is only coherent if the domain in DNS is the domain in the TLS
SNI is the name on the certificate. Without an internal CA, every TLS session has a mismatched or
self-signed cert and an analyst can trivially separate real from fake.

### 11.2 VM edition (CPU-bound for you — keep it tight)

| VM | vCPU | RAM | Purpose |
|---|---|---|---|
| `so01` | 8 | 64–96 GB | Security Onion (SIEM + sensor) |
| `fw01` | 2 | 4 GB | OPNsense — owns every VLAN gateway |
| `cthost01` | 6 | 32–64 GB | Incus container host |
| `dc01` | 2 | 6 GB | Windows domain controller |
| `ws01`–`ws04` | 2 | 6 GB | Windows 10 LTSC workstations (Sysmon + Defend) |
| `fs01-win` | 2 | 6 GB | Windows file server |
| `velo01` | 2 | 8 GB | Velociraptor analysis station |
| `ghosts01` | 2 | 4 GB | GHOSTS API server |

---

## Part 12 — OPNsense: VLAN gateways and the policy matrix

`fw01` owns the gateway address of every segment. Nothing routes between segments except through it,
which is what makes the policy matrix real and the denies loggable.

- [ ] **Step 1: Create the VM with one NIC per segment**

```bash
qm create 300 --name fw01 --memory 4096 --cores 2 --cpu host \
  --scsihw virtio-scsi-single --scsi0 rangestore:32 \
  --ide2 local:iso/OPNsense-25.7-dvd-amd64.iso,media=cdrom \
  --boot order=ide2\;scsi0 --ostype l26 --onboot 1

# net0 = WAN/uplink, then one NIC per range segment
qm set 300 --net0 virtio,bridge=vmbr0
qm set 300 --net1 virtio,bridge=vmbr10
qm set 300 --net2 virtio,bridge=vmbr20
qm set 300 --net3 virtio,bridge=vmbr30
qm set 300 --net4 virtio,bridge=vmbr40
qm set 300 --net5 virtio,bridge=vmbr45
qm set 300 --net6 virtio,bridge=vmbr60
qm set 300 --net7 virtio,bridge=vmbr70
qm set 300 --net8 virtio,bridge=vmbr99
qm start 300
```

- [ ] **Step 2: Assign each interface a gateway address**

Give every segment a `/24` with the firewall at `.1`:

| Interface | Segment | Subnet | fw01 address |
|---|---|---|---|
| `vtnet1` | SERVERS | `10.30.10.0/24` | `10.30.10.1` |
| `vtnet2` | USERS | `10.30.20.0/24` | `10.30.20.1` |
| `vtnet3` | DMZ | `10.30.30.0/24` | `10.30.30.1` |
| `vtnet4` | VOICE | `10.30.40.0/24` | `10.30.40.1` |
| `vtnet5` | OT/IoT | `10.30.45.0/24` | `10.30.45.1` |
| `vtnet6` | BRANCH | `10.30.60.0/24` | `10.30.60.1` |
| `vtnet7` | GUEST | `10.30.70.0/24` | `10.30.70.1` |
| `vtnet8` | FAKE-INTERNET | `10.30.99.0/24` | `10.30.99.1` |

- [ ] **Step 3: Write the policy matrix, and LOG the denies**

This is what makes the range teach segmentation. A reasonable starting matrix:

| From ↓ To → | SERVERS | USERS | DMZ | VOICE | OT/IoT | GUEST | FAKE-NET |
|---|---|---|---|---|---|---|---|
| **SERVERS** | ✔ | ✔ | ✔ | ✖ | ✖ | ✖ | ✔ |
| **USERS** | ✔ | ✔ | ✔ | ✖ | ✖ | ✖ | ✔ |
| **DMZ** | limited | ✖ | ✔ | ✖ | ✖ | ✖ | ✔ |
| **VOICE** | DNS only | ✖ | ✖ | ✔ | ✖ | ✖ | ✖ |
| **OT/IoT** | DNS only | ✖ | ✖ | ✖ | ✔ | ✖ | ✖ |
| **GUEST** | DNS only | ✖ | ✖ | ✖ | ✖ | ✔ | ✔ |

**Set every deny rule to log.** Denied traffic is some of the best hunting material you will have,
and it is free.

> **Then make your generators respect it.** This is the trap that produced 4,779 phantom failures per
> hour in the original build. If VOICE can only reach DNS, a phone must not be generating HTTPS to
> the DMZ. Either give each role a policy-appropriate target list, or have the generator resolve its
> target and skip when the address is on an unreachable tier. **Guard on the resolved address, not
> the hostname's shape** — the fake-internet names and the intranet names resolve to the same web
> host, so name-based guards silently pass ~78% of requests through.

- [ ] **Step 4: Point DNS and NTP at range-internal servers**

The firewall is the time root for the whole range. Verify the chain afterwards:

```bash
# on any range host - the stratum should chain back to fw01, and reach should be non-zero
chronyc sources -v   ||  ntpq -pn
```

**OPNsense config trap:** if you edit `config.xml` directly, Unbound settings live under
`<OPNsense><unboundplus>`, **not** `<unbound>`. Editing the wrong element changes nothing and looks
like the setting was ignored.

---

## Part 13 — The container host and the containers, concretely

- [ ] **Step 1: Create the container-host VM with a NIC per segment**

```bash
qm create 310 --name cthost01 --memory 49152 --cores 6 --cpu host \
  --scsihw virtio-scsi-single --scsi0 rangestore:200 \
  --ostype l26 --agent enabled=1 --onboot 1
for i in 10 20 30 40 45 60 70 99; do :; done   # see below - one NIC per segment
qm set 310 --net0 virtio,bridge=vmbr20        # mgmt
qm set 310 --net1 virtio,bridge=vmbr10
qm set 310 --net2 virtio,bridge=vmbr30
qm set 310 --net3 virtio,bridge=vmbr40
qm set 310 --net4 virtio,bridge=vmbr45
qm set 310 --net5 virtio,bridge=vmbr60
qm set 310 --net6 virtio,bridge=vmbr70
qm set 310 --net7 virtio,bridge=vmbr99
```

Use an Ubuntu 24.04 **cloud image + cloud-init** rather than an ISO — it is far less work and gives
you a repeatable build. (The original build's notes are emphatic about this.)

- [ ] **Step 2: Install Incus and create one profile per segment**

```bash
sudo apt update && sudo apt install -y incus
sudo incus admin init --minimal

# inside cthost01, bridge each NIC so containers can attach to the right segment
# (ens19 etc. - confirm names with `ip -br link`)
sudo incus profile create seg-servers
sudo incus profile device add seg-servers eth0 nic nictype=bridged parent=br10 name=eth0
sudo incus profile create seg-users
sudo incus profile device add seg-users eth0 nic nictype=bridged parent=br20 name=eth0
# ... repeat for br30 br40 br45 br60 br70 br99
```

- [ ] **Step 3: Launch containers onto their segments**

```bash
sudo incus launch images:debian/12 dc01   --profile default --profile seg-servers
sudo incus launch images:debian/12 fs01   --profile default --profile seg-servers
sudo incus launch images:debian/12 wk01   --profile default --profile seg-users
sudo incus launch images:debian/12 cam01  --profile default --profile seg-otiot
# ... etc per the catalogue in Part 11

# static addressing per the estate
sudo incus exec dc01 -- bash -c 'echo "auto eth0
iface eth0 inet static
  address 10.30.10.10/24
  gateway 10.30.10.1" > /etc/network/interfaces.d/eth0'
```

> **`incus exec` consumes stdin.** If you run these from a script piped in via `ssh HOST 'bash -s'`,
> **every** `incus exec` must end with `</dev/null` or your loop will silently exit after the first
> container. This cost the original build real debugging time.

- [ ] **Step 4: Verify every container is on the right segment and can reach its gateway**

```bash
for c in $(sudo incus list -c n --format csv); do
  ip=$(sudo incus exec "$c" -- hostname -I </dev/null 2>/dev/null | awk '{print $1}')
  gw=$(echo "$ip" | awk -F. '{print $1"."$2"."$3".1"}')
  r=$(sudo incus exec "$c" -- timeout 3 ping -c1 -W1 "$gw" </dev/null >/dev/null 2>&1 && echo OK || echo FAIL)
  printf '%-10s %-16s gw=%-16s %s\n' "$c" "$ip" "$gw" "$r"
done
```

---

## Part 14 — Windows guests, concretely

- [ ] **Step 1: Create a Windows 10 LTSC workstation VM**

```bash
qm create 150 --name ws01 --memory 6144 --cores 2 --cpu host \
  --machine q35 --bios ovmf --ostype win11 \
  --efidisk0 rangestore:1,efitype=4m,pre-enrolled-keys=1 \
  --tpmstate0 rangestore:1,version=v2.0 \
  --scsihw virtio-scsi-single \
  --scsi0 rangestore:64,discard=on,ssd=1 \
  --net0 virtio,bridge=vmbr20 \
  --ide2 local:iso/Win10_LTSC_2021.iso,media=cdrom \
  --ide0 local:iso/virtio-win.iso,media=cdrom \
  --agent enabled=1 --onboot 1
qm start 150
```

Load the **virtio SCSI driver** from the second ISO during setup or Windows will not see the disk.
Install the **QEMU guest agent** afterwards — you will want `qm guest exec` for automation.

**Build ONE golden image, then clone.** But first read this, because it cost the original build a
full rebuild of six guests:

> **Scrub the golden image before cloning.** The original golden image carried the *builder's own*
> environment into the range: house DNS servers, a remote-access agent, and Elastic/GHOSTS endpoints
> pointing at real infrastructure. Every clone inherited it. Before you clone, verify:
> `ipconfig /all` (DNS must be the range DC), no remote-access agents installed, and every agent
> endpoint pointing at range addresses.

- [ ] **Step 2: Deploy Sysmon from an upstream config**

```powershell
# RETRIEVE - never author detection content
git clone https://github.com/olafhartong/sysmon-modular C:\tools\sysmon-modular
cd C:\tools\sysmon-modular
git rev-parse HEAD | Out-File C:\tools\sysmon-config-commit.txt   # record provenance
.\Merge-SysmonXml.ps1 -AsString | Out-File -Encoding utf8 C:\tools\sysmonconfig.xml
C:\tools\Sysmon64.exe -accepteula -i C:\tools\sysmonconfig.xml

# verify it actually loaded the config you think it did
C:\tools\Sysmon64.exe -c | Select-String -Pattern 'Config file|HashAlgorithms|Rule'
```

- [ ] **Step 3: Enable command-line auditing (4688 without it is nearly useless)**

```powershell
auditpol /set /subcategory:"Process Creation" /success:enable
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
  /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f
```

- [ ] **Step 4: Enroll Elastic Agent and verify from BOTH ends**

```powershell
# the token is base64 and may end in '=' - never parse it with cut -d=
.\elastic-agent.exe install `
  --url=https://<so01>:8220 `
  --enrollment-token=<TOKEN> `
  --insecure
Get-Service "Elastic Agent" | Format-List Name,Status      # NOTE: space in the name
& "C:\Program Files\Elastic\Agent\elastic-agent.exe" status
```

Then confirm from the SIEM side — agent "healthy" does **not** prove data is arriving:

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
 "query":{"bool":{"filter":[{"term":{"host.name":"ws01"}},
   {"range":{"@timestamp":{"gte":"now-15m"}}}]}},
 "aggs":{"ds":{"terms":{"field":"event.dataset","size":10}}}}'
```

Expected: `windows.sysmon_operational`, `windows.security`, and Defend's `endpoint.events.*`.
**`host.name` is lowercase in Elasticsearch** — querying `WS01` returns zero and looks like failure.

- [ ] **Step 5: Build Active Directory into a real company**

Use the scripts in `tools/ad/` from this repo:

```powershell
.\tools\ad\populate-hr-attributes.ps1          # names, titles, departments, managers
.\tools\ad\fix-names-and-clean-service-accounts.ps1
.\tools\ad\enable-directory-change-auditing.ps1  # event 5136
.\tools\ad\verify-hr-population.ps1              # VERIFY - do not assume
```

Then build the HR database so SIEM→HR pivots work:

```bash
python3 tools/db/load-corpdb-from-ad.py
```

A flat AD of 10 identically-named users teaches nothing. A 4-level org chart lets an analyst ask
"is it normal for *this* person to touch *that* share?" — which is the actual hunting skill.

---

## Part 15 — The noise generator, in detail

This is where realism is won or lost, and where the original build spent most of its effort. Start
from `noise/containers/rangenoise.sh` in this repo, but understand these five properties — an
analyst can defeat a range that misses any one of them.

### 15.1 Diurnal shape

Traffic must follow a working day. A flat 24-hour curve is the most obvious tell there is.

```python
import math, datetime

def diurnal():
    """Activity multiplier 0.05-1.0 for the current time."""
    now = datetime.datetime.now()
    h = now.hour + now.minute / 60.0
    if now.weekday() >= 5:                      # weekend
        return 0.15
    if h < 6 or h > 20:
        return 0.05
    # peak mid-morning and mid-afternoon, dip at lunch
    curve = math.exp(-((h - 10.0) ** 2) / 8.0) + 0.9 * math.exp(-((h - 14.5) ** 2) / 6.0)
    return max(0.05, min(1.0, curve))
```

**Verify the curve is not inverted.** The original build ran an inverted curve for a while without
noticing. Measure peak:trough per tier — target 4–8× for containers, 2–4× for Windows.

### 15.2 Role awareness

A camera, a phone and a workstation must not generate the same traffic. Give each role its own
protocol mix and target list — and make that list **policy-legal** for the role's segment (Part 12).

### 15.3 Client diversity

Read Part 8.4 first. Implementation points that matter:

- **Pick a TLS profile per host, seeded by hostname**, so a machine keeps a stable fingerprint the
  way a real machine does. The *pool* must then be larger than your host count or fingerprints
  collide: 31 hosts on a 12-entry pool gave 12 fingerprints; an 80-entry pool gave ~31.
- **Vary user agents per host**, with a stable primary browser UA plus a minority of app agents
  (updaters, package managers) — real hosts emit both.
- **Keep a deliberate cleartext tier** (~10–15% HTTP) so there is something to read.

### 15.4 TLS session resumption

Real clients resume sessions. `curl` **cannot** do this across process invocations — every call is a
fresh handshake — so a curl-only generator produces ~0% resumption, which is a glaring tell.

```python
import ssl, socket

_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)      # ONE context, reused
_ctx.check_hostname = False
_ctx.verify_mode = ssl.CERT_NONE
_sessions = {}

def fetch_tls(host, port=443):
    raw = socket.create_connection((host, port), timeout=5)
    s = _ctx.wrap_socket(raw, server_hostname=host, session=_sessions.get(host))
    _sessions[host] = s.session                     # hold it for next time
    s.sendall(b"GET / HTTP/1.1\r\nHost: " + host.encode() + b"\r\nConnection: close\r\n\r\n")
    s.recv(4096)
    s.unwrap()                                      # clean TLS close -> clean TCP teardown
    raw.close()
    return s.session_reused
```

**Both sockets must share the same `SSLContext`**, and OpenSSL does not cache client sessions for
you — you hold the `session` object yourself. Target ≥ 30% resumed.

### 15.5 Do not let your own tooling become the traffic

Everything you run generates telemetry. In the original build the simulation agent's API polling
became **31% of all plaintext HTTP**, `auditd` was **78% self-noise** (`proctitle` and raw `syscall`
records), and each SSH command batch produced 6 auth events until batched into one. Budget for this,
and exclude control-plane traffic from realism gates by **destination**, after verifying the mapping
1:1 in both directions (Part 8.5).

---

## Part 16 — GHOSTS: driving the Windows users

GHOSTS (`cmu-sei/GHOSTS`) drives realistic user behaviour on Windows — browsing, Office documents,
command execution. An API server schedules timelines; clients poll it.

- [ ] **Step 1: Stand up the API**

```bash
git clone https://github.com/cmu-sei/GHOSTS
cd GHOSTS/src
docker compose up -d
docker compose ps                       # API listening on :5000
curl -s http://localhost:5000/api/home | head
```

- [ ] **Step 2: Install the client and confirm it REGISTERS**

Point the client's `application.json` at `http://<ghosts01>:5000`. A running client is not a
registered client — verify from the API side that the machine has a `machineId`:

```bash
curl -s http://<ghosts01>:5000/api/machines | python3 -m json.tool | head -30
```

- [ ] **Step 3: Author per-role timelines**

Handlers: `BrowserFirefox`/`BrowserChrome`, `Word`, `Excel`, `Command`, `Ssh`. The `HandlerArgs`
that actually matter:

```json
{
  "HandlerArgs": {
    "stickiness": 75,
    "stickiness-depth-min": 3,
    "stickiness-depth-max": 8,
    "blockimages": true,
    "isheadless": false
  }
}
```

**`stickiness` defaults to 0**, meaning every navigation jumps to a brand-new random site — nothing
like real browsing. Setting ~75 makes the browser follow links within a site for 3–8 pages, which is
both more realistic *and* substantially cuts handshake and Sysmon volume.

> **Beware the interaction with Part 8.4.** Stickiness reduces TLS handshakes, because one connection
> serves many page loads. That is *correct* browser behaviour, but it lowers your JA3 count. Do
> **not** respond by reducing stickiness — fix diversity with more distinct clients instead. The
> original build got this backwards and spent hours on it.

- [ ] **Step 4: Verify GHOSTS is actually driving activity**

```bash
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
 "query":{"bool":{"filter":[{"term":{"event.code":"1"}},
   {"range":{"@timestamp":{"gte":"now-60m"}}}]}},
 "aggs":{"p":{"terms":{"field":"process.name","size":15}}}}'
```

Expect browsers, Office binaries and shells — not just system processes.

---

## Part 17 — Velociraptor as an analysis station

Per the locked stack: **no agents on endpoints.** The workflow you are building toward is:

**detect in Kibana → triage with Defend's process telemetry → decide the host needs examination →
run an offline collector → import into Velociraptor → timeline and prove it.**

- [ ] **Step 1: Stand up the server and build an offline collector**

In the GUI: *Server Artifacts → Offline Collector*. Choose artifacts (`Windows.KapeFiles.Targets`
with `_SANS_Triage` is the usual choice) and produce a self-contained `.exe`.

- [ ] **Step 2: Run it on a target, retrieve the zip, import it**

That deliberate friction is the point — it is how real acquisition works and it forces the analyst
to justify collection.

**Design every exercise so the SIEM alone is insufficient**, the EDR narrows it, and Velociraptor
proves it. If Kibana answers the whole question, the exercise is too easy.

---

## Part 18 — Hunting exercises worth building

Once the baseline passes its gates, these shapes exploit what you have built:

| Exercise | Uses | Why the baseline matters |
|---|---|---|
| Anomalous share access | AD org chart + SMB logs + HR database | Only detectable if a "normal" pattern exists |
| Beaconing in the noise | Diurnal traffic + domain pool | A flat curve makes the beacon trivial to spot |
| Rogue device on GUEST | Policy matrix + logged denies | Denies must be logged and ordinary-looking |
| Lateral movement | BZAR / SMB / Kerberos | Needs east-west SPAN; egress-only sensors cannot see it |
| Credential theft → pivot | 4624/4625 + process telemetry | Needs per-host user assignment, not one shared account |
| Data staging + exfil | File server + proxy + byte volumes | Needs a realistic byte-tail distribution |

**Rotation is the anti-memorisation control.** Use one shared domain pool for *both* benign browsing
and C2, rotating per exercise, so the pool can never itself become the indicator. The analyst must
hunt behaviour, not recognise names from last session.

---

## Part 19 — Build order, and the day-one checklist

Do it in this order. Each line is gated on the one above actually working.

- [ ] **1.** C240 M4: JBOD via `Ctrl+R`, VT-x/VT-d on, CIMC reachable (Part 1)
- [ ] **2.** Proxmox + ZFS pool on `/dev/disk/by-id`, ARC capped at 32 GB (Part 3.1)
- [ ] **3.** Bridges: uplink + one per segment + SPAN bridge with learning off (Part 3.2)
- [ ] **4.** `fw01` OPNsense: VLAN gateways, policy matrix, logged denies (Part 12)
- [ ] **5.** `so01` Security Onion standalone, ES heap 31 GB, cluster GREEN (Parts 4.1, 2.3)
- [ ] **6.** SPAN mirrors per segment via **veth**; prove every VLAN with tcpdump (Part 4.2)
- [ ] **7.** `cthost01` + Incus + one profile per segment (Part 13)
- [ ] **8.** Container estate per the catalogue; verify each reaches its gateway (Parts 11.1, 13)
- [ ] **9.** Internal CA; reissue certs so DNS name = SNI = cert name (Part 11.1)
- [ ] **10.** Windows DC + workstations from a **scrubbed** golden image (Part 14)
- [ ] **11.** Sysmon (upstream, hash recorded) + cmdline auditing + Elastic Agent (Part 14)
- [ ] **12.** AD → real org chart + HR database (Part 14, Step 5)
- [ ] **13.** Noise generators, role-aware and diurnal (Part 15)
- [ ] **14.** GHOSTS API + per-role timelines (Part 16)
- [ ] **15.** Gate harness on a timer, appending JSON (Part 8)
- [ ] **16.** Tune volume to 5–10k/endpoint/day (Part 7)
- [ ] **17.** Velociraptor + offline collector workflow (Part 17)
- [ ] **18.** **Only now** — adversary emulation (Part 10)

### The five checks to run before believing any of it

```bash
# 1. every VLAN reaches the sensor
sudo timeout 30 tcpdump -nni <monitor-if> -e | grep -oE 'vlan [0-9]+' | sort | uniq -c

# 2. cluster health
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config "https://localhost:9200/_cluster/health?pretty"

# 3. every endpoint is shipping
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' \
 -d '{"query":{"range":{"@timestamp":{"gte":"now-30m"}}},
      "aggs":{"h":{"terms":{"field":"host.name","size":50}}}}'

# 4. connection failure rate - S0+REJ only, NOT "not SF" (see Part 8.2 for why)

# 5. no egress escapes the range: from a range host, attempt to reach your own
#    LAN and the internet. BOTH must fail.
```

**If any of the five is not measured, the range is not built — it is only running.**

---

## Appendix A — Traps, each of which cost real time

| Trap | Symptom | Fix |
|---|---|---|
| SO uses non-ECS field names | `source.bytes` = 0 **even for SF connections** | `client.bytes` / `server.bytes` / `client.packets` |
| `event.duration` is seconds | Every row prints `0.00s` after dividing by 1e9 | Do not convert |
| `capture_loss` reads 0.0% while the sensor is starved | Zeek computes loss against what it *received* | Count packets/VLAN with tcpdump |
| Checksum offloading | Zeek reports huge capture loss on a healthy link | `ethtool -K <if> rx off tx off gro off lro off` |
| `tc mirred` to a bridge master | Sensor sees almost nothing | Mirror into a **veth**, not the bridge |
| SPAN bridge learning ON | Traffic stops flooding to the sensor | learning off, `ageing_time 0` |
| MTU set in the interface stanza | Host-wide network outage | Set jumbo `post-up` |
| Elastic token parsed with `cut -d=` | Confusing auth failure | Tokens are base64; keep `=` padding |
| `Get-Service ElasticAgent` | Returns nothing, looks uninstalled | Service is `"Elastic Agent"` **with a space** |
| `host.name` uppercase in a term query | Zero hits, looks like no telemetry | It is lowercase in ES |
| ES `curl` without `-sSk` | TLS verification failure | Its `curl.config` carries no CA |
| `incus exec` inside a piped script | Loop dies after one iteration | Append `</dev/null` to every call |
| `sudo -S` with a heredoc | Password becomes line 1 of the file | Stage as user, then `sudo cp` |
| pvesh backslash escapes | `C:\Windows\Temp\agent` → `Tempgent` | Use forward slashes |
| pvesh `file-write` > 61440 chars | Silent truncation | Chunk the write |
| UTF-8 BOM | `json.loads` fails; pvesh rejects U+FEFF | Write BOM-less, strip `\ufeff` |
| auditd exclusion ordering | Exclusions silently ineffective | `-D` must come **first**; exclusions after |
| auditd `exe=` rules | Blind to containerised processes | Match on other fields |
| OPNsense config path | Edits to `<unbound>` do nothing | Unbound lives at `<OPNsense><unboundplus>` |
| Windows guest clock skew | Cross-host correlation silently wrong | Root domain time at the firewall; verify the stratum chain |

## Appendix B — Baselines measured on the original build

Compare your range against these. They are real measurements, not targets pulled from air.

| Metric | Original build achieved | Enterprise target |
|---|---|---|
| Connection failure rate (S0/REJ) | **4.51%** | < 10% |
| Unique JA3 (60 min) | **67** | ≥ 60 |
| Top single JA3 share | **7.78%** | ≤ 25% |
| Unique user agents | **83** | ≥ 80 |
| TLS session resumption | **32.6%** | ≥ 30% |
| Diurnal peak:trough (containers) | **5.5×** | 4–8× |
| Diurnal peak:trough (Windows web) | **2.11×** | 2–4× |
| Sysmon per endpoint | 12–16k/day (**over**) | 5–10k/day |
| Public egress from range | **0** | 0 |
