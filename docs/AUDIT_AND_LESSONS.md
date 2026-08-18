# Environment Audit and Lessons Learned

**Audited:** 2026-08-18 / 2026-08-19 UTC, by direct measurement against the running range.
**Audience:** whoever builds this next. Everything below is measured unless explicitly labelled
otherwise, and where a number contradicts something this project claimed earlier, the contradiction
is stated rather than quietly fixed.

---

## How to read this document

This project's defining lesson is that **the hard part was never the technology — it was knowing
whether a measurement meant what it appeared to mean.** At least eight confident diagnoses in this
build were later proven wrong, and three tasks were marked "complete" with no measurement at all.

So this document separates three things that are easy to conflate:

1. **What is measurably true right now** (Part 1) — the audit.
2. **What was accomplished** (Part 2) — with the number that proves each claim.
3. **What was learned, including everything gotten wrong** (Parts 3–5) — the most valuable part.

If you read only one section, read **Part 4 — the measurement traps**. It is what the time was
actually spent on.

---

# Part 1 — Environment audit, measured

## 1.1 Hypervisor (`cthuwu`)

| Property | Measured value |
|---|---|
| Proxmox | `pve-manager/8.4.19`, kernel `6.8.12-39-pve` |
| CPU | AMD Threadripper 3960X — 24 cores / **48 threads**, 1 socket |
| RAM | **125 GB total, 94 GB used, 31 GB available** |
| Guests defined | **29** |
| Guests running | **12** |
| Bridges | `vmbr0, vmbr1, vmbr20, vmbr30, vmbr40, vmbr50, vmbr59, vmbr60, vmbr61, vmbr90, vmbr91` |
| Storage | `vmstore` 1.72 TB (58% used), `vmdata` 902 GB (27%), `hot` 3.84 TB (71%) |

**The host is RAM-bound, not CPU-bound** — 31 GB free against 48 threads. This single fact shaped
almost every design decision, and it is the constraint that *inverts* on the migration target
(24 threads / 384 GB), which is why the sizing advice in the build plan is deliberately different.

Running guests:

| VMID | Name | RAM | Role |
|---|---|---|---|
| 170 | `so01` | 40 GB | Security Onion — SIEM + sensor |
| 310 | `cthost01` | 24 GB | Incus container host |
| 300 | `fw01` | 4 GB | OPNsense — every VLAN gateway |
| 150 | `range-dc01` | 6 GB | Windows domain controller |
| 151–153 | `range-FS01/SQL01/WEB01` | 6 GB each | Windows server tier |
| 154–155 | `range-WS01/WS02` | 4 GB each | Windows workstations |
| 161 | `ghosts01` | 6 GB | GHOSTS API |
| 146 | `kali` | 4 GB | Attack platform (idle) |
| 100 | `rick` | 6 GB | Unrelated host, excluded from the range |

17 further guests are defined but stopped (FLARE, REMnux, SIFT, IR test hosts, templates).

### SPAN discipline — verified correct

```
vmbr91 ageing_time=0
port spanmir-br  learning=0
port tap170i1    learning=0      <- so01's monitor NIC
port tap310i2    learning=0
```

This configuration is **load-bearing and non-obvious**. See §4.2.

## 1.2 Container host (`cthost01`)

| Property | Measured value |
|---|---|
| OS | Debian GNU/Linux 13 (trixie) |
| Incus | 6.0.4 |
| Resources | 12 vCPU, 23 GB RAM (6 GB used) |
| Containers | **32, all RUNNING** |
| Host instrumentation | `auditd` **active**, `falco` **active** |
| Time source | `10.20.0.61` — range-internal ✅ |

Full inventory, with which traffic generator is live on each:

