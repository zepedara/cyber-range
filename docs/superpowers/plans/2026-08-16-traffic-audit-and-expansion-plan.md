# Traffic audit and expansion plan

**Date:** 2026-08-16
**Scope:** every telemetry source feeding so01 — network (Zeek/Suricata) and host (auditd, Falco, Elastic Defend, journald, syslog)
**Method:** aggregations against the full Elasticsearch corpus over a 24-hour window, not `/nsm/zeek/logs/current` (which rotates hourly and understates everything)

---

## 0. How to reproduce this audit

Two traps cost time here and will cost it again:

- **Elasticsearch is HTTPS on 9200 and the curl config carries no CA reference.** `curl -sK ... https://localhost:9200` fails with `unable to get local issuer certificate`, and under plain `-s` returns an *empty body* that reads as "no data". Use `-sSk -K /opt/so/conf/elasticsearch/curl.config`.
- **Security Onion does not use stock ECS field names.** Querying `dns.question.name`, `tls.client.ja3` or `user_agent.original` returns cardinality `0` — not because the range is empty, but because the fields do not exist. The real names are:

| Concept | Security Onion field |
|---|---|
| DNS query | `dns.query.name`, `dns.highest_registered_domain` |
| DNS rcode | `dns.response.code_name` |
| DNS qtype | `dns.query.type_name` |
| TLS fingerprints | `hash.ja3`, `hash.ja3s`, `hash.ja4` |
| TLS SNI / version | `ssl.server_name`, `ssl.version`, `ssl.resumed` |
| HTTP UA / vhost | `http.useragent`, `http.virtual_host`, `http.status_code` |
| Conn state / bytes | `connection.state`, `network.bytes` |

Scripts live in `noise/` and the audit scripts in the session scratchpad; both should be promoted into `tools/audit/` (see Phase 0).

---

## 1. Inventory — what exists today

24-hour document counts:

| Dataset | Docs | Note |
|---|---:|---|
| `auditd.log` | 3,035,793 | one Linux host |
| `zeek.*` (31 types) | 678,975 | the whole network picture |
| `endpoint.events.file` | 312,701 | Elastic Defend, one host |
| `system.syslog` | 205,104 | |
| `journald.container` | 165,403 | 32 containers |
| `suricata.alerts` | 146,270 | |
| `syslog.syslog` | 68,919 | |
| `system.auth` | 22,984 | |
| `endpoint.events.process` | 16,509 | |
| `endpoint.events.network` | 12,191 | |
| `falco.alerts_agent` | 2,628 | |
| `strelka.file` | **2** | effectively dead |

**Hosts producing host-level logs: three.** `cthost01` (3,598,451), `so01` (390,849), `fleetserver-so01` (1,529).

---

## 2. The headline finding: the enterprise has no endpoints

A real enterprise SOC runs on endpoint telemetry at least as much as on the wire. Ours is a network range with a Linux container host bolted on.

- **There is no Windows event log pipeline at all.** No `winlog`, no Sysmon, no Security channel. The six Windows guests contribute ~584 documents combined against cthost01's 3.6 million — a ratio of roughly **6,000:1**.
- **Elastic Defend is enrolled on exactly one host** (`cthost01`). The Windows estate has no EDR.
- `strelka.file` has 2 documents, so file extraction and detonation are not meaningfully running.
- **`auditd` is 78% self-inflicted noise**: `proctitle` (1,178,872) and `syscall` (1,178,872) alone are 2.36M of 3.03M. Meanwhile `execve` — the field an analyst actually hunts on — is 96,307.

This single gap invalidates most of the detection surface in spec §7.4. Kerberoasting, AS-REP roasting, DCSync, credential dumping, and process-lineage hunts are all authored against Windows Security and Sysmon events that the range does not produce.

---

## 3. Network fidelity — measured against enterprise baselines

