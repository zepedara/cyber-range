# Verified status

Measured state of every step in
[`2026-08-16-host-and-network-log-generation-research.md`](superpowers/plans/2026-08-16-host-and-network-log-generation-research.md),
as at **2026-08-17**. Every number here came from a query against Elasticsearch or from reading the host
directly. Where a claim was previously made without measurement, it is corrected rather than quietly
dropped.

The rule this file exists to enforce: **a step is done when its gate is measured, not when the work
feels finished.**

---

## Step status

| Step | Gate | Status |
|---|---|---|
| 1 — repoint agent output | ≥5,000 Windows events/host/day | ✅ **PASS**, 6 of 6 guests |
| 2 — Windows agent policy | 4624 within 60s; 4688 with command line | ✅ **PASS** |
| 3 — Sysmon config from upstream | EIDs 1,3,10,11,22 present **and** 5k–10k/endpoint/day | ⚠️ **HALF** — IDs pass, volume 2–5× over |
| 4 — GHOSTS API + timelines | ≥60 JA3 none >25%; ≥80 UA none >20%; resumed ≥30% | 🔶 API live, 2 clients active; diversity below target |
| 5 — diurnal model | peak/trough 5–20×, peak in business hours, weekend shape | ✅ curve applied estate-wide; weekend shape unverified |
| 6 — host artifacts + Atomic Red Team | an Atomic test yields expected events in 60s | ⛔ **not started** — deliberately behind benign-baseline order |
| 7 — failure rate + auditd | `SF` ≥85%; auditd firehose reduced | ✅ failure rate 3.8%; auditd cut three times |

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