| Container | Address | Segment | webnoise | noise |
|---|---|---|---|---|
| `dc01` | 10.30.10.10 | SERVERS | active | – |
| `fs01` | 10.30.10.11 | SERVERS | active | – |
| `sql01` | 10.30.10.12 | SERVERS | active | – |
| `app01` | 10.30.10.13 | SERVERS | active | – |
| `ca01` | 10.30.10.14 | SERVERS | active | – |
| `bk01` | 10.30.10.15 | SERVERS | active | – |
| `mon01` | 10.30.5.10 | MGMT | active | – |
| `bastion01` | 10.30.5.11 | MGMT | active | – |
| `wk01`–`wk05` | 10.30.20.101–105 | USERS | active | **active** |
| `wk-test` | 10.30.20.100 | USERS | active | – |
| `newhost01` | 10.30.20.106 | USERS | active | – |
| `web01` | 10.30.30.10 | DMZ | active | – |
| `mail01` | 10.30.30.11 | DMZ | active | – |
| `proxy01` | 10.30.30.12 | DMZ | active | – |
| `extdns01` | 10.30.30.13 | DMZ | active | – |
| `pbx01` | 10.30.40.100 | VOICE | active | – |
| `phone01`–`02` | 10.30.40.101–102 | VOICE | active | – |
| `cam01`–`02` | 10.30.45.100–101 | OT/IoT | active | – |
| `badge01` | 10.30.45.102 | OT/IoT | active | – |
| `hvac01` | 10.30.45.103 | OT/IoT | active | – |
| `br-fs01` | 10.30.60.100 | BRANCH | active | – |
| `br-wk01`–`02` | 10.30.60.101–102 | BRANCH | active | **active** |
| `byod01`–`02` | 10.30.70.100–101 | GUEST | active | – |
| `pivot01` | 10.30.99.10 | FAKE-INTERNET | **inactive** | – |

`noise` (the corporate SMB/SMTP/FTP/LDAP generator) runs **only** on corporate-segment hosts.
It was deliberately disabled on `byod01/02` — see §3.6.

## 1.3 SIEM (`so01`)

| Property | Measured value |
|---|---|
| OS | Red Hat Enterprise Linux 9.8 |
| Resources | 12 vCPU, 38 GB RAM (28 GB used) |
| Cluster health | **green**, 1 node, **231 active shards, 0 unassigned** |
| Index size | **3,827,590 docs / 3.3 GB** (`logs-*` primaries) |
| 24-hour ingest | **3,607,452 docs** |
| Distinct hosts reporting | **21** |
| VLANs visible to Zeek | **9 of 9** ✅ |

**Not verified:** the Elasticsearch heap. A host-level `ps` returned a single `Xmx1000m`, but the
`org.elasticsearch.bootstrap` process was not visible from the host because Security Onion runs
Elasticsearch **inside Docker**. The 1000m figure therefore belongs to some other JVM and **must not
be read as the ES heap.** Recording this rather than reporting a number I could not confirm.

### Zeek VLAN coverage (24 h) — east-west visibility confirmed

```
VLAN 20: 102,641   VLAN 60: 38,007   VLAN 10: 27,890   VLAN 45: 22,614
VLAN  5:  21,450   VLAN 70: 19,773   VLAN 30: 18,866   VLAN 40: 17,023
VLAN 99:      20   <-- see finding F4
```

## 1.4 Telemetry composition (24 h, 3.6 M docs) — the most revealing table in the audit

| Dataset | Docs | Share |
|---|---|---|
| `journald.container` | 945,401 | **26.2%** |
| `auditd.log` | 887,831 | **24.6%** |
| `zeek.dns` | 434,716 | 12.1% |
| `zeek.conn` | 285,405 | 7.9% |
| `endpoint.events.file` | 181,083 | 5.0% |
| `system.syslog` | 121,946 | 3.4% |
| `zeek.dce_rpc` | 116,502 | 3.2% |
| `zeek.ssl` | 96,202 | 2.7% |
| `syslog.syslog` | 70,855 | 2.0% |
| `suricata.alert` | 60,439 | 1.7% |
| `windows.sysmon_operational` | 50,625 | **1.4%** |
| `soc.server` / `soc.sensoroni` | 84,899 | 2.3% |
| `system.security` | 37,803 | 1.0% |
| `endpoint.events.*` (library/process/network/security) | 84,118 | 2.3% |
| `zeek.http` | 16,599 | 0.5% |
| everything else | remainder | — |

