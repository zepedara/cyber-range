# Unified Cyber Range — Build Guide

Companion to `../specs/2026-08-14-unified-cyber-range-design.md`. The spec says what the
range *is*; this says what is *built*, what is *not*, and in what order to close the gap.

Every "NOT BUILT" line below is a measurement taken against the running range on
2026-08-15, not an assumption. Where a number is quoted, the command that produced it is
named so it can be re-run.

---

## 0. How to read this

| Mark | Meaning |
|---|---|
| ✅ | Built **and verified** by a command whose output is quoted |
| 🟡 | Partially built — specifics stated |
| ❌ | Not built |
| 🔒 | Blocked on something outside this document |

**Acceptance rule, borrowed from lab-env and adopted here:** *measure after every change*.
A change is not done when it is applied; it is done when a query proves it took effect.

---

## 1. Where the build actually stands

### 1.1 Telemetry — largely ✅

| Item | State | Evidence |
|---|---|---|
| Zeek 19 protocol log types | ✅ | `logs-zeek-so` populated |
| Suricata alerts | ✅ | 110,388 docs |
| Suricata **anomaly** | ✅ | 1,222 docs; pipeline authored here |
| Zeek `capture_loss` / `known_*` | ✅ | pipelines authored here; SO ships none |
| `conn_long` | ✅ built | upstream corelight script + generated pipeline |
| auditd, all 32 containers | ✅ | 141,834 docs, 208 upstream rules |
| Falco (modern eBPF) | ✅ | proven to see *inside* containers |
| 32 container journals | ✅ | 53k docs, host-side input, `container.name` fixed |
| Hypervisor syslog | ✅ | cthuwu 2,673 / l3e7 1,294 |
| Suricata rulesets | ✅ | 51,672 → 62,628 (Stamus lateral, SSLBL, Feodo) |
| Checksum-offload packet discard | ✅ fixed | 57.73% → 0.32% loss |

### 1.2 The enterprise itself — mostly ❌

Inventory of listening ports in all 32 containers:

| Host | Listening | State |
|---|---|---|
| dc01 | `53` | ❌ **not a domain controller.** No LDAP 389, Kerberos 88, SMB 445, GC 3268 |
| web01 | `21, 80, 443` | ✅ TLS added 2026-08-15 (6 SANs, JSON logging) |
| proxy01 | `80, 443` | 🟡 nginx, **not Squid** — no `ssl_bump`, no `extensive` logformat |
| ca01 | — | 🟡 root CA built and distributed to all 32; host itself passive |
| mon01 | — | ❌ empty |
| bk01 | — | ❌ empty |
| app01 | `22` | ❌ no application |
| bastion01 | `22` | 🟡 shell only |
| fs01 | `22,137,138,139,445` | ✅ Samba |
| mail01 | `25,110,143,993,995` | ✅ Postfix + Dovecot |
| sql01 | `3306` | ✅ MariaDB 11.8.6 |
| pivot01 | `53,80,443` | ✅ attacker infra, rotating domains |

### 1.3 Measured traffic realism — ❌

From a full day of `conn.log` / `dns.log` / `ssl.log` / `http.log`:

| Metric | Measured | Target | Source of target |
|---|---|---|---|
| Connection **failure** rate | **69.5%** (S0 55.7 + REJ 13.8) | SF should dominate | — |
| Encrypted share of web | **23.0%** | 85–95% | spec §7.8 |
| Distinct JA3/JA4 client fingerprints | **3** | dozens | spec §7.1 |
| Distinct HTTP User-Agents | **3** (curl, APT) | dozens–hundreds | — |
| Distinct SNI | **21** | thousands | — |
| Distinct DNS domains (whole range) | **84** | — | lab-env went 10→83 |
| Domains per client | **29–33** | hundreds | — |
| DNS share of all connections | **57.4%** | ~5–15% | — |
| Servers (VLAN 10) share | **1.0%** | server-heavy | — |
| Traffic in top-10 host pairs | **49.5%** | long tail | — |
| Diurnal variation | **±0.5%** over 9h (flat) | visible curve | spec / lab-env |
| conn duration p50 | **0.00s** | — | — |
| HTTP methods / statuses | **100% GET, 100% 200** | mixed | — |

