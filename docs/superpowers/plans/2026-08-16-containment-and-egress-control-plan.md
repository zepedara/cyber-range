# Range Containment and Egress Control

**Status:** in progress — audit complete and severe, remediation starting
**Date:** 2026-08-16
**Motivation:** operator request — "implement a strong protection and firewall against anything
escaping the environment … it should be a self sustaining and self contained testing environment
for hunting on with strong protections"

---

## 1. Audit result: the range is not contained

Measured 2026-08-16 from inside the range, using `bash /dev/tcp` (not `nc`, which is absent on
several hosts and previously produced exit-127s that read as network failures).

Nine distinct container subnets were probed — one live container per subnet, enumerated from
`incus list` rather than guessed, after a first pass silently skipped three names that do not
exist.

**Every segment reached every target.**

| From (all 9 segments) | Target | Result |
|---|---|---|
| `10.30.5/10/20/30/40/45/60/70/99` | house router `192.168.1.1:80` | **ESCAPES** |
| | rick hypervisor mgmt `192.168.1.144:8006` | **ESCAPES** |
| | l3e7 hypervisor mgmt `192.168.1.145:8006` | **ESCAPES** |
| | Security Onion `192.168.1.146:443` | **ESCAPES** |
| | public internet `1.1.1.1:443`, `8.8.8.8:53` | **ESCAPES** |
| | public DNS resolution | **RESOLVES** (8 of 9) |
| | Tailscale `100.112.76.79:22` | blocked (the only block) |

This includes `pivot01`, the attacker pivot server, and the BYOD/guest segments.

### What this means concretely

- A compromised range host can reach **both hypervisor management UIs**. That is a full
  virtualisation escape path — control of the hypervisor is control of every VM, including so01.
- It can reach **Security Onion itself**, the system holding the evidence. An attacker simulation
  could tamper with or delete its own telemetry.
- **Real C2 would succeed.** Any sample or tool that beacons out would reach the actual internet
  from the user's residential IP.
- The range can reach the **house router admin interface**.

The range is presently a routed extension of the house LAN, not an isolated environment.

## 2. Topology — where enforcement can go

```
container 10.30.x.y
   └─ default gw 10.30.x.1  ── fw01 (OPNsense)  WAN leg 10.20.0.61 on vmbr0
                                  │  NATs: rick has NO route to 10.30.0.0/16
                                  ▼
                             rick 10.20.0.1 / 192.168.1.144   ip_forward=1, nftables EMPTY
                                  ▼
                             house router 192.168.1.1 ──► internet
```

Identification evidence:
- fw01 is `10.20.0.61` — TLS cert `CN=OPNsense.internal`, HTTP header `Server: OPNsense`.
- rick has no `10.30.0.0/16` route (`ip route get 10.30.20.101` → `via 192.168.1.1`), proving
  fw01 masquerades.

**Consequence that drives the design:** by the time range traffic reaches rick its source address
is fw01's WAN IP `10.20.0.61`, *not* `10.30.x`. A rule at rick matching `10.30.0.0/16` would match
nothing while appearing correct. This is the same class of silent no-op that left the previous
range→house block unapplied, so it is called out explicitly here.

## 3. Design — defence in depth, three independent layers

No single layer is trusted. Each is independently sufficient to stop the worst case.

### Layer 1 — fw01 (OPNsense): policy chokepoint
Default-deny egress from every range interface, with a narrow allowlist. This is the layer that
carries the *policy* and produces the logged denies that make good hunting telemetry.

Must be applied through **Firewall → Automation → Filter** (the `os-firewall` plugin, API endpoint
`firewall/filter`). This is a *separate ruleset* from hand-created rules; editing the wrong path in
`config.xml` is silently ignored — the previously observed trap. This path also auto-creates a
savepoint and rolls back after 60s if the change locks you out.