Per-host, the top contributors are:

```
cthost01   1,907,238    <- 53% of ALL telemetry, from ONE host
so01         294,147    <- 8%, the SIEM observing itself
ws02         182,278
ws01          56,423
ir-dc01       34,616
sql01         29,516
fs01          25,191
web01          9,376
```

**Finding F1 — half of all telemetry is Linux infrastructure noise, not enterprise activity.**
`journald.container` + `auditd.log` = **50.8%** of everything ingested, and `cthost01` alone produces
**53%** of all documents. The modelled *company* — Windows endpoints, network sessions, application
logs — is a minority of the data. This is not fatal (the range still hunts well) but it distorts
storage planning and any "how much telemetry does an enterprise produce" intuition drawn from it.

**Finding F2 — Windows endpoint telemetry is only 1.4% of ingest**, which is far below a real
enterprise's profile, where endpoint process telemetry usually dominates. Cause: only 6 Windows
guests against 32 Linux containers plus two very chatty Linux infrastructure sources.

**Finding F3 — Sysmon volume is still above target.** Measured per host over 60 minutes and
extrapolated: `ws02` 20,808/day, `fs01` 20,712/day, `sql01` 20,592/day, `ir-dc01` 13,992/day,
`ws01` 12,216/day, `web01` 10,248/day — against a 5,000–10,000/day target. **Every host is over**,
by 1.0× to 2.1×. Estate-wide Sysmon is ~98,568/day. Event ID 3 (network connection) is **48.0%** of
all Sysmon, followed by ID 11 (file create) 20.0% and ID 7 (image load) 18.9%. Process creation
(ID 1) is only 3.7%. **This is the signature of generator-driven network activity, not config
verbosity** — which matters because the two have opposite fixes.

**Finding F4 — the fake-internet segment is effectively dead.** VLAN 99 shows **20 connections in
24 hours**, and `pivot01` (its only host) has its generator **inactive**. The "external" tier that
the design depends on for realistic egress and for the future attacker pivot is not producing
traffic. This is the single largest realism gap in the current build.

---

# Part 2 — What was accomplished, with the proof

Each row states the measurement that justifies it. Where a claim was previously overstated, it is
corrected here.

## 2.1 Platform and visibility

| Achievement | Proof |
|---|---|
| Security Onion consolidated from a second hypervisor onto `cthuwu`, keeping its address and MACs | `so-status` clean, cluster **green**, 203k docs at cutover |
| East-west visibility across every segment | Zeek sees **9 of 9 VLANs** with tags (§1.3) |
| Container journald + service logs shipped to the SIEM | `journald.container` = 945k docs/24 h |
| Hypervisor logs shipped | `system.syslog` = 122k docs/24 h |
| Suricata anomaly logging enabled | `suricata.anomaly` = 14,135 docs/24 h |
| BZAR (ATT&CK SMB/DCE-RPC) enabled | `zeek.dce_rpc` = 116,502 docs/24 h |
| `conn_long` detection firing | `LongConnection::found` 88 in 24 h |
| Zeek `capture_loss` root-caused to checksum offloading and fixed | loss returned to ~0 with traffic *confirmed present* |

## 2.2 Identity and application realism

| Achievement | Proof |
|---|---|
| AD rebuilt as a genuine HR directory | 4-level org chart; **2,360** name attributes populated; **86** service accounts cleaned |
| Directory-change auditing working end-to-end | event **5136** observed after a test attribute change |
| SIEM → HR pivot possible | `corpdb` rebuilt from AD, pivot verified **33/33 = 100%** |
| Per-host user assignment (so anomalies are possible at all) | logons now draw from per-host user sets, not one shared account |
| File servers actually serving | `bk01`/`br-fs01` serve real SMB and receive sessions; `zeek.smb_mapping` = 7,573/24 h |
| Windows endpoint telemetry restored across the estate | **6/6** hosts reporting; 4688 **with command line** confirmed |

