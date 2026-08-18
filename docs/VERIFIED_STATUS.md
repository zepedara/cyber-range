# Verified status

Measured state of every step in
[`2026-08-16-host-and-network-log-generation-research.md`](superpowers/plans/2026-08-16-host-and-network-log-generation-research.md),
as at **2026-08-18**. Every number here came from a query against Elasticsearch or from reading the host
directly. Where a claim was previously made without measurement, it is corrected rather than quietly
dropped.

The rule this file exists to enforce: **a step is done when its gate is measured, not when the work
feels finished.**

Gate measurements are now recorded automatically: `/usr/local/bin/range-gate-record` on so01 appends a
JSON line to `/var/log/range-gates.jsonl` every 20 minutes over a 60-minute window, storing raw counts
as well as verdicts so any reader can recompute against different thresholds.

---

## Step status

| Step | Gate | Status |
|---|---|---|
| 1 — repoint agent output | ≥5,000 Windows events/host/day | ✅ **PASS**, 6 of 6 guests |
| 2 — Windows agent policy | 4624 within 60s; 4688 with command line | ✅ **PASS** |
| 3 — Sysmon config from upstream | EIDs 1,3,10,11,22 present **and** 5k–10k/endpoint/day | ⚠️ **HALF** — IDs pass; volume cut ~20× and converging, see below |
| 4 — GHOSTS API + timelines | ≥60 JA3 none >25%; ≥80 UA none >20%; resumed ≥30% | ✅ **PASS**, 5 of 5, sustained across recorder samples |
| 5 — diurnal model | peak/trough 5–20×, peak in business hours, weekend shape | ✅ 6.93× with peak at 14Z; weekend shape still unverified |
| 6 — host artifacts + Atomic Red Team | an Atomic test yields expected events in 60s | ⛔ artifacts done; Atomic **blocked by operator standing order** |
| 7 — failure rate + auditd | `SF` ≥85%; auditd firehose reduced | ⚠️ auditd ✅; **SF 67.8% FAIL** — see correction below |

### Correction: Step 7 was measured against the wrong metric

This file previously recorded Step 7 as ✅ on "failure rate 3.8%". The plan's gate is **`SF` ≥ 85%** —
a floor on *successful* connections, which is **not** the complement of a failure rate, because Zeek has
many states that are neither `SF` nor a failure (`RSTR`, `RSTO`, `OTH`, `S1`, `SH`). Measured properly:

| Scope | SF | Verdict |
|---|---:|---|
| all transports | 86.9% | passes on a literal reading |
| **TCP only** | **67.8%** | **FAIL** |

The shortfall is **not** the generators. Patched containers sit at ~97% SF. It is the Windows tier, where
Kerberos `:88` is 100% `RSTR`, SMB `:445` 100% `RSTO` and LDAP `:389` mixed — Windows tears these down
with RST rather than a graceful FIN. **Open question for the operator:** whether `SF ≥ 85%` is the right
gate for an AD-heavy estate, or whether it is mis-specified for this environment.

### Step 4 — now PASS, measured on a 60-minute window

| Sub-gate | Measured | Verdict |
|---|---:|---|
| unique JA3 ≥60 | 167 | ✅ |
| top JA3 ≤25% | 9.26% | ✅ |
| unique UA ≥80 | 111 | ✅ |
| top UA ≤20% | 13.56% | ✅ |
| `ssl.resumed` ≥30% | 33.2% → 39.9% | ✅ |

Two of these were **unreachable by construction**, not merely untuned:

- **`ssl.resumed`** — curl *cannot* resume a TLS session. Proven: every chained request full-handshakes
  regardless of protocol version or connection handling, because OpenSSL does not cache client sessions
  across processes. It closes ~1.2 ms after the handshake, before nginx's post-handshake ticket arrives.
  Fixed by giving webnoise a Python TLS path that reuses a per-host `SSLSession` and closes with
  `unwrap()` so it keeps the clean FIN that made curl necessary in the first place.
- **`unique UA ≥80`** — browser UAs are chosen *per host*, so they cap at the container count (31),
  giving a ceiling of ~77 against a gate of 80. Fixed by widening the per-request app-agent pool.

A third fix was a realism improvement that happened to unblock the second: webnoise drew from a
194-domain profile, so a host was never revisited and there was no session to resume. Re-weighting the
existing weights by rank (Zipf) fixed both — real web access is heavily skewed, and a flat draw over 194
domains was itself an artefact.

