# Range Traffic vs Real Enterprise Baselines and SOC Lab Environments

**Date:** 2026-08-16
**Question asked:** *"have you looked at all traffic the range is producing and measured network
and host logs against real enterprise traffic, and soc analyst lab environments?"*

**Honest starting answer:** not properly. Prior work spot-checked ~8 metrics against researched
targets. There had been no full census, no host-log baseline, and no comparison against published
SOC lab environments. This document is that work.

---

## 1. Baselines used

Primary source for network traffic is the LBNL enterprise trace study (*A First Look at Modern
Enterprise Traffic*, IMC 2005) — still the canonical packet-level measurement of a real enterprise
interior. Host-log baselines come from SIEM sizing practice.

| Metric | Real enterprise | Unit |
|---|---|---|
| Name services (DNS + NetBIOS) | **45–65%** | of connections (only ~1% of bytes) |
| UDP share | **68–87%** | of connections |
| TCP share | **66–95%** | of bytes |
| Internal ↔ internal flows | **71–79%** | of flows |
| Internal → external | 2–3% | of flows |
| External → internal | 6–11% | of flows |
| HTTP success (internal) | 72–92% | of connections |
| DNS success | 77–86% | of connections |
| NetBIOS / name-service failure | **36–50%** | of connections |
| Scanning traffic | 4–18% | of connections |
| Windows events / endpoint / day | 5,000–10,000 curated; 20k–50k verbose | docs |
| EPS: DC vs workstation | 300–500 vs **1–5** | events/sec |

**The unit matters more than the number.** Conflating byte-share with connection-share is exactly
what produced an earlier wrong verdict (see §4).

## 2. Measured census (30-minute window)

| Metric | Range | Baseline | Verdict |
|---|---:|---|---|
| UDP share of connections | 49.3% | 68–87% | **below** |
| TCP share of bytes | 95.4% | 66–95% | at top edge |
| Name services (conns) | 38.8% | 45–65% | **below** |
| Internal ↔ internal | 70.5% | 71–79% | essentially in range |
| Distinct log datasets | **49** | contract was 35 | **exceeds** |
| Windows docs/endpoint/day | 153k–1.22M | 5k–10k curated | **far above** |
| Windows EPS (ws01) | 14.1 | 1–5 workstation | **~3–14× above** |

Top ports by connection count: `443` 32.1%, `53` 31.7%, `514` 5.0%, `161` 5.0%, `80` 4.4%,
`5355` 4.1%, `445` 2.5%.

## 3. Findings that overturn earlier conclusions

### 3a. "DNS share is too high" was WRONG — it is too LOW

An earlier gate flagged DNS at 60.6% against a "10–20%" target. That 60.6% was DNS share of **Zeek
log documents**; the 10–20% figure is a **bytes**-based number. Measured the way the baseline
measures it — as a share of **connections** — DNS is 31.7% and all name services 38.8%, against an
enterprise norm of **45–65%**.

The range **under-produces** name-service traffic, and under-produces UDP generally (49.3% of
connections vs 68–87%). The correct action is more DNS/NetBIOS/mDNS chatter, not less. The audit
harness gate has been corrected accordingly.

### 3b. Windows hosts ARE too verbose — reversing task #38

Task #38 recorded "Sysmon config is already correct — my 'too verbose' premise was wrong", on the
grounds that a measured ~440k docs/host/day was a backfill artefact. A clean 30-minute steady-state
window says otherwise:

```
ws01     25,396 in 30m  ->  1,219,008/day   14.1 EPS
ws02     12,575 in 30m  ->    603,600/day    7.0 EPS
fs01      6,137 in 30m  ->    294,576/day    3.4 EPS
sql01     5,978 in 30m  ->    286,944/day    3.3 EPS
ir-dc01   3,191 in 30m  ->    153,168/day    1.8 EPS
```