## 2.3 Network realism

| Achievement | Before | After |
|---|---|---|
| Public egress from the range | 221,487/day | **0** |
| Connection failure rate (S0/REJ) | **71.7%** | **4.51%** |
| Unique JA3 fingerprints (60 min) | 12 | **67** |
| Top single JA3 share | — | **7.29–7.78%** |
| TLS session resumption | 0.4% | **32.6%** (peak hours) |
| Diurnal peak:trough, containers | flat/inverted | **5.5×** |
| Diurnal peak:trough, Windows | assumed flat | **2.11×** web / **3.13×** DNS |
| auditd volume | baseline | cut **40.3%**, then a further **46.6%**, then **10.6%** |
| DNS self-noise | baseline | cut **94.4%** |

## 2.4 The two headline fixes of the final session

**A. Step 4 (client diversity) reached 5 of 5 sub-gates** at 18:29Z: JA3 67, top JA3 7.78%, UA 83,
top UA 19.98%, resumption 32.61%. Two root causes, both of which were *misunderstood* first:

- JA3 was capped by **host count, not profile count** — the generator picks a TLS profile per host,
  so 31 containers sharing a 12-entry pool could never exceed 12 fingerprints. Widening the pool to
  80 configurations took containers 40–46 → 57 and the estate to 67.
- The top-UA gate was being set by **the simulator itself**: `Ghosts Client` → `10.31.10.50:5000`
  was 31.36% of all plaintext HTTP. Verified 1:1 in both directions (533/533 each way) before
  excluding the control plane by destination. Top UA 30.71% → 18.58%.

**B. Step 7's objective was met**: connection failure rate **71.7% → 10.6% → 4.51%**. The dominant
cause turned out to be a generator bug, not a network fault — see §3.5.

---

# Part 3 — Lessons learned: the things this project got wrong

These are ordered by how much time they cost. Every one is a real error made during this build.

## 3.1 The meta-lesson: a measurement is a claim, and claims need controls

Eight diagnoses in this project were confidently stated and later disproven. The pattern was almost
always the same: **a query that could not have found the thing it claimed was absent**, or **a
comparison between two things that did not share a path**.

Wrong conclusions actually reached and later corrected:

| Claimed | Reality |
|---|---|
| "The SF shortfall is the Windows tier" | Windows was 7.5% of connections and could not move the estate figure. The cause was container `S0` at 34.8%. |
| "The resumption fix collapsed JA3" | Containers held perfectly flat. The collapse was browser throttling done for a *different* gate. |
| "auditd regressed" | The measurement window straddled the change. |
| "ws01's GHOSTS isn't browsing" | It was. |
| "355 junk profiles exist" | Only 16. The listing was truncated and I read the truncation as data. |
| "Guest/voice segments can't resolve DNS" | They could. |
| "`taskkill` was eliminated" | It was a restart transient. |
| "Swift is 70% of modular" | Confounded comparison. |
| "These reset connections never did work" | They had moved 471 KB over 11,448 packets. The byte fields were simply absent. |

**The discipline that would have prevented nearly all of them:** before concluding *X is
absent/broken*, run the query that would have found X if it were present, and confirm your control
shares the same network path, the same time window, and the same field names.

## 3.2 Time windows are part of the measurement

Five separate false conclusions came from windows that **straddled a change**. If you changed
something at 18:22, query `gte 18:25`. A 60-minute window that contains 25 minutes of "before" will
average away the very effect you are trying to see.

Equally: **short windows systematically understate cardinality.** "How many unique X" on a 6-minute
window is not a small version of the 60-minute answer — it is a *lower* answer, structurally.
Ratios are safe on short windows; counts and cardinalities are not.

## 3.3 THE BIG ONE: cardinality gates are diurnal, and will flip twice a day

This was discovered during this audit and is the most important finding for anyone reusing these
gates. The recorder's own history, sampled every 20 minutes as the working day ended:

| Time (UTC) | TLS sessions | unique JA3 | unique UA | top UA % | resumed % | SF % |
|---|---|---|---|---|---|---|
| 15:46 | 15,090 | 53 | 108 | 24.13 | 34.62 | 68.77 |
| 17:07 | 13,229 | 67 | 108 | 25.47 | 36.28 | 66.90 |
| 18:29 | 7,378 | 67 | **83** | **19.98** | **32.61** | 59.39 |
| 19:50 | 4,647 | 67 | 61 | 29.55 | 26.90 | 78.83 |
| 21:30 | 3,571 | 67 | 55 | 35.34 | 18.73 | 75.05 |
| 23:32 | 2,398 | **67** | **43** | **40.76** | **12.64** | 70.08 |

Traffic fell **6.3×** from peak to trough. Read what happened to each metric:

- **`unique_ja3` held EXACTLY FLAT at 67** across the entire collapse. This is a clean natural
  experiment confirming that **JA3 cardinality is a function of client *configuration*, not traffic
  volume** — which is precisely the model used to fix it. It is the one gate here that is
  time-independent.
- **`unique_ua` tracked volume almost linearly** (108 → 43). Fewer transactions, fewer distinct
  agents observed.
- **`top_ua_pct` moved *inversely*** (24% → 41%). As volume falls, steady infrastructure chatter
  becomes a larger share of a smaller pool.
- **`ssl_resumed_pct` fell** (34.6% → 12.6%), because resumption needs repeat visits within a
  session lifetime, and at night there are few.

**Consequence: "Step 4 passes 5/5" was true at 18:29Z and is false at 23:32Z, with no configuration
change whatsoever.** Any gate on cardinality or share **must** be qualified by time of day —
evaluate during the business-hours peak, or normalise per 1,000 sessions. A gate harness that does
not do this will report a regression every single night and a fix every single morning, and will
train whoever reads it to ignore it.

## 3.4 Your own tooling becomes the telemetry

Repeatedly, the largest signal in the data was *the range's own machinery*:

- the GHOSTS agent's API polling was **31% of all plaintext HTTP**
- `auditd` was **78% self-noise** (`proctitle` + raw `syscall`)
- each SSH command batch produced **6** auth events until batched into one (cut to 1, A/B proven
  against a control arm)
- the measurement harness itself appeared in the data it was measuring
- `journald.container` + `auditd.log` remain **50.8%** of all ingest today (F1)

**Budget for observer effect from day one.** Exclude control-plane traffic from *realism* gates by
destination — and verify the 1:1 mapping in both directions before excluding anything, or you will
silently drop real traffic.

## 3.5 Guard by resolved address, never by name shape

The single most instructive bug of the build. The generator suppressed internal-tier requests from
segments denied to that tier — but tested the **hostname suffix** (`.range.lan`). A code comment
asserted *"external fake-internet names do not resolve to web01"*. **The comment was false**:

```
update-manifest-svc.net  ->  10.30.30.10     # "external" name
intranet.range.lan       ->  10.30.30.10     # same host
```

So the guard caught the 16% internal branch and let the ~78% external branch straight through to the
same unreachable host. Result: **4,779 unanswered SYNs per hour**, presenting as a 34.8% connection
failure rate that looked like a network fault and was not.

Two lessons: **guard on the resolved address**, and **treat comments as claims to be verified**, not
as documentation.

## 3.6 Generators must respect the policy matrix

`noise` — the *corporate* generator (SMB, SMTP, FTP, LDAP to corporate servers) — was running on
`byod01/02`, personal devices in the GUEST segment that policy correctly denies to those servers.
Every call was both doomed and implausible. That is a **role mis-assignment**, not a firewall
problem, and the fix was to stop generating the traffic, not to open the policy.

Keep a **~3% trickle** of policy-denied attempts, though: real estates do contain devices attempting
blocked connections, and those denies are excellent hunting material. The flood was the artifact;
the existence of denies was not.

## 3.7 Do not fix one gate by breaking another