### Layer 2 — rick nftables: independent backstop
A `forward`-chain policy at the hypervisor, matching on **`10.20.0.61`** (fw01's WAN). Independent
of OPNsense entirely: if fw01 is misconfigured, rebooted into a default state, or compromised, this
still holds. Currently the ruleset is empty, so this is additive and low-risk.

### Layer 3 — Firewalla Gold SE: last resort at the house edge
Block the range's source address from WAN and from house VLANs. Catches the case where both
rick and fw01 fail.

### Allowlist — the only traffic permitted out
| Flow | Reason |
|---|---|
| range → `192.168.1.146` : `5055`, `8220` | Elastic Agent telemetry to so01. Severing this blinds the SOC. |
| house `192.168.1.0/24` → range (inbound-initiated) | operator management; return traffic via conntrack |
| established/related | return path for the above |

**Everything else denied, including all internet access.** The range already has a fake internet
(`pivot01` + 600 fakenet DNS mappings, now dual-stack), so real egress is not needed for realism —
it is purely a leak. A documented break-glass toggle re-enables it for maintenance windows.

### Explicitly out of scope for this change
- `10.20.0.70` (`files.lab.local`) is a range asset sitting directly on the hypervisor management
  bridge `vmbr0`. That is a containment defect but relocating it is a separate change; noted as
  follow-up so this plan stays reversible.

## 4. Gates — each verified by measurement, not by reading rules

| # | Gate | Method |
|---|---|---|
| G1 | 0 of 9 segments reach `192.168.1.1`, `.144:8006`, `.145:8006` | re-run `egress_audit2.sh`, expect all `blocked` |
| G2 | 0 of 9 segments reach `1.1.1.1:443` or resolve public DNS | same harness |
| G3 | Telemetry still flowing: Windows + container docs continue to arrive | ES doc count over a 10-min window, before vs after |
| G4 | Layer 2 holds with Layer 1 disabled | disable the OPNsense rule, re-run G1 |
| G5 | Denies are logged and searchable in SO | query the drop-log dataset |
| G6 | Survives reboot of fw01 and of rick | persist rules, reboot, re-run G1 |

G3 is the one that can silently fail: a block that also severs telemetry looks like success on
G1/G2 while destroying the range's purpose.

## 5. Rollout order

1. Layer 2 at rick, applied **with an automatic rollback timer** — the connection used to apply it
   traverses the host being firewalled.
2. Verify G1–G3.
3. Layer 1 at fw01 via the Automation API.
4. Verify G4 (disable L1, confirm L2 alone holds), then re-enable.
5. Layer 3 at the Firewalla.
6. Persist across reboots, verify G6.

## 6. Findings folded in from the same audit

- **DNS dual-stack fixed.** All 600 fakenet names were A-only; dnsmasq answers AAAA for such names
  with NXDOMAIN rather than NODATA, which was 85.6% of all NXDOMAIN in the range. Added 600 AAAA
  companions on dc01 and extdns01. NXDOMAIN 45.1% → 17.9%. Note: `systemctl reload dnsmasq` does
  **not** re-read `conf-dir`; a full restart is required.
- **Residual NXDOMAIN (~18%)** is now names the noise generators query that were never provisioned
  in any zone — a different defect from the one fixed.
- **DNS is 61.8% of all network events** vs a 10–20% enterprise norm. The generators are
  DNS-heavy relative to the sessions they produce.
- **so01 access path was undocumented.** It had no ssh entry and no known_hosts entry anywhere;
  the prior session reached it by password via `sshpass` from l3e7. Now key-based through a
  `ProxyJump l3e7-pve` entry. Also: SO's login banner corrupts the legacy scp protocol — pipe
  scripts with `ssh so01 'bash -s' < file` instead of scp.

## References

- [OPNsense firewall automation](https://docs.opnsense.org/manual/firewall_automation.html)
- [OPNsense firewall API](https://docs.opnsense.org/development/api/core/firewall.html)
- [OPNsense rules and default-deny](https://docs.opnsense.org/manual/firewall.html)
- [Egress filtering fundamentals — Rapid7](https://www.rapid7.com/blog/post/2013/08/28/firewall-egress-filtering-why-and-how-you-should-control-whats-leaving-your-network/)
- [FakeNet-NG — isolated-environment guidance](https://github.com/mandiant/flare-fakenet-ng)