> lab-env's build guide records its own encryption ratio going **22.9% → ~40%**. Ours
> measures **23.0%** — this range is sitting almost exactly at lab-env's pre-improvement
> state, which is a useful confirmation that the gap list below is the right one.

### 1.4 Never built at all

| Phase | Deliverable | State |
|---|---|---|
| 0 | `estate/*.yaml`, renderer, `range-verify` | ❌ **the repo contains no code — only README and the spec** |
| 6 | Gold images + telemetry acceptance gate | ❌ |
| 6 | AD live | ❌ |
| 8 | Nine custom ingest pipelines (Postfix, Dovecot, vsftpd, CUPS, Samba, BIND, dnsmasq, Kea, Veeam) | ❌ none |
| 9 | Sliver, Caldera | ❌ |
| 9 | Gates 0–4 (§9 verification) | ❌ none |
| 10 | First end-to-end exercise | ❌ |
| — | GHOSTS NPC framework | ❌ (both reference projects use it) |
| — | Windows guests running | ❌ all 8 stopped |

---

## 2. What the two reference projects have that we do not

**They are separate projects with different shapes** — TTD is a Docker/compose red-team lab,
lab-env is a measured LXD noise-and-hunt range. Neither is our build guide; both are sources
of technique.

### From `Icarus4122/tiger-team-defense`

| Component | Ours |
|---|---|
| GHOSTS client provisioning (`scripts/11-get_ghosts_client.sh`) | ❌ |
| Caldera (`images/lab_caldera`) | ❌ |
| Mythic (`images/lab_mythic`) | ❌ |
| Sliver (`scripts/13-get_sliver_packages.sh`) | ❌ |
| SNMP traffic simulation (`lab_snmp/simulate_snmp_traffic.py`) | ❌ no SNMP at all |
| Telnet service (`lab_telnet`) | ❌ |
| Fake mail generation (`lab_mail/generate_fake_mail.sh`) | 🟡 SMTP noise only |
| DB bait data (`lab_db/generate_bait.sh`) | 🟡 `corpdb` exists |
| Domain scraping for C2 (`lab_attacker/scrape_domains.sh`) | ✅ equivalent built |
| Windows client + server images | ❌ stopped |

### From `zepedara/lab-env`

| Component | Ours |
|---|---|
| `36-internal-pki.sh` | ✅ built 2026-08-15 |
| `38-ws01-real-https.sh` | ✅ built 2026-08-15 |
| `05-encryption-ratio.sh` + pass two | ❌ not measured as a gate |
| `25-new-role-services.sh` (43 KB service buildout) | ❌ |
| `33-mon01-app02-real-services.sh` | ❌ mon01/app01 empty |
| `56-timeline-names-and-browser-ua.sh` (UA diversity) | ❌ 3 UAs |
| `64-noise-amplifier.sh` | ❌ |
| `57-kit-generators-off-dead-subnet.sh` | ❌ |
| `44-network-segments.sh` / `50-segment-policy.sh` | ✅ equivalent built |
| `31-syslog-over-tls.sh` | 🟡 syslog is TCP, not TLS |
| `AUDIT.sh`, `TEST-CYCLE.sh`, `tool-hunt-verify.sh` | ❌ no verification harness |
| PCAP replay of 137 scored malware captures | ❌ |
| Kerberos domain join | ❌ |
| LLMNR name proliferation (1 → 40) | ❌ |

---

## 3. Ordered build plan

Ordering rule: **fix what makes every other measurement lie, first.** A broken resolver and
a hollow service tier corrupt every realism number, so they precede noise work.

### Phase A — Correctness (nothing else is trustworthy until these are true)
1. **A1** Resolve the 69.5% connection-failure rate. `dns.log` shows 79% of records with no
   rcode. dc01 answers correctly when queried directly; extdns01 (10.30.30.13) **times out**
   from clients yet receives ~4,380 connections per workstation. Find and fix the mismatch.