Browser activity drives **both** Sysmon volume (a volume gate) **and** TLS fingerprint diversity via
GREASE (a diversity gate). Throttling browsers to cut Sysmon volume silently collapsed JA3 from 79
to 6.

The resolution was to recognise that **handshake volume was never the JA3 lever** — client
configuration is. Widening the TLS profile pool fixed diversity *without* touching the throttling
that the volume work depended on. Both gates then held simultaneously.

Also note: the original JA3 of 79 was **GREASE inflation** from two hosts re-handshaking constantly.
Browser keep-alive (fewer handshakes) is the *more* realistic state. **A metric moving in the
"good" direction is not automatically realism.**

## 3.8 Know which metric actually encodes failure

The plan carried a sub-gate of `SF ≥ 85%`. Zeek's `RSTO`/`RSTR` mean **established, then aborted** —
the session did its work and skipped a clean FIN. Measured:

| Port | State | n | client → | server → | packets | duration |
|---|---|---|---|---|---|---|
| 5055 | RSTR | 257 | 17,255 B | 3,827 B | 38.5 | 137.68 s |
| 445 | RSTO | 60 | **471,141 B** | 463,073 B | **11,448** | 113.82 s |
| 389 | RSTO | 24 | 3,371 B | 43,001 B | 51.2 | 56.92 s |
| 88 | RSTR | 158 | 835 B | 1,213 B | 13.4 | — |

A 471 KB, 11,448-packet SMB transfer is not a "connection failure". Windows genuinely closes SMB,
Kerberos and LDAP with RST, and **Logstash's Elastic Agent input closes idle connections with RST
rather than FIN by design** (documented upstream behaviour, shared codebase with `input-beats`).

**The correct metric is `(S0 + REJ + RSTOS0 + SH + SHR) / total`** — connections that never
established. On that metric the range measures **4.51%**.

## 3.9 Infrastructure leaks into the range unless you actively scrub it

The Windows golden image carried the *builder's own environment* into the range: house DNS, a
remote-access agent, and Elastic/GHOSTS endpoints pointing at real infrastructure. Every clone
inherited it. Similarly, the container host silently depended on the house router for DNS and a
public NTP pool — dependencies that "worked" only because egress containment was dropping them, and
that would have vanished on migration.

**Audit every guest for dependencies on your real network before you trust the estate.**

---

# Part 4 — The measurement traps, in full

Each of these produced a wrong conclusion at least once.

| # | Trap | Symptom | Correct approach |
|---|---|---|---|
| 1 | Security Onion does not use stock ECS byte fields | `source.bytes` = 0 **even for `SF` connections** | Use `client.bytes`, `server.bytes`, `client.packets`, `server.packets`. Zero on a completed connection means the *field* is absent, not the traffic empty. |
| 2 | `event.duration` is in **seconds** | Every row prints `0.00s` after dividing by 1e9 | Do not convert. |
| 3 | `capture_loss` cannot detect a starved sensor | Reported **0.0%** while Zeek received **3 packets / 10 s** | Zeek computes loss against what it *received*. Count packets per VLAN with `tcpdump`. |
| 4 | Windows straddling a change | 5 false conclusions | Query `gte <exact change time>`. |
| 5 | Short windows understate cardinality | "JA3 is only 40" on a 6-min window vs 67 on 60 min | Use ≥ 20 min for any cardinality gate. |
| 6 | Diurnal variation in gates | Gates flip nightly with no config change | Qualify by time of day (§3.3). |
| 7 | Truncated output read as data | "355 junk profiles" — there were 16 | Check for truncation before counting. |
| 8 | A control that does not share the path | Concluded a service was down when policy was dropping it | A dead listener and a policy drop are identical from the client. Test from a **permitted** segment. |
| 9 | Elastic tokens are base64 | Parsing with `cut -d=` truncates them | Keep the `=` padding. |
| 10 | Windows service name has a space | `Get-Service ElasticAgent` returns nothing | It is `"Elastic Agent"`. |
| 11 | `host.name` is lowercase in ES | Term query on `WS01` returns zero | Use lowercase. |
| 12 | ES `curl.config` carries no CA | TLS verification failure | Use `curl -sSk`. |
| 13 | `incus exec` consumes stdin | Piped loop dies after one iteration | Append `</dev/null` to every call. |
| 14 | `sudo -S` with a heredoc | Password becomes line 1 of the file | Stage as the user, then `sudo cp`. |
| 15 | pvesh interprets backslash escapes | `C:\Windows\Temp\agent` → `Tempgent` (`\a` = BEL) | Use forward slashes. |
| 16 | pvesh `file-write` caps at 61,440 chars; `file-read` is a GET | Silent truncation | Chunk writes. |
| 17 | UTF-8 BOM | `json.loads` fails; pvesh rejects U+FEFF | Write BOM-less; strip `\ufeff`. |
| 18 | auditd exclusion ordering | Exclusions silently ineffective | `-D` first, exclusions after. |
| 19 | auditd `exe=` rules | Blind to containerised processes | Match on other fields. |
| 20 | OPNsense config path | Edits to `<unbound>` do nothing | Unbound lives at `<OPNsense><unboundplus>`. |
| 21 | Jumbo MTU in an interface stanza | Host-wide network outage | Set it `post-up`. |
| 22 | `tc mirred` to a bridge master | Sensor sees almost nothing | Mirror into a **veth**. |
| 23 | SPAN bridge learning enabled | Traffic stops flooding to the sensor | learning off, `ageing_time 0`. |
| 24 | Git Bash has no `python3` | Script silently does nothing | Parse on the remote host. |
| 25 | WSL runs as root | `~` is `/root` | Use absolute paths. |

