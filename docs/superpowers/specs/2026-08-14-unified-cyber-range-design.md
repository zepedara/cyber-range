# Unified Cyber Range — Design

**Date:** 2026-08-14
**Status:** Draft for review
**Repo:** `github.com/zepedara/cyber-range` (public)

---

## 1. Purpose

One enterprise-like cyber range, defined once and rendered twice — as a container
edition and a VM edition — producing hunt-grade telemetry across network, endpoint,
identity, and application tiers, with a controllable attack platform that reaches the
estate through a pivot server rotating over a shared pool of benign-looking domains.

It supersedes two earlier projects and takes the best of each:

| Source | What carries forward | What is dropped |
|---|---|---|
| `Icarus4122/tiger-team-defense` (TTD) | Service catalogue, per-service entrypoint pattern, profile-grouped startup, internal CA + generated domain infrastructure, fake-external segment with randomized public IPs, hash-pinned Windows ISO fetch, `labctl` control-plane shape | Unpinned `:latest` images, scraped download URLs, missing env files, MACVLAN claim that was never implemented |
| `zepedara/lab-env` | Diurnal traffic curve, role-based noise generation, `--check`/`--revert` idempotence, measurement bands for exercise difficulty, the trap knowledge (AppArmor/tcpdump, UTF-16LE SMB, pcap filter semantics), honest failure logging | The PCAP replay pipeline, hand-maintained estate state, hardcoded `~/Desktop` paths |

The governing improvement over both: **the estate is data, and telemetry coverage is
measured rather than asserted.**

---

## 2. Decisions

Settled with the owner before design:

| # | Decision | Value |
|---|---|---|
| 1 | Target host | cthuwu (home Proxmox, bare metal) |
| 2 | Purpose | Owner's own hunt practice; migration to a larger host planned |
| 3 | Hunt surface | All four tiers: network, endpoint process, identity/auth, application |
| 4 | Domain rotation | Shared pool, per-exercise rotation |
| 5 | Attack engine | Live C2 + ATT&CK emulation (no PCAP replay) |
| 6 | **Locked tool stack** | **Security Onion / Kibana as SIEM, Elastic Agent + Elastic Defend as EDR, Velociraptor for forensics — all three are training requirements, not implementation choices** |
| 7 | Sensor version | Security Onion **3.2**, greenfield install on Oracle Linux 9 |
| 8 | Architecture | One enterprise, two renderings, shared identity plane |
| 9 | Container kernel | Dedicated container-host VM running **Incus**, not the hypervisor |
| 10 | Repo visibility | Public — therefore no real fleet addressing in committed files |
| 11 | Velociraptor model | **Analysis station only.** No clients on endpoints; acquisition via offline collectors |
| 12 | Windows client OS | **Windows 10 Enterprise LTSC 2021** — not IoT, which Elastic Defend does not support |
| 13 | Workstation count | Six, running concurrently, gated on measured KSM reclaim |
| 14 | rick | Stripped to headless, 32 GB → 8 GB, freeing 24 GB for the range |

### 2.1 What "meaningful implementation" means here

The three locked tools are not boxes to tick. The range is finished when an analyst can
complete a whole workflow across all three: **detect in Kibana → triage with Elastic
Defend's process telemetry → decide the host warrants examination → run an offline
collector → import into Velociraptor → timeline and prove it.** Every exercise in §9.2 is
designed so the SIEM alone is insufficient, the EDR narrows it, and Velociraptor proves it.

---

## 3. Architecture

### 3.1 Core rule

**Nothing about the enterprise is written in a script.** Hostnames, addresses, roles,
users, and domains live in `estate/*.yaml`. Scripts read the estate; they never contain
it. This is what makes two editions possible without drift, and what makes migration to
a larger host a re-render rather than a rebuild.

`lab-env` is the cautionary case: its estate exists only as the accumulated side effects
of 73 scripts, so it cannot be reproduced, only continued.

### 3.2 Two renderings, one enterprise

```
                     estate/*.yaml  (single source of truth)
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
      render/lxc                        render/pve
   container edition                    VM edition
   ~45 containers                       ~12 VMs
   network + application                endpoint + identity
   telemetry                            telemetry
              │                               │
              └───────────────┬───────────────┘
                              ▼
                      Security Onion 3.0
                  Zeek · Suricata · Elastic
                        Kibana = one pane
                              ▲
                     Velociraptor (separate server)
                     on-demand forensic collection
```

Both editions use the same host names, roles, users, and domain pool. Addressing differs
only in the second octet, so a log's edition is unambiguous in Kibana.

### 3.3 Why containers still win on the migration target

cthuwu is 48 threads / 125 GB — CPU-rich, RAM-poor. The migration target is 20 cores /
384 GB — RAM-rich, CPU-poor. The instinct is that these want opposite designs. They do
not: 45 VMs means 45 kernels, 45 timer interrupts, and 45 Elastic Agents scheduling
against 20 cores, where 45 containers share one kernel. Containers win on both hosts,
for opposite reasons. What changes is the sizing profile, not the design.

`estate/profiles.yaml` carries named resource profiles (`cthuwu` = RAM-bound,
`xeon` = CPU-bound) setting per-host RAM, vCPU, noise-generator concurrency, and Zeek
worker count.

---

## 4. Host layout on cthuwu

### 4.1 Measured starting state (2026-08-14)

125 GB RAM, 48 threads, ZFS ARC capped at 8 GB. Storage: `vmstore` 814 GB free,
`vmdata` 426 GB free, `/mnt/hot` 1.6 TB free. Seven isolated bridges already exist;
`vmbr90` carries the house SPAN into Security Onion.

Six VMs were shut down to free capacity (`flare-vm`, `remnux`, `sift-ws`, and three
`irtest-*`), taking available RAM from 32 GB to 56 GB.

### 4.2 Budget

`rick` (VM 100) was measured using **8 GB of its 32 GB allocation**, of which 4 GB was a
GNOME desktop with no remote viewer attached. Stripping it to headless and reallocating
frees 24 GB. All of rick's services stay — graphify, ntfy, qdrant, SearxNG, RustDesk,
immudb, ollama on the 4090 — since together they use under 3 GB.

| Component | GB | Note |
|---|---|---|
| `rick`, stripped headless | 8 | was 32 |
| ZFS ARC (capped explicitly) | 4 | was 8 |
| Host / PVE | 3 | |
| **Security Onion 3.2** | **48** | grown to match the larger estate |
| Velociraptor analysis station | 4 | |
| operator01 (ex-`kali`) | 3 | |
| **Range** | **~55** | |

Range allocation:

| Component | GB |
|---|---|
| Container-host VM + ~70 containers | 18 |
| dc01, dc02 (Server Core) | 6 |
| fs01 (Server Core) | 3 |
| sql01 (Server Core + MSSQL) | 5 |
| wk01–wk06 (Win10 LTSC linked clones) | 24 nominal → **~17 with KSM** |
| pivot01 (Debian minimal) | 1.5 |
| fw01 (OPNsense) | 1.5 |
| **Total** | **~52 effective** |

**KSM is load-bearing and is currently switched off.** There is no `/etc/ksmtuned.conf`
on the host, `ksmtuned` is inactive, and `/sys/kernel/mm/ksm/run` is `0`. The kernel does
have the newer in-kernel advisor available (`smart_scan=1`, `advisor_mode` present), which
supersedes the old userspace daemon and is the right mechanism to use.

**Acceptance gate:** after the six workstation clones are running, measure
`pages_sharing × 4096` and require **≥25% reclaim across the Windows tier**. If it
under-delivers, power down two workstations. Nothing about the build changes — only how
many are powered.

### 4.3 VM repurposing map

Existing VMs are renamed and re-provisioned rather than built fresh.