2. **A2** Fix the search-domain bug producing `files.corp.range.lan.range.lan` (3,288 queries).
3. **A3** l3e7 NIC carrier flapping — diagnose properly and add failsafes (see Phase F).

### Phase B — Identity (unblocks the largest class of detections)
4. **B1** Samba AD DC on dc01: LDAP, Kerberos, SMB, GC. Preserve DNS — every container
   resolves through dc01 today, so snapshot first.
5. **B2** A realistic user population with SPNs, so Kerberoasting/AS-REP are exercisable.
6. **B3** Join workstations to the domain (Kerberos traffic only exists if someone authenticates).

### Phase C — Service tier
7. **C1** Squid on proxy01 with `logformat extensive` + `ssl_bump peek/splice`; point
   workstation egress through it. Enables the spec's highest-value panel: *egress in
   `conn.log` with no matching Squid record*.
8. **C2** app01 — an application holding a **persistent MariaDB pool** (also fixes `conn_long`).
9. **C3** mon01 — polling monitoring (server-to-server traffic, currently ~absent).
10. **C4** bk01 — nightly bulk transfer from fs01/sql01 (off-hours large-transfer shape).
11. **C5** SNMP + telnet services (TTD has both; we have neither).
12. **C6** Per-service logging beyond defaults: Samba `vfs_full_audit`, Dovecot
    `auth_verbose`, MariaDB `server_audit`, vsftpd `log_ftp_protocol` with
    `xferlog_std_format=NO`, dnsmasq `log-queries=extra`.

### Phase D — Traffic realism
13. **D1** Noise on all 32 containers, **role-aware** (currently 9 workstations only).
14. **D2** Long-lived sessions across many hosts — IMAP IDLE, DB pools, mapped SMB —
    so "long connection" is not a synonym for "malicious".
15. **D3** Browser/User-Agent and JA3/JA4 diversity (3 → dozens). GHOSTS is the instrument
    both reference projects use; its client runs **without** the API server.
16. **D4** Domain/destination diversity: 84 → several hundred, with a believable NXDOMAIN rate.
17. **D5** Make the diurnal curve visible in hourly connection volume.
18. **D6** Mixed HTTP methods and statuses (POST, 401, 403, 404, 500) — currently 100% GET/200.
19. **D7** Encryption ratio 23% → 85–95%, measured as a gate.

### Phase E — Attack platform and exercises
20. **E1** Sliver and Caldera.
21. **E2** Start the Windows estate; unblocks BZAR, Stamus lateral, and analyst steps 3–6.
22. **E3** Velociraptor to l3e7 and running.
23. **E4** First end-to-end exercise scored against the difficulty bands.

### Phase F — Engineering the build itself
24. **F1** `range-verify` — assert mirror coverage, segment isolation, log-type presence.
25. **F2** `estate/*.yaml` + renderer, so the estate is declarative rather than hand-built.
26. **F3** The nine custom ingest pipelines.
27. **F4** Gates 0–4.
28. **F5** Fleet failsafes: peer-hypervisor watchdog with phone alerting, autostart assertion,
    telemetry-gap markers.

---

## 4. Standing traps

Carried forward so they are not rediscovered. Full detail in spec §7B and §10.

- **The log filename IS the ingest pipeline name** (Zeek and Suricata). No pipeline ⇒ the
  document is shipped and then rejected at Elasticsearch, with nothing looking unhealthy.
- **Zeek discards invalid-checksum packets**, which on a virtual SPAN is most of them.
  `redef ignore_checksums = T`.
- **Salt merges dicts recursively but replaces lists.** `zeek …local:load` is a list;
  `suricata …eve-log:types` is a dict. Opposite correct edits in the same file.
- **Never pipe content through `sudo -S`** — with cached credentials the password becomes
  line 1 of the file.
- **`sudo wc -l < file`** performs the redirect as the calling user.
- Zeek emits a protocol log **only** when it observes that protocol. No AD ⇒ no
  `kerberos.log` ⇒ no identity detections, however good the rules are.