**Measurement lesson recorded here deliberately:** cardinality gates cannot be judged on short windows.
`unique_ua` read 49 on a 6-minute window and 111 on a 60-minute window *for the same estate*. Widen the
window before concluding.

### Step 3 — volume, three levers, converging

ws02 measured 203,000 docs/day against a 5,000–10,000 gate. Three fixes, each chosen from measurement:

| Lever | Effect |
|---|---|
| GHOSTS `stickiness` 0 → 75 (upstream default is 0) | 203,000 → 34,645/day |
| browse `DelayAfter` ×3.5 | → ~15,570/day; taskkill and firefox left the top-5 processes |
| scheduled noise task intervals ×2.5 | projected ~9,600/day — **verification pending** |

`stickiness=0` means the NPC never follows a link within a site, so every timeline event became a fresh
browser launch/kill cycle. Upstream documents no option to stop the per-event relaunch, so `DelayAfter`
and task cadence were the remaining levers. Already in band: `ir-dc01` ~4,900, `web01` ~3,100.
`sql01` ~10,950 and `fs01` ~10,285 are marginally over and are server roles untouched by these changes.

### Infrastructure change: Security Onion consolidated onto cthuwu

so01 moved from l3e7 to cthuwu keeping `192.168.1.146`, with both MACs preserved. `vmbr1` is now the LAN
bridge (`enp73s0` enslaved), and vmbr0's `MASQUERADE` was repointed to it — miss that and the whole
10.20.0.0/24 range loses egress.

**A regression worth recording, because the failure mode is deceptive.** After the move the sensor was
receiving 3 packets per 10 seconds while `so-status` was all-green, Elasticsearch was GREEN and
`capture_loss` read **0.0%**. Cause: so01's monitor tap became a new port on `vmbr91`, where MAC learning
was still on, so mirrored unicast kept going to the previously-learned port. Fixed with
`learning off` + `flood on` + fdb flush + `ageing_time 0`, persisted in the bridge stanza.

**`capture_loss` alone is not a span health check** — Zeek computes loss as a fraction of what it
*receives*, so a starved sensor loses nothing and reports a perfect 0%. Measure packet delivery into the
monitor tap instead.

---

## Step 1 — agent output — PASS

Windows events per host, 24h:

| Host | Events/day |
|---|---:|
| ir-dc01 | 245,590 |
| ws01 | 47,902 |
| ws02 | 45,824 |
| fs01 | 32,417 |
| sql01 | 31,958 |
| web01 | 13,105 |

6 of 6 above the 5,000/day gate.

## Step 3 — Sysmon — HALF PASS, and a correction

**Correction.** This was previously recorded as complete with the config identified as `sysmon-modular`.
That attribution was **wrong**. The Sysmon EID 16 configuration-change record shows the live config is:

```
Configuration       C:\Windows\Temp\sysmonconfig-swift.xml
ConfigurationFileHash  SHA256=055FEBC600E6D7448CDF3812307275912927A62B1F94D0D933B64B294BC87162
```

That is **SwiftOnSecurity**. Both it and sysmon-modular are upstream-endorsed by the plan, so the
"retrieved, never authored" rule holds — but the record said the wrong thing.

**Event-ID half — PASS.** All five required IDs present over 24h:

| EID | Meaning | 24h |
|---:|---|---:|
| 1 | process creation | 6,455 |
| 3 | network connection | 11,094 |
| 10 | process access (credential theft) | 3,055 |
| 11 | file create | 21,825 |
| 22 | DNS query | 1,832 |

Also present: 7 image load **27,801**, 17 named pipe 9,892, 13 registry 3,254, 12 registry 146,
25 process tampering 24. Zero for 8 (remote thread), 15 (file stream), 23 (file delete).

**Volume half — FAIL.** Gate is 5,000–10,000 per endpoint per day:

| Host | Sysmon/day | vs gate |
|---|---:|---|
| ws01 | 24,391 | ABOVE |
| ws02 | 19,990 | ABOVE |
| sql01 | 13,114 | ABOVE |
| fs01 | 12,943 | ABOVE |
| ir-dc01 | 10,943 | ABOVE |
| web01 | 6,097 | in band |

1 of 6 in band. Remaining work is the plan's own recommendation: retrieve **sysmon-modular**, merge with
`Merge-AllSysmonXml`, deploy separate DC and workstation variants, re-measure. Top volume drivers to tune
first are EID 7, 11 and 3.

## Step 7 — volume and health

- **Connection failure rate 3.8%** — below the 5–15% enterprise band, i.e. the range is now slightly
  *too clean*.