| Existing | Becomes |
|---|---|
| `range-dc01` (150) | **dc01** — Windows AD, Server Core |
| `range-WEB01` (153) | **dc02** — second DC |
| `range-FS01` (151) | **fs01** — file server |
| `range-SQL01` (152) | **sql01** — MSSQL + audit |
| `range-WS01/WS02` (154/155) | **wk01, wk02** |
| `irtest-win10ent` (3010) | **wk03** — has 21 GB of installed content, reusable |
| `irtest-win11ent` (3011) | **wk04** — disk is 112 KB, never installed; rebuild |
| `redinfra01` (210) | **pivot01** — attack platform |
| `sandbox01` (130) | **fw01** — OPNsense |
| `kali` (146) | **operator01** — Sliver + Caldera console |
| `dfir-ws` (141) | **analyst01** — the hunting workstation |
| `velociraptor01` (102) | **velo01** — analysis station, standalone GUI mode |
| new | **cthost01** — container-host VM |
| new | **wk05, wk06** — linked clones of the gold image |

Untouched: `soc-securityonion` (170). `rick` (VM 100) is stripped, not repurposed.

**Verified 2026-08-14:** all six `range-*` VMs carry real installed disks (11.6–28.4 GB
allocated) with seed ISOs indicating an automated unattend build, so these are genuine
repurposes. Windows media is already on the host — `winsrv2022-eval.iso`,
`win11-ent-eval-25h2.iso`, `win10.iso`, `virtio-win.iso` — all evaluation editions. The
workstation tier needs **Windows 10 Enterprise LTSC 2021** media, which is not present and
must be sourced.

### 4.4 The container-host VM

Containers cannot produce syscall telemetry (§7.3). That telemetry must come from the
kernel they run on — which must not be the hypervisor.

**Why not the hypervisor, concretely.** `auditd` is not installed on cthuwu and `audit=1`
is not on its kernel command line, so instrumenting it requires a cmdline change and a
**reboot of a host with no out-of-band recovery**. Worse, auditd's backlog limit defaults
to 64 records and on overflow the kernel puts the *generating process* into uninterruptible
sleep for up to 60 seconds — on a hypervisor those processes are `qemu-system-x86_64`,
`pvedaemon`, and `corosync`. Red Hat's bug for this is closed WONTFIX.