Caveat, stated plainly: the two published baselines disagree with each other. "5,000–10,000
events/endpoint/day" describes a *curated* Critical-tier subscription (~0.06–0.12 EPS), while
"1–5 EPS for a workstation" implies 86k–432k/day. They cannot both be right. Against the EPS
baseline ws01 is ~3–14× high; against the curated-docs baseline it is ~122× high. Either way
**ws01 is the outlier and Step 3 deserves reopening** — but the honest multiplier is ~3–14×, not
122×, and the earlier "440k/day" number was not the artefact it was dismissed as.

Note also that `ir-dc01`, a domain controller, produces the *least* — the inverse of the real-world
pattern where a DC (300–500 EPS) far exceeds a workstation (1–5 EPS).

### 3c. auditd volume is now self-inflicted by the noise generators

The Falco feedback loop is genuinely fixed — falco no longer appears at all. But auditd is still
~75% of all telemetry, and the source has simply changed:

```
by key:      network_socket_created 50.9%   process_creation 32.6%
by process:  snmpd 33.6%  curl 28.5%  incusd 15.0%  python3 10.3%
by host:     cthost01 100%
```

The noise generators fork `curl` per request and wake `python3` on timers; every one trips
`socket()` and `execve()` audit rules. The `dnsnoise.py` generator added in this session
contributes directly. This is a *design* consequence of process-per-request noise, not a bug.

Auditing every socket creation also duplicates, far more expensively and far less usefully, what
Zeek already provides.

## 4. Comparison against SOC analyst lab environments

| Environment | Purpose | Benign traffic |
|---|---|---|
| **DetectionLab** | Vagrant/Packer lab with logging + security tooling | none to speak of |
| **Splunk Attack Range** | Terraform/Ansible lab, runs Atomic Red Team into Splunk | attack telemetry only |
| **GOAD** | Vulnerable multi-domain AD for practising attacks | none |
| **Security Onion** | The monitoring platform itself | n/a — it is the sensor |

**These are attack-simulation platforms. None of them meaningfully generates realistic benign
background traffic.** They exist to produce *malicious* telemetry on demand.

That is the gap this range fills, and it is why analysts trained on those labs can spot an attack
by contrast alone: in DetectionLab or Attack Range, essentially everything in the logs *is* the
attack. A hunt against a realistic 49-dataset benign baseline is a materially harder and more
faithful exercise — which is exactly the standing order to finish benign traffic before running
Atomic Red Team.

## 5. Actions arising

1. **Reopen Step 3 / task #38.** ws01 at 14.1 EPS is the outlier; Sysmon scoping needs revisiting
   with the EPS baseline, and the config must still be *retrieved* from sysmon-modular or
   SwiftOnSecurity, never authored.
2. **Increase name-service and UDP traffic**, not decrease it — 38.8% vs a 45–65% norm.
3. **Fix the DC/workstation inversion**: `ir-dc01` should produce the most events, not the least.
4. **Scope the auditd `network_socket_created` rule.** It is 50.9% of audit volume and duplicates
   Zeek. Preferred filter is by `auid` (daemon activity has `auid=unset`; interactive and attacker
   activity does not), which preserves detection value — rather than excluding `curl`/`python3` by
   path, which would blind the range to genuine malicious use of those binaries.
5. **Add name-service failure realism**: enterprises show 36–50% NetBIOS/name-service failure.
6. Baselines and units are now encoded in `/usr/local/bin/range-audit` on so01 so this comparison
   is repeatable rather than a one-off.

## References
- [A First Look at Modern Enterprise Traffic (IMC 2005, LBNL)](https://www.icir.org/enterprise-tracing/first-look-imc05/)
- [Splunk Attack Range](https://github.com/splunk/attack_range)
- [GOAD — Game of Active Directory](https://github.com/Orange-Cyberdefense/GOAD)
- [Gigamon TLS trends — encrypted east-west share](https://www.gigamon.com/company/news-and-events/newsroom/ssl-tls-research-2022.html)
- [Neo23x0 auditd best-practice configuration](https://github.com/Neo23x0/auditd)