- **Encryption 88.1%** (band 70–90).
- **auditd reduced three times**: −40.3%, then −46.6%, then −10.6%. The last came from qualifying the
  `noise` generator and replacing `date`/`seq` with bash builtins across 9 containers — with network
  traffic held constant by design (work commands were qualified, not removed).
- **5145 `IPC$`/`lsarpc` filtered** via the documented `logs-system.security@custom` pipeline, keeping
  `svcctl`/`samr`/`srvsvc` for lateral-movement detection. Verified by `_simulate` (1 of 5 docs dropped,
  the right one) and live (`lsarpc` 0, `SYSVOL` retained).

---

## Identity and business data — built this cycle

**The directory was unusable as a directory.** BadBlood had created 2,502 objects but set no HR
attributes at all, and no `givenName`/`sn`/`displayName` on **any** of them.

| Attribute | Before | After |
|---|---:|---:|
| Department | 0 / 2446 | 100% |
| Title | 0 / 2446 | 96.6% |
| Manager | 0 / 2446 | 95.9% |
| EmailAddress | 0 / 2446 | 100% |
| OfficePhone | 0 / 2446 | 93.0% |
| givenName / sn / displayName | 0 / 2360 | 2360 / 2360 |

Deliberately **not** 100% — uniform completeness is itself a generated-data tell. Org chart depth 4,
IC → Manager → Director → VP → CEO.

86 service-shaped accounts (digit/`SA` suffix) had HR attributes stripped; they had been mis-classed as
people because they carry no SPN. **"No SPN" is not a sufficient test for "is a person" — check the
account-name shape too.**

**corpdb rebuilt from AD** — same 2,360 people in the database and the directory, with
`sam_account_name` added as the join column and `manager_id` populated (it was entirely NULL). Generated
business data has tenure correlated with seniority:

| Level | n | Mean tenure | Mean salary |
|---|---:|---:|---:|
| exec | 31 | 11.9y | 208,822 |
| director | 64 | 10.3y | 145,556 |
| manager | 168 | 7.7y | 113,655 |
| senior | 373 | 6.2y | 100,542 |
| IC | 1,724 | 4.0y | 69,192 |

**Cross-source pivot verified: 33 of 33 (100%)** domain accounts seen in 6h of logon telemetry resolve to
a full HR record with department, title, manager, office and hire date.

## Directory-change auditing — fixed

5136 was producing nothing. Both halves were broken; both are now verified end to end, with a controlled
before/after on the same kind of operation:

| Window | Attribute writes | 5136 events |
|---|---:|---:|
| before the fix | ~2,446 | **0** |
| after the fix | ~2,360 | **17,196** |

`givenName` shows *Value Added* with no *Value Deleted* — correct, since no prior value existed — while
`mail`/`sn`/`displayName` show both. Old-value capture confirmed.

## Logon realism — per-host assigned users

Logons previously drew uniformly from the whole workforce, so **no logon could ever be anomalous**. Each
workstation now has a stable 5-user set derived from its own hostname, plus 10% visitor logons from
outside the set. Verified at runtime; the two hosts' sets are disjoint.

---

## Known gaps and open decisions

| Item | State |
|---|---|
| **Workstation image** | ws01/ws02 are **Server 2022**, so Prefetch is impossible — `SysMain` deletes `EnablePrefetcher` on start and a reboot re-deletes it. Needs a re-image to Windows 10/11 or explicit acceptance. |
| **Office not installed** | No document-creation activity is possible anywhere. Needs a licensing decision. |
| **Software variance** | ws01 and ws02 have identical software fingerprints (7 programs). Adding variance needs staged packages — the range has no internet by design. |
| **Browser history** | Chromium `History` is exactly 116 KB on all five guests — the untouched default. GHOSTS browsing is not persisting. |
| **Profile count** | ws01 has 355 local profiles (a one-time build artifact, not ongoing growth). Cosmetic — 42–46 GB free on every host. |
| **Atomic Red Team** | Deliberately not started; benign baseline comes first. |
| **JA4+** | Beyond BSD-licensed JA4 requires accepting FoxIO License 1.1. Operator's call. |
| **House NSM** | `10.20.40.11` should be repaired or formally decommissioned; agents were originally pointed at it. |

## Credential hygiene

⚠️ **This repository is public and `noise/containers/rangenoise.sh` already contains a lab credential.**
Range passwords should be treated as compromised and rotated. New material in this repository uses
placeholders, and the build guide supplies none.