`cthost01` is a **Debian 13** VM (kernel 6.12, newer than the hypervisor's 6.8) running the
container estate under **Incus**, with Falco and a narrow auditd instrumenting its own
kernel.

**Incus rather than Proxmox's native containers**, for one decisive reason:
`security.idmap.isolated=true` assigns every container a unique, non-overlapping UID range,
which makes **the UID already inside each audit record the container identifier** — no
`/proc` lookup, no race with process exit, works for processes that died microseconds ago.
Proxmox's default places every unprivileged container at the same UID base, so the UID
identifies nothing.

**Falco is the primary sensor; auditd is a narrow secondary.** The distinction is
architectural: Falco ships *rule matches*, auditd ships *raw records* — same detection
fidelity, three orders of magnitude difference in output. Falco measures 76.5 MB resident
at ~3,000 events/second. auditd is scoped only to what Falco cannot provide: the login UID
that survives `su`/`sudo`, and roughly fifteen config-file watches.

**Zero agents inside the containers.** Elastic Agent's measured baseline is 220–280 MB;
seventy of those would consume the entire container tier on log shipping alone. The
container host reads each container's journal and logs directly from its root filesystem
and runs file-integrity watches host-side. This also places the collector **outside the
blast radius** — an attacker who owns a container cannot kill an agent that isn't there.

**Host prerequisites verified 2026-08-14:** BTF present (CO-RE eBPF viable), cgroup v2,
nested virtualization enabled, `debian-13-standard` template available, inotify limits
already at 4,194,304 watches. One trap confirmed present: **`kernel.keys.maxkeys` is 2000**,
which is the setting that makes containers silently fail to start at around forty. It must
be raised before the container tier is built.

Container-to-VMID-to-hostname enrichment is built in Elasticsearch on day one, sourced
from the container host's own config. Retrofitting it across 45 containers of historical
data is not worth doing later.

---

## 5. Network design

### 5.1 Addressing

cthuwu already occupies `10.20.0/20/30/40/50/59`. The range therefore lives in
**`10.30.0.0/16`**, colliding with nothing.

```
10.<30|31>.<vlan>.<host>
   30 = container edition       .1        gateway (fw01)
   31 = VM edition              .10-.49   servers / infrastructure
                                .51-.99   clients (static)
                                .100-.199 DHCP pool
                                .200-.254 reserved
```

Second octet identifies the edition; a host keeps its identity across both
(`dc01` is always `.10`, `wk01` always `.51`).

### 5.2 Segments

Nine VLANs trunked over two VLAN-aware bridges (`vmbr60` containers, `vmbr61` VMs),
rather than eighteen bridges. This also puts 802.1Q on the wire, which is what a real
enterprise looks like.

| VLAN | Segment | DHCP | Contents |
|---|---|---|---|
| 5 | MGMT | no | mon01, bastion01, backup master, agent policy |
| 10 | SERVERS | no | dc01, dc02, fs01, sql01, app01/02, ca01, print01, bk01 |
| 20 | USERS | yes | wk01–wk20 |
| 30 | DMZ | no | web01, mail01, proxy01, ftp01, vpn01, extdns01 |
| 40 | VOICE | yes | pbx01, phone01–04 |
| 45 | OT/IoT | yes | cam01–04, badge01, hvac01, mfp01 |
| 60 | BRANCH | yes | br-dc01 (RODC), br-fs01, br-wk01–03 |
| 70 | GUEST | yes | byod01–03 |
| 99 | TRANSIT | no | edition uplink to fw01 |

DHCP on five segments is deliberate: it produces `dhcp.log`, lease churn, and hostname
registration — the data an analyst uses to attribute an IP to a machine.

### 5.3 The fake internet

Hosted entirely inside the range, using **real public allocations**:

| Range | Apparent owner | Serves |
|---|---|---|
| `23.62.0.0/16` | Akamai | CDN, software updates |
| `104.18.0.0/16` | Cloudflare | bulk of the shared domain pool |
| `142.250.0.0/16` | Google | search, mail, docs |
| `52.139.0.0/16` | Microsoft Azure | O365-alike, Windows Update |
| `172.64.0.0/16` | Cloudflare | second pool block |

Two reasons. First, Security Onion enriches with GeoIP and ASN, so benign traffic shows
Cloudflare/Akamai/Google exactly as production does — and because the rotating C2 domain
resolves into the same ranges, an exercise cannot be solved by filtering on ASN or
geography. Second, it sidesteps a documented trap: Security Onion's `HOME_NET` defaults
to RFC1918, so ranges using `10.x` for their simulated internet get it classified as
internal, poisoning direction logic and a large share of Emerging Threats rules. Note
`172.64.0.0/16` sits outside `172.16.0.0/12`, so there is no collision.

This also retires lab-env's "hide C2 inside the victim's own subnet" trick. That existed
because replayed captures otherwise fell out of the noise under one subnet filter. With
live C2 egressing through the proxy to the same fake internet the benign hosts use all
day, blending is structural rather than staged — and outbound C2 is what real intrusions
look like.

### 5.4 Segment policy

Enforced on `fw01` (OPNsense), not assumed. Every denied flow is a logged drop, which is
both a hunting data source and something for lateral-movement exercises to trip over.

| From ↓ / To → | MGMT | SERVERS | USERS | DMZ | VOICE | OT | BRANCH | GUEST | INTERNET |
|---|---|---|---|---|---|---|---|---|---|
| MGMT | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| SERVERS | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ | via proxy |
| USERS | ✗ | AD/SMB/SQL | ✓ | ✓ | ✗ | print only | ✗ | ✗ | via proxy |
| DMZ | ✗ | AD only | ✗ | ✓ | ✗ | ✗ | ✗ | ✗ | ✓ |
| VOICE | ✗ | DNS/NTP | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ | SIP only |
| OT/IoT | ✗ | DNS/NTP | ✗ | ✗ | ✗ | ✓ | ✗ | ✗ | ✗ |
| BRANCH | ✗ | ✓ | ✗ | ✓ | ✗ | ✗ | ✓ | ✗ | via proxy |
| GUEST | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓ | direct |

A firewall as a first-class host also buys a telemetry source neither reference project
had: filter logs, flow records, and VPN authentication events. It additionally serves as
an independent oracle on SPAN health — if the firewall counted a flow Zeek never saw,
the mirror is dropping traffic.

### 5.5 Mirroring

The range gets its own mirror bridge (`vmbr91`) and a dedicated capture NIC on the
sensor, **separate from the existing house SPAN on `vmbr90`**. Mixing them would put the
owner's own laptop, phone, and Plex traffic into every hunt query — the exact failure
lab-env documented as "analysts can find themselves" and never fixed.

Mirroring is `tc mirred` on veths and taps into a virtual bridge, entirely in software,
so it is not limited by the 1 Gbps house SPAN NIC. The cost is CPU, which is the
resource cthuwu has spare.

---

## 6. Images

### 6.1 Principle

Debloat anything that emits no telemetry and is not attack surface; keep everything that
does either. Community "tiny Windows" images routinely strip or break Defender, WMI,
PowerShell subsystems, and WinRM — producing a small VM that cannot be hunted on.

### 6.2 Gold images

| Image | Base | Used for | Disk | Idle | + telemetry |
|---|---|---|---|---|---|
| `gold-win-core` | Server 2022 Server Core | dc01, dc02, fs01, sql01 | 12 GB | 0.7 GB | 1.8–2.5 GB |
| `gold-win-ws` | Win11 24H2 Enterprise LTSC | wk01–wk06 | 15 GB | 1.1 GB | 2.5–3.0 GB |
| `gold-win-legacy` | Win10 22H2 Enterprise LTSC | wk03 | 14 GB | 1.0 GB | 2.5 GB |
| `gold-deb-vm` | Debian 12 `minbase` | pivot01, cthost01 | 3 GB | 90 MB | 400 MB |
| `gold-deb-ct` | same, LXC template | ~45 containers | 500 MB | 25 MB | 180 MB |
| `fw01` | OPNsense | firewall/router | 8 GB | 700 MB | 1.5 GB |

**Removed:** Store and UWP packages, OneDrive, Xbox, Widgets, consumer Teams, Delivery
Optimization cache, SysMain, System Restore, hibernation, search indexing on servers,
WSL/Hyper-V/Sandbox, theme packs.

**Kept deliberately:** Defender (its Operational log is a first-class hunting source),
PowerShell with module + script-block + transcription logging, WMI, Task Scheduler,
WinRM, RDP, print spooler on `print01`, Edge on workstations for browsing noise.

### 6.3 Multipliers

- **Linked clones** from one sysprepped image — six workstations cost ~15 GB instead of 90.
- **KSM** — identical Windows clones share most memory pages, typically reclaiming
  25–40% across four to six clones. Off by default; the highest-leverage setting here.
- **Ballooning** so idle VMs return RAM between exercises.

### 6.4 Acceptance gate

An image may not become a clone parent until it passes its telemetry contract. Each gold
image ships a `verify` script asserting the floor — for `gold-win-ws`: Sysmon emits
1/3/7/11/22/25; Security emits 4624/4634/4688 **with a populated command line**, 4697,
4720; PowerShell emits 4103/4104; Defender Operational is live; WMI-Activity is live;
the shipper delivers to the sensor within 60s. Fail any check and the image is rejected.

This is lab-env's "measure after every change" applied to image builds, which is where
debloating usually fails silently.

---

## 7. Telemetry contract

The contract is the deliverable. Each source below is specified as: what it produces,
what enables it, its hunting value, and its volume class. Sources marked **off by
default** are the ones that make or break coverage.

### 7.1 Network — Zeek and Suricata

Zeek is the metadata engine; Suricata is the alerting engine. On a stock Security Onion
build, Suricata emits `alert` and nothing else — Zeek carries all protocol metadata.
That split is kept.

| Source | Notes |
|---|---|
| Zeek core protocol logs | conn, dns, http, ssl, ssh, smtp, ftp, smb_*, dce_rpc, kerberos, ntlm, ldap, rdp, dhcp, ntp, snmp, sip, radius, mysql, quic, syslog |
| Zeek files / x509 / pe | file provenance, certificate pivoting, PE triage |
| Zeek notice / weird / intel | Zeek's own detections; protocol anomalies; IOC matching |
| **BZAR** (MITRE) | ATT&CK-mapped SMB/DCE-RPC lateral movement. **Ships with Security Onion, disabled by default** — enable |
| **JA4+** | JA4/JA4S (TLS), JA4H (HTTP), JA4T (TCP stack), JA4SSH (**detects reverse shells inside encrypted SSH**), JA4X (cert tooling), JA4D (DHCP). Install required |
| `known_hosts`, `known_services` | First-seen hunting. **Excluded from Elastic ingest by default** — un-exclude |
| `capture_loss`, `stats` | Sensor trust. **Excluded from Elastic ingest by default** — un-exclude, or an analyst checking for packet loss in Kibana finds nothing and concludes there is none |
| `zeek-long-connections` | `conn_long.log` — C2 tunnels that `conn.log` only emits at close |
| Suricata `alert` | ET Open + abuse.ch (CC0, free, best signal-to-noise) + `stamus/lateral` (fills ET Open's worst gap: internal lateral movement) |
| Suricata `anomaly` | Evasion and malformed traffic. Off by default |
| OPNsense filter log + flow | Policy decisions Zeek cannot see, plus an independent SPAN-health oracle |

**Critical range constraint:** Zeek creates a protocol log only when it observes that
protocol. There is no empty `kerberos.log` — there is no `kerberos.log`. Every log type
the range intends to be hunted must be *generated* by the noise engine. This is a hard
requirement, not a realism nicety.

### 7.2 Windows endpoint

| Source | Enable via | Key IDs | Value | Volume |
|---|---|---|---|---|
| Sysmon Operational | sysmon-modular balanced (workstations), excludes-only (Server Core) | 1,3,7,8,10,11,12–14,17–18,19–21,22,25 + tamper 4/16/255 | Highest | Highest |
| Security — process creation | *Audit Process Creation* **+ "Include command line in process creation events"** | 4688, 4689, 4696 | High | Medium–High |
| Security — logon | *Audit Logon*, *Special Logon*, *Other Logon/Logoff* | 4624, 4625, 4648, 4672, 4964, 4778/4779 | High | Low–Medium |
| Security — scheduled tasks | *Audit Other Object Access Events* — **off by default, low volume** | 4698–4702 (full task XML incl. command line) | High | Low |
| Security — service install | *Audit Security System Extension* | 4697 | High | Low |
| System log | on by default | **7045** (needs no audit policy — the fallback when audit policy is tampered), 7040, 7034, 104 | High | Medium |
| PowerShell Operational | Script block + module logging | **4104** (deobfuscated), 4103 | Very High | High, bursty |
| Windows PowerShell (classic) | **on by default, zero config** | 400 (`HostApplication` = full command line), 600 | High | Low |
| WMI-Activity/Operational | on by default | **5861** (permanent subscription), 5857–5860 | High | Medium |
| TaskScheduler/Operational | **disabled** — enable | 106, 129, 140, 141, 200 | High | Medium |
| Defender/Operational | on by default | **5007** (exclusion added — one of the strongest single intrusion indicators), 5001/5010, 1006–1009, **1121/1122** (ASR) | Very High | Low |
| ASR + Exploit Protection | **audit mode** | 1122, Security-Mitigations 1–24 | High | Very Low |
| CodeIntegrity/Operational | on; WDAC policy in audit | 3076, 3077, 3033, 3065/3066 | High | Very Low |
| AppLocker | policy in *Audit only* | 8003, 8004, 8006, 8007 | High | Very High — drop the "allowed" events |
| TerminalServices (LSM/RCM/RDPClient) | mostly on; force RDPClient | 21–25, 1149, **1024/1102** (source-side pivot) | High | Low |
| BITS-Client, WinRM, SMBClient, PrintService, Kernel-PnP, NTLM/Operational | mixed | 3/59/60, 6/91, 30803/31001, 316/808, 400, 8002 | High | Low |
| Security 1102 / System 104 | always logged | log cleared | Very High | ~0 |

**The 4688 trap:** the command-line field is empty unless a second policy is set
(`ProcessCreationIncludeCmdLine_Enabled`). Most community Sigma `process_creation` rules
match on `CommandLine`, so without it a large fraction of the detection corpus cannot
fire. This is the highest-priority single setting in the contract.

**Server Core:** the AppLocker "MSI and Script" channel does not exist there. WDAC in
audit mode is the substitute. Server Core generates under 10% of a workstation's volume,
so near-total capture is affordable exactly where lateral movement lands.

### 7.3 Linux endpoint — and the container boundary

**LXC containers cannot produce syscall telemetry.** The Linux audit subsystem is not
namespaced (one global queue, one auditd, both the host's), and the kernel forbids
loading tracing eBPF programs from a user namespace — which is what an unprivileged
container is. This rules out auditd, Falco, Tracee, Sysmon for Linux, and Elastic Defend
*inside* containers. Making containers privileged would require disabling AppArmor and
seccomp and would let each container load eBPF into the host kernel; in a range where
containers are deliberate detonation targets, that inverts the security model.

| Placement | Sources |
|---|---|
| **Inside containers** | journald (primary substrate), all service logs, file-integrity events (fsnotify — *what* changed, not *who*), osquery state tables, dpkg/apt history |
| **On `cthost01`** | auditd via Elastic's Auditd Manager (netlink), Falco modern eBPF — covers all 45 containers from one kernel |
| **On Debian VMs** | full stack: auditd with Session View, Elastic Defend, eBPF-backed file integrity, optionally Sysmon for Linux for Windows/Linux schema parity |

**auditd rules** start from `Neo23x0/auditd` — designed to collect broadly useful
telemetry and leave detection to Sigma, which is the right shape here. Exclusions must
be written *before* the ruleset is enabled: unfiltered auditd is roughly a 50× volume
jump, and one nightly backup walking a filesystem emits one event per file.
`-F arch=b32` rules are not optional; a b64-only ruleset is evaded by compiling 32-bit.

**Debian 12 specifics:** rsyslog was demoted to optional, so `/var/log/auth.log` does not
exist on a fresh install — journald is the substrate everywhere. journald silently drops
above 10,000 messages per 30 seconds per service, which erases exactly the brute-force
burst an exercise is built around *and* doubles as a working log-flooding evasion. Set
`RateLimitBurst=0` on range hosts, and teach the evasion deliberately.

### 7.4 Identity and Active Directory

| Source | Enable via | Detects |
|---|---|---|
| Kerberos AS/TGS | *Audit Kerberos Authentication Service* + *Service Ticket Operations* — **Microsoft's "Stronger" tier, not baseline** | 4768/4769/4771 — Kerberoasting, AS-REP roasting, spraying, Golden/Silver ticket |
| NTLM | *Audit Credential Validation* + Restrict-NTLM audit policies | 4776, **8004** (the only event naming the *target server*) — relay, spraying |
| DS Access | *Audit Directory Service Access* **+ SACLs** | 4662 — DCSync (needs a *separate* SACL on the replication extended rights), LAPS/gMSA reads |
| DS Changes | *Audit Directory Service Changes* + SACLs | 5136/5137 — RBCD, ACL abuse, SPN injection, Shadow Credentials, GPO edits |
| Account management | mostly on by default | 4720–4738, 4728–4756, 4765/4766 |
| AD CS | *Audit Certification Services* **AND** `certutil -setreg CA\AuditFilter` | 4886/4887/4890/4882 — ESC1–ESC8 |
| DNS Server audit | on by default | 513–582 — ADIDNS spoofing, dynamic-update abuse |
| RODC | ship the RODC's own log | branch-site authentication |
| Zeek `dce_rpc.log` | free, no DC configuration | `DsGetNCChanges` from a non-DC — the *preferred* DCSync detection |

**Three traps:** Kerberoasting and AS-REP roasting are invisible on a baseline-configured
domain because the Kerberos subcategories are not in Microsoft's baseline. Certificate
Services logs nothing at all unless *both* switches are set. And the RODC's logs are never
replicated anywhere — ship it or lose branch authentication entirely.

**Volume:** a tuned identity configuration is ~60–150k events/day (0.2–0.5 GB) — trivial.
Cranked to maximum (DNS analytic on every DC, LDAP event 1644 at threshold 1, read
auditing) it reaches 500k–1.5M/day *and makes hunting worse*. Maximum logging is
explicitly not the goal; expensive sources are opt-in demonstrations.

### 7.5 Application and infrastructure

This is the noisy middle layer where much real hunting happens, and where the highest
proportion of value sits behind non-default settings.

| Service | Enable beyond defaults | Answers what the wire cannot |
|---|---|---|
| nginx | JSON `log_format … escape=json` with `$request_id`, `$upstream_*`, `$ssl_*`, XFF | URI, query string, and status inside TLS-terminated HTTPS; which backend served the attack |
| IIS | add `BytesSent`/`BytesRecv`/`Host`; Custom Fields for `X-Forwarded-For`; collect `httperr` | ProxyShell is literally a grep over `cs-uri-query`; requests HTTP.sys rejected before IIS ever logged them |
| **Squid** | `logformat extensive` (one of only two formats Elastic parses); `ssl_bump peek step1; splice all` | **Authenticated username on every CONNECT** — turns "an IP beaconed" into "alice's workstation beaconed". Plus the policy verdict, and bytes-in for exfil |
| Postfix | `maillog_file` **and `maillog_file_permissions=0644`**; `smtpd_tls_loglevel=1`; `header_checks` with `WARN` | Phish reconstruction by chaining queue ID across four daemons; SASL spray on 587/465 |
| Dovecot | **`auth_verbose=yes`**; `auth_verbose_passwords=sha1:8`; centralize `sieve_user_log` | IMAP spray; mailbox mass-download via session byte counts; Sieve forwarding-rule abuse (the canonical BEC persistence) |
| MariaDB | `server_audit` with `events=CONNECT,QUERY,TABLE`; raise `query_log_limit` from 1024 | SQLi payload text on a TLS'd app-to-DB connection; `INTO OUTFILE`; privilege escalation |
| MSSQL | Server + database audit specs → **SECURITY_LOG** | `xp_cmdshell` enable-and-execute; linked-server pivot; backup to an attacker share |
| Samba | `vfs_full_audit` scoped to `connect openat create_file renameat unlinkat fset_nt_acl` | SMB3 encryption hides filenames from the sensor entirely — the file server is the only place they exist |
| Windows SMB | *File Share* + *Detailed File Share* (no SACLs needed); *File System* + SACLs on decoys | 4663 has the process and full path; 5145 has the client IP and the per-right decision. Both, or neither is complete |
| vsftpd | `dual_log_enable=YES`, `xferlog_std_format=NO`, `log_ftp_protocol=YES` | Once FTPS is on, Zeek's analyzer is blind to usernames, filenames, and commands |
| BIND / dnsmasq | `category queries`+`rpz`+`spill`; dnsmasq `log-queries=extra` and `log-async` | **Client attribution.** A sensor north of the resolver attributes every malicious lookup to the resolver's own IP |
| Kea DHCP | `libdhcp_legal_log` (free, in base Kea) | IP↔MAC↔hostname↔time — the enabler for every other log. Option 82 gives switch-port attribution |
| CUPS / Windows Print | `LogLevel info`, `AccessLogLevel all`, **`PageLogFormat`** (empty by default = off); enable `PrintService/Operational` | Exfil-by-printing with job name and page count; PrintNightmare 808 (attempt) → 316 (driver actually loaded) |
| Backup | 4688-with-command-line or Sysmon 1; script-block logging | `vssadmin resize shadowstorage /MaxSize=` — evicts every shadow copy without ever using the word "delete", evading naive rules |
| OPNsense | per-rule logging (off by default); log default-block; syslog target over TCP | Blocked-connection evidence, NAT-edge attribution, rule → policy intent, VPN auth |

**Engineering cost to budget explicitly:** nine of these services have **no Elastic
integration** — Postfix, Dovecot, vsftpd, CUPS, Samba, BIND, dnsmasq, Kea, and Veeam.
Each needs a hand-written Elasticsearch ingest pipeline. Logstash does not parse in this
stack; all field extraction happens in ingest pipelines. This is the largest hidden cost
in the whole telemetry contract.

Two database choices follow from licensing: **MariaDB rather than MySQL Community**,
because `server_audit` is free and in the base product while MySQL Community has no
usable audit plugin at all. And **MSSQL audit must target SECURITY_LOG** — FILE is the
most secure but Elastic's integration is event-log-only and cannot read it, while
APPLICATION_LOG is readable by any authenticated user, which is a log-injection surface.

**The single highest-value dashboard panel in the stack:** egress connections in Zeek's
`conn.log` with no matching Squid record. Proxy bypass is deliberate evasion, and this
correlation costs nothing to build.

### 7.6 Syslog transport — a deliberate split

Encrypting syslog removes its content from the network sensor while preserving it at the
endpoint. That is the right production answer and the wrong teaching default, so the
range runs both.

**Default: plaintext RFC 5424 over TCP on an isolated management VLAN.** This gives a
third vantage point — the same event visible in the host's own file, in Zeek's
`syslog.log`, and as a parsed document in Kibana — and triangulating across the three is
the most valuable single exercise a log-source curriculum can offer. The isolation is
explicit, and the spec says out loud that this is not the production answer.

**Plus one deliberately TLS-encrypted path**, ideally from a domain controller or jump
host. Students run the identical hunt, find `syslog.log` empty, and rebuild the detection
from `conn.log`, `ssl.log`, and byte volume alone.

A nuance worth building in: **encryption without authentication does not stop spoofing.**
An anonymous TLS listener encrypts (and so blinds the sensor) while authenticating
nobody — anyone can open a session and inject. Only certificate-based auth buys the
anti-spoofing property, which makes a clean two-part lab.

This also sets up the loss-of-telemetry exercises, which map to ATT&CK T1562.006:
stopping the forwarder, firewalling the collector (the host still believes it is
logging — the best teaching moment of the set), repointing to an attacker collector,
raising the severity filter above the heartbeat, and flooding high-severity messages so
the collector's own discard policy drops genuine telemetry. Detection needs four layers:
heartbeats on their own facility, RFC 5424 sequence IDs, **per-data-source** last-seen
rather than per-host, and network-side corroboration from `conn.log` — which works
identically under TLS and is independent of the collector entirely.

### 7.7 Defaults that silently collect nothing

Each of these produces a healthy-looking configuration and an empty index. They are
called out here because every one of them has to be actively set.

1. Security Onion must be **Standalone or Distributed** — Evaluation and Import cannot
   receive agent-forwarded logs at all.
2. **Debian 12 has no `/var/log/mail.log`, `/var/log/syslog`, or `/var/log/auth.log`.**
3. Postfix `maillog_file_permissions` defaults to **0600** — a non-root agent reads nothing.
4. Dovecot **`auth_verbose` defaults to `no`** — no brute-force visibility whatsoever.
5. CUPS **`PageLogFormat` defaults to empty** — page logging is entirely off.
6. Windows **`PrintService/Operational` is disabled** — you get the PrintNightmare attempt
   but never the success.
7. vsftpd **`log_ftp_protocol` is silently ignored** when `xferlog_std_format=YES`.
8. Windows **4688 has no command line** without the second policy setting.
9. Squid must use the `squid` or `extensive` format or the pipeline grok-fails outright.
10. The OPNsense integration **discards unmatched logs** without reporting it.
11. Samba's audit operation names changed (`mkdirat`, `renameat`, `unlinkat`, `openat`) —
    an invalid name makes the module fail to load, which presents as shares refusing to
    mount rather than as a logging error.

### 7.8 Encryption mix

Target **85–95% of external traffic encrypted** and a meaningful minority of internal
traffic too (LDAPS, SMB signing, RDP TLS, internal HTTPS). But not 100%: a range where
every flow is opaque teaches nothing about `http.log`, `files.log`, or file carving. The
design keeps a deliberate cleartext tier where full-content hunting works, an encrypted
majority where analysts must fall back to SNI, JA4, certificate detail, and connection
behaviour, and a TLS 1.3 subset specifically — so students discover `x509.log` going
dark and have to adapt.

---

## 7A. The locked tool stack — implementation

### 7A.1 Security Onion 3.2

Greenfield install from ISO onto Oracle Linux 9, **Standalone** node type, 48 GB.
Standalone is the floor: Evaluation and Import modes do not run Logstash, and Elastic
Agents from other hosts require it — agents on those modes silently do not work.

Nearly every reported problem with 3.x lives in the `soup` upgrade path, which a greenfield
install skips entirely. Hardware requirements are byte-identical between 2.4 and 3.x, so
the version choice costs no RAM.

**Pin before ingest ramps:**

| Setting | Value | Why |
|---|---|---|
| `Elasticsearch.esheap` | 8 GB | the 33% default would take ~16 GB on a 48 GB box |
| Logstash heap | 2 GB | |
| `redis_maxmemory` | 2048 | absorbs bursty exercise traffic; default is a fixed 812 MB |
| `suricata.pcap.conditional` | `alerts` | full capture is ~540 GB/day at 50 Mbps |
| `suricata.pcap.compression` | `lz4` | |

Un-exclude from Elastic ingest: `capture_loss`, `stats`, `known_hosts`, `known_services`.
The first two are how an analyst checks for packet loss — excluded by default, so hunting
for loss in Kibana finds nothing and wrongly concludes there is none.

Enable **BZAR** (MITRE's ATT&CK-mapped SMB/DCE-RPC package) — it ships with Security Onion
and is disabled by default. Install **JA4+** for JA4SSH, which detects reverse shells inside
encrypted SSH. Note JA4+ is FoxIO License 1.1: fine for personal and academic use, not for
monetization.

**Operational gotcha:** custom Elasticsearch ingest pipelines under
`/opt/so/saltstack/local/salt/` do **not** trigger auto state apply. Each of the nine
custom pipelines needs a manual `salt state.apply` after every edit.

**Documentation caveat:** the 3.x docs live at `docs.securityonion.net/en/3/main/`, not at a
version-numbered path. Version-specific URLs 404 and the docs repo has no 3.x branch, so
some 2.4 documentation is still the only reference for unchanged subsystems.

### 7A.2 Elastic Agent + Elastic Defend

**The licensing boundary, stated plainly.** Basic (free) provides **100% of Defend's
telemetry** — every event category on every OS, `logs-endpoint.events.*`, `process.Ext.*`,
process ancestry — plus malware protection and all prebuilt detection rules. It provides
**none of the response surface**: host isolation is Platinum; the response console and
every response action are Enterprise.

There is one **30-day self-managed trial per major version**. Spend it deliberately, on a
concentrated block of response training once a repeatable attack chain exists — not on day
one. A major-version stack upgrade legitimately opens a second window.

**Policy: reverse the defaults Elastic tuned for enterprise data-volume economics.**

| Setting | Default | Set to | Why |
|---|---|---|---|
| `capture_command_line` | **off** | on | silently blinds every rule matching `process.args` |
| `process_ancestry_length` | 5 | 20 | cut from 20 in 8.15 for volume reasons |
| `ancestry_in_all_events` | off | on | |
| `linux.advanced.events.enable_caps` | **off since 8.14** | on | Linux privilege-escalation rules need it |
| `diagnostic.enabled` | on | off | |
| `utilization_limits.cpu` | — | 20–30% | |
| network dedup / process aggregation | on | **off on one victim host** | so beacon cadence survives for the rotating-pivot exercises |

Domain controllers additionally restore registry fidelity
(`disable_registry_write_suppression=true`, `enforce_registry_filters=false`).

**Defend and Sysmon are two parallel telemetry planes, not one.** Verified in Elastic's
ingest pipeline source: Sysmon's `process.entity_id` is the raw ProcessGuid while Defend
computes its own. **They never join** — correlation is on host, PID, and time. Run Defend
wide and narrow Sysmon to its complement: drop image-load and network-connect hard, keep
process-access, named pipes, WMI, and process-tampering wide.

Defend's `process.Ext.effective_parent` resolves the *logical* parent through COM and
svchost brokering, where Sysmon's literal `ParentProcessGuid` is wrong. That is a genuine
capability gap Sysmon cannot close.

**~390 of Elastic's prebuilt rules cannot fire without Defend** (measured from a clone of
`elastic/detection-rules`; 948 declare the endpoint integration). That is the concrete
answer to what running it buys.

**Fleet notes:** Security Onion's highstate reloads its own integration policies over
`endpoints-initial`, so role policies must be created as *new* policies rather than edits.
Snapshot and revert work cleanly because agent identity lives in `fleet.enc` and travels
with the snapshot; the failure modes are unenrolling between snapshot and revert, and
cloning rather than reverting.

**Verify locally:** whether Security Onion's own Sysmon pipeline populates
`process.entity_id` at all. It uses its own parser rather than Elastic's, and the answer
determines whether Sigma-derived and Elastic-derived content share field names.

### 7A.3 Velociraptor — analysis station

**No clients on endpoints.** Velociraptor runs standalone on one VM and is used to analyse
collections that an analyst deliberately acquires.

Deployment is a single binary: `velociraptor gui --datastore /srv/velo-case --noclient`.
No server package, no fleet. 6 GB RAM is ample; **150–300 GB of disk on its own volume** is
the resource that actually matters.

**Pre-load** `Server.Import.Extras` (six bundles including the Triage bundle carrying
`Windows.KapeFiles.Targets`, `Windows.Triage.Targets`, `Linux.Triage.UAC`, plus Registry
Hunter, SQLite Hunter, and Sigma) and `Server.Import.DetectRaptor`, then
`Server.Utils.UploadTools` to materialize tool binaries — including the release binaries the
collector builder itself needs.

**Acquisition** is by **Generic Collector** — an unmodified signed binary plus a separate
config, run on the target. Set `opt_cpu_limit` explicitly, write output to a non-evidence
volume or straight to an SMB drop, and skip full memory acquisition. Rebuild collectors
after every server upgrade.

**Import with an explicit `ClientId` every time.** Range hostname collisions are guaranteed
across linked clones, and the default import path will merge unrelated hosts.

**Integration with Security Onion — push, never patch.** Use the built-in
`Elastic.Flows.Upload` artifact to write a curated allow-list of artifacts into Security
Onion's Elasticsearch from the Velociraptor side. This leaves **zero footprint inside the
Security Onion grid**, so `soup` has nothing of ours to break — the inverse of every
integration that patches nginx or Salt.

- Set `ArtifactNameRegex` to an explicit allow-list, **never the default `.`** — a firehose
  produces mapping conflicts and silent drops.
- **Never route Windows Event Log artifacts through it.** The artifact documents that it is
  unsuitable, because EventData's shape varies and Elasticsearch needs a stable schema.
- Do the ECS mapping in an **Elasticsearch ingest pipeline**, not in VQL — editing a
  built-in artifact shadows it with a custom copy that drifts from upstream on every upgrade.
- **`host.id = ClientId` is the load-bearing join.** Do *not* map `ClientId` to `agent.id`;
  it collides with the Elastic Agent's own.
- **`timestamp` is upload time, not event time.** Fix `@timestamp` in the ingest pipeline
  from the artifact-specific field, or every timeline in Kibana is wrong.

**Do not use `weslambert/securityonion-velociraptor`** — last commit 2022, open issues
confirming it is broken on current versions, and it overwrites firewall and Filebeat files
that `soup` then clobbers. Security Onion never shipped Velociraptor and does not now.

**Verify:** whether an imported collection fires `System.Flow.Completion`, which is what
`Elastic.Flows.Upload` watches. If it does not, drive the upload from a notebook cell
instead — which is arguably better for training anyway, since the analyst then *chooses* to
publish a finding to the SIEM.

**Coexistence:** the offline collector does raw physical-drive and process-memory access —
exactly what an EDR flags. Add the collector binary to Elastic Defend as a Trusted
Application scoped by signer and path, and add a narrow Defender exclusion for that binary
only. **Deliberately do not exclude it from Sysmon** — those raw-access and process-access
events are ground truth, and teaching an analyst to distinguish "the DFIR tool did this"
from "the adversary did this" is a feature of the range.

---

## 7B. Implementation status — 2026-08-15

What is actually live, measured rather than assumed. Doc counts are point-in-time.

### 7B.1 Live telemetry

| Source | Dataset | State |
|---|---|---|
| Zeek | `zeek.*` (19 protocol types) | live |
| Zeek capture health | `zeek.capture_loss`, `known_hosts`, `known_services`, `known_certs` | live — pipelines authored here, SO ships none |
| Suricata alerts | `suricata.alert` | ~110k |
| Suricata anomaly | `suricata.anomaly` | live — pipeline authored here |
| auditd (all 32 containers) | `auditd.log` | ~89k, 208 rules |
| Falco | `falco.alerts_agent` | live, modern eBPF |
| Container journals ×32 | `journald.container` | ~53k |
| Hypervisor syslog | `syslog` | cthuwu + l3e7 |
| Elastic Defend | `endpoint.events.*` | file/process/network |

### 7B.2 The filename *is* the pipeline name

The single most costly mechanism to not know. The Zeek filestream integration dissects
`/nsm/zeek/logs/current/%{pipeline}.log` and sets `@metadata.pipeline = "zeek." + pipeline`;
Logstash passes it through untouched as the Elasticsearch ingest pipeline. Suricata is the
same shape via `suricata.{{event.dataset}}`.

The consequence: **a log with no matching ingest pipeline is shipped and then rejected.**
It is not dropped at the sensor, and nothing in the agent looks unhealthy. SO ships 124
Zeek pipelines and 21 Suricata pipelines; anything outside those sets needs one written
first. Five Zeek pipelines and one Suricata pipeline were authored here for exactly this
reason. Logstash parses nothing and drops nothing — do not go looking there.

### 7B.3 Additions to §7.7 — more defaults that silently collect nothing

12. **Zeek's `exclude_files` regex** drops `capture_loss`, `stats`, `known_hosts`,
    `known_services`, `known_certs`, `ntp` and `ocsp` before Elastic ever sees them. An
    analyst checking Kibana for packet loss finds nothing and concludes there is none.
13. **Suricata runs alert-only.** `eve-log.types` ships as `[alert]`. No anomaly records at
    all, so protocol violations and evasion are invisible.
14. **BZAR ships installed but unloaded**, and is Windows-oriented: against Linux Samba
    there is no `C$`/`ADMIN$`, so T1021.002 cannot fire regardless.
15. **JA4+ ships disabled by licence.** Only BSD-licensed `JA4` (TLS client) is on;
    `JA4S/JA4H/JA4SSH/JA4X/JA4L/JA4T/JA4D` are all `F` pending FoxIO License 1.1.
16. **Zeek discards packets with invalid checksums by default.** On a virtual SPAN feed
    that is most of them — see 7B.4.
17. **Container journals attribute to the host.** `add_host_metadata` overwrites
    `host.hostname`, so all 32 containers appear as `cthost01` until the real value is
    copied aside at input level.
18. **Proxmox 9 ships journald-only** — no rsyslog, and `ForwardToSyslog` must be set or a
    newly installed rsyslog forwards an empty stream while looking healthy.

### 7B.4 Checksum offloading is the SPAN killer

`capture_loss` reported 21–48% loss while every other measurement said the packets arrived:
NIC `drop=0`/`errs=0` across 1.8M packets, `ethtool rx_drops=0`, workers at 1.6% CPU, and a
synchronized VXLAN sample of 131 sent / 131 received. Zeek's own `reporter.log` gave the
answer — invalid TCP checksums from NIC offloading, and *"packets with invalid checksums
are discarded by Zeek"*. With virtio NICs and `tc`-mirrored traffic the checksum is not
computed until the physical NIC, so every mirrored copy looks invalid.

Fix: `redef ignore_checksums = T;`. Checksum validation belongs to the endpoints; a mirror
sensor's job is to analyse what was transmitted. **Any virtual SPAN needs this set.**

### 7B.5 Salt merge semantics decide whether you destroy the config

`pillar.get(..., merge=True)` merges dicts recursively but **replaces lists wholesale**.
Consequences, both encountered:

- `zeek:config:local:load` is a **list** → adding `bzar` means restating all 48 shipped
  entries, or `ja3`/`ja4`/`hassh`/`intel`/`icsnpp`/... are silently dropped.
- `suricata:config:outputs:eve-log:types` is a **dict** (the jinja does `.types.items()`
  and converts back to a list for the rendered YAML) → adding `anomaly` must *not* restate
  `alert`, and writing a list breaks the template outright.

Check which one you are editing before writing. Same file, opposite rules.

### 7B.6 Deliberate non-choices

- **KSM** — measured 0 MB on cthuwu, 106 MB on l3e7 against a ≥25% gate. Containers already
  share page cache through one kernel; there is little anonymous memory to dedupe. Not
  enabled.
- **abuse.ch ThreatFox** — 80,697 IOC rules / 31 MB. Roughly doubles the ruleset for
  signatures that will not fire on synthetic isolated traffic.
- **An agent per container** — ~150 MB × 32 ≈ 4.8 GB. Replaced by one host-side journald
  input reading all 32 journals directly.
- **An agent per hypervisor** — replaced by rsyslog to the syslog listener SO already runs.
- **JA4+ beyond BSD JA4** — a licence acceptance, and therefore the operator's decision.

### 7B.7 Elasticsearch heap

13.2 GB configured, 2.5 GB in use. If memory is ever tight, this is where it is — not KSM.

---

## 8. Attack platform

### 8.1 Pivot and rotation

`pivot01` sits in the fake internet. A shared pool of benign-looking domains (generated
from a public top-sites list, in the TTD manner) serves **both** benign browsing and C2.
Each exercise draws a fresh, previously-unused domain and a fresh address from the same
public-looking ranges the benign hosts use all day.

The pool can never become an indicator, because every workstation hits it constantly.
The analyst must pivot on behaviour — beacon cadence, JA4 fingerprint, request pattern,
rare-destination analysis — rather than on a naming pattern learned last session.

Certificates for the rotating domains are issued by the range's internal CA, so TLS is
internally coherent: the domain in DNS *is* the domain in SNI *is* the name on the cert.
This is a direct benefit of dropping PCAP replay, where `tcprewrite` cannot alter payload
and the rewritten addresses disagree with the original hostnames.

### 8.2 Engines

- **Live C2** — Sliver through the rotating pivot, driven from `operator01`. Produces
  coherent network, endpoint, and identity telemetry simultaneously.
- **ATT&CK emulation** — Caldera and Atomic Red Team for discrete, technique-tagged
  activity, so exercises map to specific ATT&CK IDs and a technique can be hunted in
  isolation.

Both are legitimate security tools, not malware, which satisfies the standing rule that
range hosts carry no live malware.

### 8.3 Controllability

Beacon interval, jitter, protocol, volume, and technique selection are all parameters.
This is the capability the PCAP library could not offer, and the reason for the change.

---

## 9. Verification

Coverage is measured, never asserted. Four gates, run on every estate change:

**Gate 0 — demand model.** Parse the ATT&CK STIX bundle to emit
`technique → detection strategy → analytic → data component → log source` for a
prioritised technique list. Note that **ATT&CK deprecated the DS-xxxx data-source model
in v18 (October 2025)**; the replacement names concrete log channels
(e.g. `wineventlog:security`) rather than abstract categories, which makes coverage
machine-checkable. The contract is built against v18.

**Gate 1 — declared supply.** Generate DeTT&CT's `data-sources.yaml` *from the rendered
estate* — never hand-written, which is how coverage inflation starts. Fail if any Tier-1
technique's visibility drops below threshold.

**Gate 2 — unfireable-rule analysis.** Intersect the Sigma corpus's required
`(logsource, fields)` against the deployed Sysmon config and audit policy. Report rules
that *cannot* fire. This catches the 4688-without-command-line class of failure before a
single VM boots, and it is the cheapest high-value gate in the pipeline. No off-the-shelf
tool does this; building it is defensible original work.

**Gate 3 — empirical proof.** Snapshot, run mapped Atomic Red Team tests across every
host role, wait the ingest interval, then assert **event presence AND required fields
non-empty AND correlatable to the run**, record latency, restore. Asserting on fields
rather than event presence is the single most important design choice here.

**Gate 4 — narrative proof.** Run a Caldera operation from a CTID micro emulation plan
and assert the hunt narrative is reconstructable end to end — the failure mode atomic
tests structurally cannot catch.

Report the gap between the *declared* and *proven* coverage layers as a first-class
number, and drive it toward zero.

### 9.1 Exercise difficulty bands

Carried directly from lab-env, which got this right:

| Metric | Band |
|---|---|
| Malicious share of victim's connections | <2% too hard · 2–35% good · >35% too easy |
| Noise floor | >100 connections from other hosts |
| Alerting hosts estate-wide | >1, or it is a lookup rather than a hunt |

Plus lab-env's hard-won timing rule: malicious share is a property of the *hunt window*,
not the exercise. Run exercises 30–45 minutes before hunting.

### 9.2 The three-tool analyst workflow

This is the range's actual product. Every exercise is built so that no single tool is
sufficient.

```
1. DETECT      Kibana — an alert fires, or a hunt query surfaces an anomaly.
                 Sigma/ET rule, rare-destination analysis, beacon cadence,
                 JA4 fingerprint, unexpected authentication.
                          │
2. TRIAGE      Elastic Defend — what did the process actually do?
                 Full ancestry (depth 20), command line, effective parent
                 through COM/svchost brokering, token and logon-session
                 fields inline, network and file events from the same host.
                 Decide: benign, or does this host warrant examination?
                          │
3. ACQUIRE     A deliberate analyst decision, not a background stream.
                 Build/run a Velociraptor offline collector on that host.
                 Targeted triage profile, not a full image.
                          │
4. ANALYSE     Velociraptor — import with an explicit ClientId.
                 Registry hives, MFT and USN journal, prefetch, Amcache,
                 scheduled tasks, WMI subscriptions, browser history,
                 shellbags and jumplists (workstations only — Server Core
                 has no shell and cannot carry user-activity artifacts).
                          │
5. TIMELINE    Notebooks and VQL over the imported collection.
                 Add to Timeline, annotate, correlate against the SIEM
                 window using host.id.
                          │
6. PROVE       Publish the finding back to Elasticsearch via
                 elastic_upload(), so the artifact evidence sits beside
                 the alert that started it.
```

**What only Velociraptor can answer:** raw NTFS artifacts, the MFT and USN journal,
registry hives, prefetch, deleted-file recovery, and arbitrary queries against live system
state. An exercise that ends at "the EDR showed me the process" is a detection exercise;
one that ends at "and here is the artifact proving what it touched" is a DFIR exercise.

#### 9.2.1 Validation status — 2026-08-15

The workflow above was designed before the build existed. Checked against it:

| Step | State | Detail |
|---|---|---|
| 1. DETECT (Kibana) | **validated** | ~110k Suricata alerts, Zeek notices, and 62,628 rules incl. Stamus lateral. Anomaly records now present. |
| 2. TRIAGE (Elastic Defend) | **partial** | `endpoint.events.process/file/network` flowing with ancestry — but from the Linux container host only. |
| 3. ACQUIRE (Velociraptor) | **blocked** | `velociraptor01` is powered off, pending its move to l3e7. |
| 4. ANALYSE (Velociraptor) | **blocked** | Same, and the artifacts named — MFT, USN, registry hives, prefetch, Amcache, shellbags — are Windows-only. |
| 5. TIMELINE | **blocked** | Depends on 4. |
| 6. PROVE (`elastic_upload`) | **untested** | Depends on 4. |

Two dependencies gate the whole back half, and they are the same two that gate BZAR and
the Stamus ruleset:

1. **Velociraptor must be running** on l3e7 as the analysis station.
2. **The Windows guests must be started** — `range-dc01`, `range-FS01`, `range-SQL01`,
   `range-WEB01`, `range-WS01`, `range-WS02` are all currently stopped. Steps 4–6 are
   defined almost entirely in terms of Windows forensic artifacts, so until then the range
   can run detection exercises but not DFIR exercises.

Put plainly: the range currently supports steps 1–2 well and cannot yet deliver the thing
§9.3 says distinguishes a DFIR exercise from a detection exercise.

### 9.3 Exercise design principles

- **The SIEM alone must be insufficient.** If a Kibana query answers the whole question,
  the exercise is testing rule coverage, not analysis.
- **The acquisition step is a decision.** The analyst must choose to collect, and choose
  what — which is the judgement being trained.
- **Two exercises that fall out of the tooling itself**, and are worth building
  deliberately: *find and exclude your own responder footprint* (the offline collector
  leaves prefetch, USN, Amcache and BAM traces of its own), and *the DFIR tool as the
  attacker's tool* — distinguishing authorised from unauthorised use of an identical
  binary, which is a real and current adversary technique.

---

## 10. Constraints from prior experience on this fleet

These are not theoretical. Each cost real time previously.

1. **`tc mirred` rules die on every container and VM restart.** The veth is recreated and
   the qdisc reverts. A host stays perfectly healthy while silently vanishing from the
   sensor, with nothing to alert on. A start hook is mandatory, and mirror coverage is
   asserted on every verification run.
2. **Mirror ports need MAC learning disabled** (`bridge link set dev X learning off flood on`)
   or they deliver nothing — a bridge never forwards a frame back out the port it arrived
   on. `bridge fdb flush` does not clear already-learned entries; delete them individually.
3. **Isolation vanishes silently in three specific ways**, all previously observed on this
   host: `netfilter-persistent` absent so rules exist but never load; IPv6 entirely
   unsegmented while v4 is correct; and a blanket MASQUERADE that returns from `post-up`
   lines. `range-verify` asserts isolation on a timer, IPv6 included.
4. **No out-of-band recovery exists on this fleet.** No IPMI, no switched PDU. Every
   change to cthuwu's networking ships with the blessing pattern — apply, verify,
   auto-revert unless a check script blesses it — and **no reboot or network change
   happens without asking first.**
5. **Proxmox sensor requirements:** CPU type `host`, NIC offloads disabled on both the
   physical interface *and* the bridge, `ethtool -L … combined 1` on multiqueue NICs.
6. **Snapshot revert breaks the packet-capture pivot** via clock skew — the sensor builds
   its query from the event timestamp and returns empty. Exercise reset must force a time
   re-sync, hypervisor included.
7. **BPF filters must be written twice** — `<filter> or (vlan and <filter>)` — or they
   silently match nothing on tagged traffic.
8. **Stenographer strips VLAN tags.** Any lab teaching VLAN analysis needs Suricata PCAP.
9. **Detection content is retrieved, never generated.** Sigma rules, ATT&CK IDs, auditd
   rulesets, and Sysmon configs come from upstream repos pinned to a commit. An earlier
   project shipped invented CLI flags in ~44 of 61 modules by asking a model to produce
   facts it did not have.
10. **Never inline a multi-line script through `wsl → ssh`.** Write it to a file and pipe
    it. Four quoting layers previously cost seven failures in one session.

---

## 11. Repository layout

```
estate/                 the enterprise, as data. No code.
  segments.yaml         VLANs, CIDRs, gateways, policy
  hosts.yaml            name, role, segment, address, render: [lxc|vm|both]
  identity.yaml         users, groups, service accounts
  domains.yaml          shared pool + generation rules
  profiles.yaml         cthuwu (ram-bound) | xeon (cpu-bound) sizing
render/
  lxc/                  materializes hosts.yaml as containers on cthost01
  pve/                  materializes hosts.yaml as Proxmox VMs
  common/               idempotence, --check/--revert, verification
roles/                  one directory per role, edition-agnostic
  <role>/install.sh · noise.py · verify.sh
identity/               renders identity.yaml into Samba AD and Windows AD
noise/                  diurnal engine: curve, weekday factor, per-role scheduling
attack/
  pivot/                domain pool, split-brain DNS, internal CA, rotation state
  c2/                   Sliver listeners bound to the rotating domain
  emulate/              Caldera + Atomic operations, ATT&CK-tagged
telemetry/
  span/                 tc mirred + restart hookscript
  agents/               Elastic Agent, Sysmon config, auditd rules (pinned upstream)
  pipelines/            Elasticsearch ingest pipelines per custom source
  velociraptor/         client deployment, artifact packs
measure/                the four gates, the difficulty bands, the estate audit
docs/                   specs, runbook, answer keys
site.env                GITIGNORED. Real hostnames, IPs, credentials.
```

`site.env` is the only file that knows this is cthuwu. Everything committed refers to
`${SPAN_IFACE}`, `${SENSOR_HOST}`, `${MGMT_CIDR}` — which is what makes the repo
publishable and the migration a configuration change.

---

## 12. Build order

Each phase is independently useful and independently verifiable.

| Phase | Deliverable |
|---|---|
| 0 | `estate/*.yaml` + renderer skeleton + `range-verify`. Nothing deployed |
| 1 | **Reclaim:** strip rick to headless 8 GB; cap ZFS ARC to 4 GB; raise `kernel.keys.maxkeys`; enable the in-kernel KSM advisor. No range components yet |
| 2 | Bridges, VLANs, `fw01`, segment policy proven by `range-verify` |
| 3 | `cthost01` (Debian 13 + Incus, isolated idmaps) + container edition rendered; Falco and narrow auditd on its kernel; Zeek sees all nine VLANs |
| 4 | Noise engine: every Zeek log type the contract names actually exists |
| 5 | Security Onion 3.2 built fresh on Oracle Linux 9, 48 GB, separate `/nsm` volume, dedicated range mirror bridge |
| 6 | Gold images + telemetry acceptance gate; VM edition rendered; AD live; **KSM reclaim measured against the ≥25% gate** |
| 7 | Elastic Agent + Defend deployed with the fidelity policy; Velociraptor analysis station stood up with artifact bundles pre-loaded |
| 8 | Full telemetry contract, including the nine custom ingest pipelines (Postfix, Dovecot, vsftpd, CUPS, Samba, BIND, dnsmasq, Kea, Veeam); Gates 0–2 passing |
| 9 | Attack platform: pivot, rotation, Sliver, Caldera; Gates 3–4 passing |
| 10 | First end-to-end exercise, run across all three tools and scored against the difficulty bands |

---

## 13. Open questions

Carried from research, to be resolved empirically before the phases that depend on them.

**Resolved since the first draft** — kept for the record: Security Onion 3.x ingest-pipeline
handling is unchanged from 2.4, same path, same parse-in-Elasticsearch model. The container
host's inotify limits are already at 4,194,304 watches, so file-integrity coverage is not
watch-constrained. **Ludus was evaluated and rejected** — it rewrites host networking, has
no LXC support at all, and its Sysmon role is paid while audit-policy, script-block-logging,
auditd and Suricata roles do not exist; its Packer templates and a few Ansible roles are
worth vendoring, nothing else.

1. Whether Security Onion's own Sysmon ingest pipeline populates `process.entity_id`. It
   uses its own parser rather than Elastic's, and the answer decides whether Sigma-derived
   and Elastic-derived content share field names. **Highest-priority unknown** — it shapes
   how Sysmon-side detections get authored.
2. Whether an imported Velociraptor collection fires `System.Flow.Completion`, which is
   what `Elastic.Flows.Upload` watches. If not, uploads run from a notebook cell instead.
3. Real KSM reclaim across six identical Windows clones on this hardware. No good published
   Windows-on-Proxmox measurement exists; the 25–30% planning figure is interpolated, and
   the concurrent-workstation decision depends on it.
4. Sysmon for Linux events 2 and 22 — verify empirically that they fire before designing
   timestomping or DNS detections on them.
5. Whether the built-in Windows 11 Sysmon optional feature exists on LTSC and Server
   2022 Core — it does not coexist with standalone Sysmon.
6. Whether the AppLocker "MSI and Script" channel exists on Server Core. Documentation does
   not settle it; two `wevtutil` commands do.
7. JA4+ is under the FoxIO License 1.1: permissive for internal and academic use, not for
   monetization. Fine for personal practice; needs review if this ever ships commercially.
8. Does Zeek's syslog analyzer parse TCP on the sensor image we build? Older Zeek shipped
   it UDP-only, which would silently break the plaintext-syslog teaching path.
9. Measure — do not assume — the throughput cost of MariaDB `server_audit`, MSSQL audit,
   and Windows 5145 auditing on this hardware. Every published figure found was an
   estimate.
10. Does the pf filter log carry any pre/post-NAT correlation field, or must both sides be
    joined on destination, ports, and time?

---

## 14. Explicitly out of scope

- Cloud telemetry. Red Canary's most-observed technique is a cloud one, and an on-prem
  range cannot cover it. Stated rather than hidden.
- PCAP replay of real malware captures.
- Multi-operator tooling, installers, and menus — this is a single-operator range.
- Commercial detection content (ET Pro, Stamus NRD).
