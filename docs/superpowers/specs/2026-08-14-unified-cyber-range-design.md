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
| 6 | Analysis stack | Security Onion / Kibana, Elastic Agent for endpoint, Velociraptor for forensics |
| 7 | Sensor version | Build for Security Onion 3.0, sensor-agnostic |
| 8 | Architecture | One enterprise, two renderings, shared identity plane |
| 9 | Container kernel | Dedicated container-host VM, not the hypervisor |
| 10 | Repo visibility | Public — therefore no real fleet addressing in committed files |

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

| Component | GB |
|---|---|
| `rick` (VM 100) — off limits | 32 |
| ZFS ARC + host | 11 |
| Security Onion (lean profile) | 32 |
| Velociraptor | 4 |
| operator01 (ex-`kali`) | 3 |
| **Range** | **~43** |

Range allocation:

| Component | GB |
|---|---|
| Container-host VM + ~45 containers | 12 |
| dc01, dc02 (Server Core) | 4.5 |
| fs01, sql01 (Server Core) | 5 |
| wk01–wk06 (Win11 LTSC linked clones, KSM-shared) | 18 |
| pivot01 (Debian minimal) | 1.5 |
| fw01 (OPNsense) | 1.5 |
| **Total** | **42.5** |

### 4.3 VM repurposing map

Existing VMs are renamed and re-provisioned rather than built fresh.

| Existing | Becomes |
|---|---|
| `range-dc01` (150) | **dc01** — Windows AD, Server Core |
| `range-WEB01` (153) | **dc02** — second DC |
| `range-FS01` (151) | **fs01** — file server |
| `range-SQL01` (152) | **sql01** — MSSQL + audit |
| `range-WS01/WS02` (154/155) | **wk01, wk02** |
| `irtest-win10ent` (3010) | **wk03** (Win10 LTSC) |
| `irtest-win11ent` (3011) | **wk04** (Win11 LTSC) |
| `redinfra01` (210) | **pivot01** — attack platform |
| `sandbox01` (130) | **fw01** — OPNsense |
| `kali` (146) | **operator01** — Sliver + Caldera console |
| `dfir-ws` (141) | **analyst01** — the hunting workstation |
| new | **cthost01** — container-host VM |
| new | **wk05, wk06** — linked clones of the wk gold image |

Untouched: `rick` (VM 100), `soc-securityonion` (170), `velociraptor01` (102).

### 4.4 The container-host VM

Containers cannot produce syscall telemetry (§7.3). That telemetry must come from the
kernel they run on — which must not be the hypervisor.

`cthost01` is a Debian VM running the ~45 range containers, with `auditd` and Falco
instrumenting its own kernel. This gives full syscall coverage of the container estate
with clean per-container attribution, leaves cthuwu completely uninstrumented, and makes
migration to the larger host a matter of moving one VM.

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
| 1 | Bridges, VLANs, `fw01`, segment policy proven by `range-verify` |
| 2 | `cthost01` + container edition rendered; Zeek sees all nine VLANs |
| 3 | Noise engine: every Zeek log type the contract names actually exists |
| 4 | Security Onion 3.0 rebuilt, lean profile, separate `/nsm` disk, range mirror bridge |
| 5 | Gold images + acceptance gate; VM edition rendered; AD live |
| 6 | Full telemetry contract deployed, including the nine custom ingest pipelines (Postfix, Dovecot, vsftpd, CUPS, Samba, BIND, dnsmasq, Kea, Veeam); Gates 0–2 passing |
| 7 | Attack platform: pivot, rotation, Sliver, Caldera; Gates 3–4 passing |
| 8 | First end-to-end exercise, scored against the difficulty bands |

---

## 13. Open questions

Carried from research, to be resolved empirically before the phases that depend on them.

1. Does Security Onion 3.0 change the Elastic Agent enrollment or ingest-pipeline story
   materially versus 2.4? (Affects Phase 4 and 6.)
2. Does Elastic Defend resolve LXC container *names*, or only IDs? If names, the
   container attribution glue gets simpler.
3. Sysmon for Linux events 2 and 22 — verify empirically that they fire before designing
   timestomping or DNS detections on them.
4. `fs.inotify.max_user_watches` on the container host, and whether privileged containers
   share one budget. Determines whether file-integrity coverage across 45 containers is
   real or silently partial.
5. Whether the built-in Windows 11 Sysmon optional feature exists on LTSC and Server
   2022 Core — it does not coexist with standalone Sysmon.
6. Ludus (Proxmox-native range orchestrator, very actively developed) — evaluate whether
   its role model is worth adopting for `render/pve` rather than building from scratch.
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