---

# Part 5 — What is NOT done

Stated plainly so nobody inherits a false picture of completeness.

| # | Gap | Detail |
|---|---|---|
| N1 | **The estate is not data** | `estate/`, `render/`, `roles/`, `attack/` do not exist. The range was built by scripts and accumulated host state, so it **cannot be reproduced from this repository** — only continued. This is the exact failure the design spec warned about. |
| N2 | **Fake-internet tier is dead** | VLAN 99: 20 connections in 24 h; `pivot01`'s generator inactive (F4). |
| N3 | **Sysmon volume over target** | Every host 1.0–2.1× above the 5–10k/day band (F3). |
| N4 | **Workstations are Server 2022** | Prefetch artifacts are therefore unobtainable. Spec called for Windows 10 LTSC 2021. |
| N5 | **Office installed nowhere** | Removes a large, realistic document-activity source. |
| N6 | **No adversary emulation** | Deliberately deferred until the benign baseline is finished — the correct order. |
| N7 | **Coverage never measured against ATT&CK** | The README promises four coverage gates; none were built. |
| N8 | **Velociraptor workflow unproven** | The analysis station exists; the offline-collector → import → timeline loop has not been exercised end-to-end. |
| N9 | **Gate specification unresolved** | The `SF ≥ 85%` sub-gate is mis-specified (§3.8) and awaits an operator decision. |
| N10 | **Repo hygiene** | House addressing appears in committed docs, against the spec's own "no real fleet addressing" rule. |

---

# Part 6 — If you are building this next, do these five things differently

1. **Build `estate/*.yaml` first**, before a single container exists. Everything else follows from
   it, and it is what makes the build survive a hardware change. This is the biggest single
   regret of this build.
2. **Stand up the gate harness before the estate**, not after. Evidence that accumulates on a timer
   caught a regression here that manual checks missed — and **make every gate time-of-day aware**
   from the start (§3.3).
3. **Decide your telemetry budget per tier up front.** Half of this build's ingest is Linux
   infrastructure noise (F1). That is a choice you should make deliberately, not discover.
4. **Scrub the golden image, and audit every guest for dependencies on your real network** before
   you trust anything (§3.9).
5. **Write down what each gate actually means before you tune to it.** Two of this project's gates
   were measuring something other than what their names implied (§3.3, §3.8), and tuning to a
   misunderstood metric wastes more time than having no metric.
