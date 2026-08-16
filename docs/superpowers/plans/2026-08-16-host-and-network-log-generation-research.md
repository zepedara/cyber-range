# Generating real host and network logs: research and implementation

**Date:** 2026-08-16
**Companion to:** `2026-08-16-traffic-audit-and-expansion-plan.md`

This document exists because the earlier audit reached a wrong conclusion. It is corrected here, and the corrected picture changes the plan substantially — mostly in our favour.

---

## 0. Correction to the audit

The audit concluded "the range has no endpoints — there is no Windows host telemetry." **That was wrong.** Direct inspection of the guests shows they are thoroughly instrumented:

| | WS01 | DC01 |
|---|---|---|
| Sysmon64 service | Running, **53,810** events | Running, **32,860** events |
| elastic-agent / elastic-endpoint | Running | Running |
| osquery | Running | Running |
| Audit: Process Creation | Success and Failure | Success and Failure |
| `ProcessCreationIncludeCmdLine_Enabled` | **1** | **1** |
| Security log records | — | **159,232** |
| GHOSTS | `C:\ghosts\x64\ghosts.exe`, task Running | n/a |

The audit was right that *Elasticsearch* holds almost no Windows data. It was wrong about why. **This is a shipping and policy failure, not an instrumentation gap** — which is a far cheaper problem, and it means Phase 2 is mostly configuration rather than deployment.

### Root cause 1 — agents ship to the wrong Security Onion

From `elastic-agent-20260816.ndjson` on WS01:

```
Failed to connect to failover(
    backoff(async(tcp://10.20.40.11:5055)),
    backoff(async(tcp://securityonion:5055))
): lookup securityonion: no such host
   dial tcp 10.20.40.11:5055: connectex
```

`10.20.40.11` is the **house NSM** (VM 170, Security Onion 2.4) — a different system from the range's so01. Measured:

- `10.20.40.11:5055` — **unreachable**
- `so01` (192.168.1.146) — **listening on 5044, 5055 and 8220**
- From WS01: `192.168.1.146:8220` reachable **True**, `:443` **True**

So the agents get their policy from so01 but send their data to a dead host, with a failover to a hostname that does not resolve. Every Sysmon and Security event generated since enrolment has been dropped on the floor.

### Root cause 2 — the Windows guests are in a Linux policy

`elastic-agent inspect` on WS01 shows policy `endpoints-initial` containing:

```
logfile-system.auth      logfile-system.syslog
journald-system.auth     journald-system.syslog
endpoint-so-manager_logstash
```

`journald` and `logfile-system` are Linux inputs. **There is no `winlog` integration**, so even with shipping fixed, the Security, Sysmon, PowerShell and Defender channels would not be collected. The agent also reports `DEGRADED`.

### What this means

The two most expensive-sounding items in the audit plan — deploying Sysmon fleet-wide and enabling command-line auditing — are **already done**. The work is:

1. Repoint the Elastic Agent output at so01.
2. Create a Windows agent policy with the `windows` and `system` integrations and move the six guests into it.

That is hours, not days, and it unlocks the entire §7.4 detection surface.

---

## 1. Host log generation — what the research says

### 1.1 Sysmon configuration

Two upstream configurations dominate, and per our standing rule detection content is **retrieved, never authored by me**:

- **[SwiftOnSecurity/sysmon-config](https://github.com/SwiftOnSecurity/sysmon-config)** — the most widely deployed enterprise baseline. Enables 15+ event types with hundreds of known-good exclusion filters, maintained against current threat intelligence and calibrated to balance coverage against volume. Recommended practice is to deploy as-is, run 30 days, then tune.
- **[olafhartong/sysmon-modular](https://github.com/olafhartong/sysmon-modular)** — rules split per ATT&CK technique in numbered folders (`1_process_creation`, `3_network_connection_initiated`, `11_file_create`), merged with `Merge-AllSysmonXml`. More assembly work, but far cleaner to map detection coverage and to maintain.

Variants matter: `sysmonconfig.xml` is the balanced default; `sysmonconfig-excludes-only.xml` and `sysmonconfig-research.xml` are explicitly marked **do not use in production** (extreme verbosity). Upstream also recommends separate configs for domain controllers, servers and workstations.

The highest-value event IDs are **1** (process creation), **3** (network connection), **10** (process access — credential theft), **11** (file create), **22** (DNS query).

**For us:** Sysmon is already running. We should determine which config is loaded and, if it is the stock default, replace it with sysmon-modular so our detections map to ATT&CK — which is what the curriculum needs.

### 1.2 Windows audit policy

Command-line logging in 4688 requires **Audit Process Creation** plus *Include command line in process creation events* — [without it 4688 is nearly useless for detection](https://lantern.splunk.com/Security_Use_Cases/Threat_Hunting/Enabling_Windows_event_log_process_command_line_logging_via_group_policy_object). **Both are already enabled on our guests.**

The channels a SOC needs: 4624/4625 (logon), 4688 (process + command line), 4768/4769/4771 (Kerberos — required for the Kerberoasting and AS-REP scenarios), 4776, 5140/5145 (share access), 7045 (service install), and PowerShell 4103/4104.

### 1.3 Volume baselines — these become our gates

Published sizing guidance:

| Source | Expected |
|---|---|
| Workstation, reasonable audit policy | 10–50 EPS |
| Domain controller | 300–500 EPS |
| Sysmon + key Security events | **5,000–10,000 events per endpoint per day** |
| Adding verbose tiers | 20,000–50,000 per endpoint per day |

For six guests at the conservative end that is **30,000–60,000 Windows events/day**. Today Elasticsearch receives roughly 584. That is the size of the gap, and it gives us a concrete gate.

### 1.4 Making host logs *interesting*, not just present

Volume alone is not a SOC exercise. Two upstream frameworks generate detection-worthy host telemetry safely:

- **[Atomic Red Team](https://redcanary.com/blog/testing-and-validation/atomic-red-team/qa-automating-atomic-red-team/)** — small, repeatable, per-ATT&CK-technique tests. Ideal for *validating that logging, telemetry and SIEM pipelines actually work*, which is exactly our failure mode.
- **[MITRE CALDERA](https://fourcore.io/blogs/top-10-open-source-adversary-emulation-tools)** — full campaign emulation with C2, natively mapped to ATT&CK. Our reference project **tiger-team-defense already runs CALDERA**.

A common stack is Atomic Red Team for continuous detection testing plus CALDERA for campaign emulation. Constraint stands: **no live malware on range hosts** — both of these emulate behaviour rather than detonating samples.

---

## 2. Network traffic generation — what the research says

### 2.1 GHOSTS is the right tool, and we already have it (unconfigured)

[GHOSTS](https://github.com/cmu-sei/GHOSTS) (CMU SEI) is a user-simulation framework built for exactly this. It drives **Firefox and Chrome, Word/Excel/PowerPoint/Outlook, SSH, SFTP, RDP, WMI, command line** and more — 27+ handlers on the Windows client, 38+ on the universal client.

**This directly solves our worst fidelity metrics.** Driving real browsers produces genuine, *diverse* JA3/JA4 fingerprints, realistic user agents, and TLS session resumption as a side effect — the three things our audit flagged as critical (12 JA3s, 14 user agents, `curl` at 87%, resumption at 0.04%).

**Correction to an earlier note:** I previously recorded that the GHOSTS client runs standalone without the API server. That is wrong — [the documentation](https://cmu-sei.github.io/GHOSTS/) states clients connect to the API by REST and SignalR for command and control, with no offline mode. Verified on our fleet: `C:\ghosts\x64\ghosts.exe` exists and the `GHOSTS` scheduled task is Running on WS01, but **no GHOSTS API is listening on port 5000 anywhere** (checked WS01, DC01, 10.30.5.10, cthost01, cthuwu). So the client has nothing to take orders from and has been generating nothing.

Deployment is a docker-compose stack (API, UI, Postgres, Grafana) — the same arrangement tiger-team-defense uses. cthost01 is the natural home.

Concepts we will use:
- **Timeline** — a preconfigured script defining tasks, operations and durations.
- **Machine Group** — timelines assigned to a group apply to all its machines, so we author per-role timelines (finance, IT, exec, developer) once.
- **NPCs / Animator** — simulated users with personalities and jobs, for behaviour that varies rather than repeats.

### 2.2 Temporal realism — our inverted diurnal curve

[TempoNet](https://arxiv.org/html/2601.15663) addresses precisely our Phase 4 problem, and its framing is worth quoting: temporal dynamics are "often considered out of scope by state-of-the-art network packet trace generation approaches," with the consequence that "blue teams and IDS tools trained in these environments can more easily distinguish simulated from real events."

Its findings that translate into requirements:

1. **Daily cycles** — mid-day peaks and overnight lulls. Ours is inverted (busiest 01:00–08:00).
2. **Weekly patterns** — distinct weekday/weekend variation. We have none.
3. **Host-pair burstiness** — traffic should concentrate among frequently-communicating pairs, not spread uniformly. Generation should be *conditioned on the host pair*.
4. Evaluate with **EMD on inter-arrival times and flow durations**, Q-Q plots, and host-pair fidelity — not just "does the log exist".

The broader [survey on synthetic traffic generation](https://arxiv.org/html/2507.01976v2) taxonomises approaches as statistical (Poisson, Markov, hierarchical state machines), deep-learning (VAE/GAN/diffusion/transformer), and simulation-based, and names **quality evaluation as an open challenge with no standardised metrics**. Its most relevant warning for us: contextual attributes — user behaviour, application types — remain "largely unexplored", which is precisely the gap an agent-based generator like GHOSTS fills.

**Our approach should be agent-based (GHOSTS) with a statistical time model layered on top**, not ML generation. Agent-based traffic is real traffic — real TLS handshakes, real protocol state — so it is realistic by construction at the packet level, and we only need to shape *when* it happens.

### 2.3 What our own reference projects already solved

**[lab-env](https://github.com/zepedara/lab-env)** already implements what our Phase 4 asks for: "a diurnal curve (overnight floor, morning ramp, lunch dip, evening decline)" adjusted for weekday/weekend in local time. It also uses **measured rather than asserted** hunt validation — malicious share held between 2–35% of victim connections, a noise floor of >100 connections from other hosts, and estate-wide alerting across >1 host. That measured-gate philosophy is the thing to port wholesale, and it is the same discipline this project keeps failing at (two tasks marked complete without measurement).

lab-env also rewrites real malware PCAPs with `tcprewrite` to map victim IPs/MACs onto real containers and place C2 inside the victim's own subnet, so simple subnet filtering cannot isolate the exercise.

**[tiger-team-defense](https://github.com/Icarus4122/tiger-team-defense)** already runs the full GHOSTS stack (API, UI, database, Grafana) plus CALDERA and Mythic C2, and generates **host artifacts** — `.bash_history`, `.viminfo`, `.mysql_history`, realistic misconfigurations, randomised believable user accounts. Host artifacts are cheap and disproportionately improve forensic realism; we have none.

---

## 3. Implementation

Ordered by value per unit of effort. Every item has a measured gate, because the recurring failure in this project has been declaring completion without one.

### Step 1 — Repoint agent output at so01 *(hours; unlocks everything)*

The single highest-value action in this document.

1. Correct the Elastic Agent output host from `10.20.40.11:5055` / `securityonion:5055` to `192.168.1.146:5055`.
2. Confirm so01's Logstash accepts the connection (it is already listening).
3. Restart agents; confirm `DEGRADED` clears.

**Gate:** `logs-*` shows documents with `host.name` in {DC01, FS01, SQL01, WS01, WS02}; Windows events ≥ 5,000/host/day.

### Step 2 — A real Windows agent policy *(hours)*

Create a Windows policy with the `windows` and `system` integrations and move the six guests into it. Collect Security, Sysmon/Operational, PowerShell/Operational, System, Application and Defender channels.

**Gate:** `winlog.*` datasets non-zero; a deliberate logon produces 4624 in Kibana within 60s; a deliberate `whoami` produces 4688 **with command line** and Sysmon Event ID 1.

### Step 3 — Sysmon config from upstream *(hours)*

Determine which config is loaded. If stock, replace with `sysmon-modular` (merged) or SwiftOnSecurity, with a DC variant and a workstation variant. Retrieved from upstream, never authored here.

**Gate:** Sysmon event IDs 1, 3, 10, 11, 22 all present in ES; volume within 5,000–10,000/endpoint/day.

### Step 4 — Stand up the GHOSTS API and author timelines *(days; the fidelity payoff)*

1. Deploy the GHOSTS docker-compose stack on cthost01.
2. Point the existing WS01 client at it; install clients on WS02 and the Linux user containers (universal/lite client supports Linux).
3. Author per-role timelines and machine groups: finance, IT, exec, developer, service account.
4. Drive **real Firefox and Chrome**, Office, Outlook, SSH, RDP.

**Gate (from the audit):** ≥ 60 unique JA3, no single JA3 > 25%; ≥ 80 user agents, none > 20%; `ssl.resumed` ≥ 30%.

### Step 5 — Port lab-env's diurnal model *(days)*

Take the overnight-floor / morning-ramp / lunch-dip / evening-decline curve with weekday/weekend variation, and apply it as a shared scheduler to both GHOSTS timelines and the container `rangenoise.service`. Per TempoNet, condition on **host pair** so traffic concentrates realistically, and invert the curve for servers and backup jobs.

**Gate:** peak/trough 5–20x with the peak inside business hours; distinct weekend shape; EMD between our hourly distribution and a reference enterprise profile below threshold.

### Step 6 — Host artifacts and adversary emulation *(days)*

1. Port tiger-team-defense's artifact generation: shell histories, recent-file lists, browser profiles, believable local accounts.
2. Deploy **Atomic Red Team** on the Windows guests for continuous, safe, per-technique detection tests — its primary value here is proving the telemetry pipeline works end to end.
3. Consider CALDERA for campaign emulation once Steps 1–4 hold.

**Gate:** an Atomic test for a chosen ATT&CK technique produces the expected Sysmon/Security events in Kibana within 60s, with no live malware anywhere on the range.

### Step 7 — Fix the failure rate and tune volume

Unchanged from the audit plan: reachability matrix so generators only attempt flows that can succeed (Phase 1, `SF` ≥ 85%), and auditd tuning (Phase 7, drop the `proctitle`/`syscall` firehose that is 78% of 3M docs).

---

## 4. Sequencing

Steps 1 and 2 come first and are cheap; until agent data lands in so01, nothing else about host logging is verifiable. Step 4 is the largest fidelity win but depends on standing up infrastructure. Steps 5–6 are refinement.

Notably, **Steps 1–3 need no new software** — the agents, Sysmon, audit policy and GHOSTS binary are already on the guests. The range was built more completely than the audit gave it credit for; it is misconfigured, not unbuilt.

## 5. Open decisions for the operator

- **JA4+** beyond BSD-licensed JA4 requires accepting FoxIO License 1.1. `hash.ja4` is already populated, so this remains a one-line change and remains your call.
- **CALDERA / Mythic C2** — tiger-team-defense runs both. Adding C2 emulation to this range is a scope decision, not a technical one.
- Whether the **house NSM** (10.20.40.11) should be repaired or formally decommissioned, since agents are still configured to reach it.