Encryption baselines below are from published measurement studies: ~88–95% of web traffic is encrypted globally, and **65% of internal east-west enterprise traffic is encrypted** ([Gigamon, 1.3T flows](https://www.gigamon.com/company/news-and-events/newsroom/ssl-tls-research-2022.html); [AppLogic Networks](https://www.applogicnetworks.com/blog/encryption-trends-in-networks-whats-changing-and-what-is-not); [state of TLS Q1 2026](https://sslreminder.pro/blog/posts/state-of-tls-q1-2026/)).

| Metric | Measured | Enterprise reality | Verdict |
|---|---:|---|---|
| Connection success (`SF`) | **28.3%** | 85–95% | **critical** |
| Connections never answered (`S0`) | **58.2%** (94,095) | <5% | **critical** |
| DNS share of all network events | **65.0%** | 10–20% | **critical** |
| TLS share of all network events | **2.7%** | 40–60% | **critical** |
| Unique JA3 client fingerprints | **12** (top 2 = 93.3%) | hundreds, long tail | **critical** |
| Unique HTTP user agents | **14** (`curl/8.14.1` = 87%) | hundreds | **critical** |
| TLS session resumption | **0.04%** | 30–60% | **critical** |
| TLS 1.3 share | **99.8%** | ~70%, with a 1.2 tail | high |
| NXDOMAIN ratio | **34.4%** | 5–15% | high |
| Unique registered domains | **86** | thousands | high |
| HTTP methods | GET **99.3%**, POST 0.7% | GET ~70%, POST ~20%, plus HEAD/PUT/OPTIONS | high |
| HTTP status codes | 200 **97.7%** | 200 ~75%, with 302/304/404/401/500 tail | high |
| Bytes/conn p50 / p99 | 217 / 39,045 | fatter tail — backups, file transfer, video | medium |
| Conn duration p90 / p99 | 3s / 58s | long-lived sessions routine | medium |

### What these numbers mean

**The 70% failure rate is the worst problem.** 94,095 connections in 24 hours were sent and never answered. Task #24 recorded this as fixed at 69.5%; it is 71.7% today, so either it regressed or it was never actually fixed. A range where most connections fail teaches analysts that failure is normal — the exact opposite of the instinct you want, because scanning and C2 beaconing are *detected* by anomalous failure rates.

**`curl/8.14.1` at 87% of HTTP is the single most obvious synthetic tell.** Any analyst who pivots on user agent sees immediately that this is generated traffic. Same for 12 JA3 fingerprints where two account for 93%.

**Zero TLS session resumption is a strong tell.** Real clients resume constantly; `ssl.resumed` false on 18,663 of 18,671 sessions says every connection is a fresh scripted handshake.

**The domain mix is polluted by infrastructure.** `securityonion.local` is 23.0% of all DNS and `google.com` + `msftncsi.com` another 20.1% — the SIEM talking to itself and connectivity probes. Only about a third of DNS is actually the fictional enterprise (`range.lan` 29.7%, `lab.local` 14.1%).

**Port distribution shows contamination**: ports 21116 (16,561) and 21114 (8,387) are RustDesk, and 5355/5353 are LLMNR/mDNS — 25k+ connections that belong to neither fictional company.

### Diurnal shape

```
08:00  3,984  ########
09:00  6,220  #############
...
15:00  9,560  #####################
16:00  1,683  ###
18:00    574  #
19:00-00:00      0        <- maintenance window (SPAN move), not a fidelity finding
02:00 13,422  ##############################
07:00 17,876  ######################################## <- busiest hour is 07:00
```

Discounting the maintenance gap, **the curve is inverted**: the range is busiest overnight (01:00–08:00, 13k–17k/hr) and quietest during business hours. There is no working-day shape, no lunch dip, no weekend/weekday difference.

---

## 4. Root causes

1. **Noise generators target hosts and ports that policy denies or that do not listen.** This is the direct cause of 58% `S0`. Nothing validates that a generated flow *can* succeed.
2. **One client stack generates nearly all application traffic.** `curl` from containers produces one JA3 and one UA. Fidelity is bounded by client diversity, and we have almost none.
3. **No endpoint agents on Windows.** Never deployed; the estate was powered off until 2026-08-16.
4. **No time model.** Generators loop on `sleep $RANDOM` with no concept of business hours, so the diurnal curve reflects when *I* was working.
5. **Infrastructure traffic is not excluded or is not separated.** SIEM self-talk dominates DNS.
6. **`auditd` rules are unfiltered**, so `syscall`/`proctitle` bury the signal and inflate storage.

---

## 5. The plan

Phased, each phase gated by a measurement. **No phase is "done" until its gate passes** — that is what went wrong with the KSM and connection-failure tasks, both of which were marked complete without a measurement.

### Phase 0 — Make the audit repeatable (prerequisite)

Promote the audit scripts into `tools/audit/` with a single entry point that prints the table in §3 with pass/fail against thresholds. Without this, every later phase is unverifiable.

- `tools/audit/traffic_audit.sh` — the ES aggregations, correct field names baked in
- `tools/audit/gates.yaml` — thresholds
- Run it hourly; alert on regression

**Gate:** the script reproduces §3 unattended.

### Phase 1 — Fix the failure rate (highest value, lowest effort)

The generators must only attempt flows that the policy matrix permits and that have a listener.

1. Derive a reachability matrix once at startup: for each (source segment, destination, port), probe and cache whether it connects.
2. Generators draw only from permitted, listening tuples.
3. Keep a *deliberate* small failure population — 3–7% — because a range with zero failures is equally unrealistic. Make it intentional and labelled, not accidental.
4. Remove RustDesk/LLMNR/mDNS contamination from the SPAN, or scope it out.

**Gate:** `SF` ≥ 85%, `S0` ≤ 7%.

### Phase 2 — Windows host telemetry (largest realism gain)

This is what turns a network range into an enterprise.

1. **Sysmon on all six Windows guests.** Retrieve the config from upstream — [SwiftOnSecurity/sysmon-config](https://github.com/SwiftOnSecurity/sysmon-config) or [Olaf Hartong's sysmon-modular](https://github.com/olafhartong/sysmon-modular) — per the standing rule that detection content is retrieved, never authored by me.
2. **Elastic Agent + Defend on all six**, enrolled into a Windows policy with the `windows` and `system` integrations.
3. **Enable the Security channel events that matter**: 4624/4625 (logon), 4688 (process creation with command line), 4768/4769/4771 (Kerberos), 4776, 5140/5145 (share access), 7045 (service install), plus PowerShell 4103/4104.
4. Advanced audit policy + command-line auditing must be turned on via GPO, or 4688 carries no command line and is nearly useless.

**Gate:** all six hosts present in `host.name` aggregation; `winlog.*` datasets non-zero; a test logon produces 4624 within 60s.

**Note:** this needs the RAM freed on 2026-08-16 (52 GB headroom now) and pairs naturally with task #31 (virtio guest tools).

### Phase 3 — Client diversity

Break the `curl` monoculture.

1. Deploy real browser stacks in the user segments — headless Chromium and Firefox produce genuine, *different* JA3/JA4 and realistic UAs, plus session resumption for free.
2. GHOSTS is already installed on WS01; drive it properly rather than leaving it idle.
3. Add non-browser clients that exist in real enterprises: Office telemetry, Windows Update, `apt`/`yum`, Java clients, a mail client, a backup agent.
4. Vary TLS stacks so `ssl.version` develops a 1.2 tail (~25–30%) and ciphers/curves diversify.

**Gate:** ≥ 60 unique JA3; no single JA3 > 25%; ≥ 80 unique user agents; no single UA > 20%; `ssl.resumed` ≥ 30%.

### Phase 4 — Traffic shape and time model

1. A shared business-hours model: ramp 07:00, peak 09:00–11:00 and 13:00–16:00, lunch dip, decay after 17:00, low overnight floor, reduced weekends.
2. Per-role weighting — workstations follow the curve hard, servers and backup jobs invert it (nightly windows), monitoring stays flat.
3. Fatten the byte distribution: scheduled backups, file-server copies, a software-update mirror, a video/streaming analogue.
4. Long-lived sessions (RDP, SSH, database pools) so `conn_long` reflects real behaviour rather than a synthetic case.

**Gate:** peak/trough ratio 5–20x with peak inside business hours; bytes p99.9 ≥ 5 MB; ≥ 50 concurrent connections lasting > 1 hour.

### Phase 5 — DNS realism

1. Expand the fictional domain corpus from 86 to 2,000+ registered domains with a realistic Zipf popularity distribution.
2. Drive NXDOMAIN down to 5–15% by making generated names resolvable, keeping a deliberate typo/DGA-ish slice for hunting.
3. Exclude or separate `securityonion.local` self-talk from the analyst-visible corpus.
4. Add the query-type mix real networks show: more PTR, SRV, TXT, CNAME chains; drop the NIMLOC artifact (6.6%) which is an LLMNR/mDNS side effect.

**Gate:** ≥ 1,500 registered domains; NXDOMAIN ≤ 15%; no single domain > 10%; DNS ≤ 25% of network events.

### Phase 6 — Encryption ratio and the remaining log types

1. Raise TLS to 40–60% of application flows (baseline: 65% of east-west enterprise traffic is encrypted).
2. Close out task #33: `sip`, `radius`, `quic` need services stood up; `intel` needs indicators retrieved from upstream (abuse.ch is already a configured Suricata ruleset source); `mysql` is blocked upstream by [zeek#2716](https://github.com/zeek/zeek/issues/2716) and should be documented as a known gap rather than chased.
3. Reconsider JA4+ — the pipelines already exist and `hash.ja4` is populated. Anything beyond BSD-licensed JA4 requires accepting FoxIO License 1.1, which remains **your** decision.

**Gate:** encrypted share 40–60%; ≥ 32 of 35 Zeek log types sustained across a Zeek restart.

### Phase 7 — Tune auditd, and make Strelka real

1. Drop `proctitle`/`syscall` firehose rules or filter them; keep `execve`, service lifecycle, credential and audit-config changes. Target ~80% volume reduction with no loss of hunt value.
2. Get file extraction actually flowing into Strelka (currently 2 documents).

**Gate:** `auditd.log` ≤ 600k/24h with `execve` volume unchanged; `strelka.file` > 1,000/24h.

---

## 6. Priority

If only three things get done:

1. **Phase 1** — the 70% failure rate is actively teaching the wrong lesson, and it is cheap to fix.
2. **Phase 2** — no Windows host telemetry means most of the intended detection surface cannot exist.
3. **Phase 3** — 12 JA3s and `curl` at 87% make the range transparently synthetic to anyone who pivots.

Phases 4–7 raise it from "credible" to "hard to distinguish".

---

## 7. Honest limitations

- The 19:00–00:00 dead zone is my own maintenance window (moving the SPAN to the crosslink), not a property of the range.
- The 24-hour window includes the period when the Windows estate was unreachable, so Windows-sourced network traffic is under-represented relative to steady state.
- `mysql` cannot be fixed at our layer.
- Enterprise baselines are drawn from public measurement studies of internet and east-west traffic; a specific organisation's mix varies with industry and remote-work posture.
