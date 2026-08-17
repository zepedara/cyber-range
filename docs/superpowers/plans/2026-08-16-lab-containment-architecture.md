# Lab Containment Architecture — Placement, Management Plane, and Isolation

**Status:** design for review — no migration performed
**Date:** 2026-08-16
**Trigger:** operator raised the threat model — *"it's likely we will be downloading attacker
malware in the environment and we need to ensure there's no way for anything to escape"*, plus
*"you do need to be able to manipulate the VMs and containers within it"*, and a proposal to move
project data to l3e7 so cthuwu can be fully locked down.

---

## 1. What changed

Until now the range's constraint was **no live malware on range hosts**. Lifting that inverts the
design problem. Previously the range was a *source of realistic telemetry* and the worst case was
noisy data. Now the design must hold when **a guest is fully compromised and the attacker is
actively trying to leave**.

Two consequences:

1. Firewall rules alone are insufficient. They assume the guest stays inside its VM. The 2025–26
   ESXi escape campaigns chain emulated-device bugs to execute in the hypervisor process, and the
   `VSOCKpuppet` backdoor communicated guest→host over VSOCK, *invisible to network monitoring*.
   Isolation therefore has to be **physical/placement-based**, not only network-based.
2. Anything valuable co-resident on the same hypervisor as a detonation guest is in the blast
   radius, regardless of VLANs.

## 2. Measured state

### Hosts

| | **cthuwu** `192.168.1.144` | **l3e7** `192.168.1.145` |
|---|---|---|
| CPU | TR 3960X, 48 cores | i9-11900K, 16 cores |
| RAM | 125 GB (59 GB free) | 62 GB (**14 GB free**) |
| Running | 11 VMs, 82 GB allocated | so01 only, 40 GB |
| Free storage | vmstore 813 G, vmdata 676 G, /mnt/hot 1013 G | tank 2.62 T, rpool 857 G, /var/lib/vz 829 G |
| IOMMU | **not enabled** | **not enabled** |

`cthuwu` is the machine previously referred to as "rick"; **VM 100 `rick` is the user's services
guest living on it** (12 GB RAM, 1.86 TB disk). That is the single most important fact in this
document: *the crown jewels currently share a hypervisor with the range.*

### Containment

All nine range segments currently reach the house router, **both hypervisor management UIs**, the
Security Onion SOC, and the real internet. Full detail and the remediation rule set are in
`2026-08-16-containment-and-egress-control-plan.md`. A Layer-2 nftables backstop was written and
proven to apply cleanly; it was deliberately allowed to auto-roll-back pending operator sign-off.

### Management plane — the blocker

Verified directly (an earlier check was buggy and its results were discarded):

```
100 rick        cfg=1        QEMU guest agent is not running
150 range-dc01  cfg=1        QEMU guest agent is not running
151..155, 161   cfg=1        QEMU guest agent is not running
310 cthost01    cfg=enabled=1 QEMU guest agent is not running
146 kali        cfg=1        ANSWERS
```

The agent is **enabled in VM config but not installed inside the guests**. Only `kali` answers.
Containers are fine — `incus exec` already works and is host-side.

**So if the network were locked down today, the range VMs would become unmanageable.** This is
the reason the lockdown has not been completed, and it is the first thing to fix.

## 3. The management-plane answer

The operator asked how to manipulate VMs "through the firewall". The correct answer is that you
should **not** manage them through the firewall at all — you manage them from the **hypervisor
control plane**, which is a different plane entirely and needs no guest-network reachability.
This is standard out-of-band management: a management path separate from the production path.

Three channels, in order of preference:

| Channel | Works today | Guest-network needed | Notes |
|---|---|---|---|
| `incus exec` (containers) | **yes** | no | already how the range containers are driven |
| Proxmox VNC/noVNC console | **yes** (Proxmox default) | no | needs nothing inside the guest; the reliable fallback |
| `qm guest exec` (agent) | **no** — not installed | no | scriptable; must be installed first |
| serial console | only on fw01 | no | worth adding; text-streamable, good for automation |

### Where the agent must NOT be used

`qemu-guest-agent` is appropriate for **benign** range hosts, but should be **absent from the
detonation zone**:

- `guest_exec` carries an OS-command-injection CVE (CVE-2019-12929) — it is host→guest attack
  surface running at SYSTEM/root inside the guest.
- It is a **sandbox-evasion tell**: malware fingerprints virtual hardware and helper processes and
  changes behaviour when it sees them, which corrupts the analysis.

So: **agent ON for the enterprise-simulation range** (scripted control, no network),
**agent OFF in the detonation zone**, driven instead by console + snapshot revert — the standard
malware-lab workflow of snapshot → detonate → observe → revert to pristine.

## 4. Placement — recommendation

The operator proposed moving project data to l3e7 so cthuwu could be locked down. **I recommend
inverting it**, for a concrete reason: the range needs the big machine and cannot fit anywhere
else, whereas the thing that actually needs protecting is small and portable.

The range currently runs 82 GB allocated across 11 VMs on 48 cores. l3e7 has 62 GB total and 16
cores, with so01 alone consuming 40 GB. **The range cannot move to l3e7.** But `rick` (12 GB,
1.86 TB provisioned) can.

### Target layout

```
cthuwu  = DISPOSABLE / HOSTILE          l3e7 = TRUSTED
  fw01, cthost01 (31 containers)          so01  Security Onion (SOC + evidence)
  range VMs 150-155, 161                  rick  user services  <-- MOVE HERE
  detonation zone (isolated VLAN)
  kali / DFIR tier
  nothing of value; rebuildable
```

Rationale: after the move, **cthuwu holds nothing worth protecting**. A hypervisor compromise
there costs a rebuild, not data. Both the SOC and the user's services sit on a physically separate
box that the range cannot route to.

### The constraint that blocks this today

RAM on l3e7:

```
so01 40 GB + rick 12 GB + host overhead ~6 GB  =  58 GB   of 62 GB physical
```

That leaves ~4 GB of headroom, which is too thin for a ZFS-root host (ARC needs room). Options,
best first:

1. **Add RAM to l3e7** — the i9-11900K platform takes 128 GB. Cleanest, removes the constraint
   permanently, and leaves room for a second SOC-side workload.
2. **Trim so01 to 32 GB** — it is an Elasticsearch node; needs measuring against actual heap and
   retention before committing, and risks degrading the SOC.
3. **Enable KSM on l3e7** — helps least here; so01 and rick share few pages.

Disk is not a constraint: `tank` has 2.62 TB free against rick's 1.86 TB provisioned (actual
allocation is lower).

### What stays put

- **so01 on l3e7** — already correct. The SOC must never share a hypervisor with detonation.
- **The range on cthuwu** — it needs the cores and RAM.
- **`10.20.0.70` (`files.lab.local`)** is a range asset sitting directly on the hypervisor
  management bridge `vmbr0`, bypassing fw01 entirely. It should be moved behind fw01. This is a
  live containment defect independent of everything else here.

## 5. Isolation design for the detonation zone

Beyond the three-layer network containment already specified:

- **Dedicated VLAN with no gateway.** Not "a firewalled gateway" — no gateway at all. Services the
  samples expect are answered locally by INetSim/FakeNet-NG, which is the established pattern for
  giving malware a convincing internet without one.
- **Agent absent, snapshot-driven.** Snapshot before detonation, revert after, always — including
  when the sample appears to have done nothing.
- **No shared storage or clipboard** between detonation guests and anything else; no virtiofs, no
  shared folders.
- **Telemetry is the one permitted flow.** Agents push to so01 `:5055`. This is the sole hole in
  the design and should be the only allowed destination/port pair, from fw01's WAN address only.
- **Enable IOMMU on both hosts.** Currently off on both. It does not stop a QEMU-process escape
  but it is a prerequisite for any device-level isolation and costs nothing.
- **Keep the SPAN path in mind.** cthuwu already mirrors traffic to so01 over VXLAN; that is a
  cthuwu→l3e7 path and must be accounted for in the l3e7 firewall, not just the range's.

## 6. Sequenced plan

Ordered so that nothing is locked down before it can still be managed.

| # | Step | Gate |
|---|---|---|
| 1 | Install `qemu-guest-agent` / virtio tools in range VMs 150–155, 161, 100, 310 (task #31) | `qm agent <id> ping` answers for each; `qm guest exec` returns output |
| 2 | Add serial console to range VMs | text stream obtainable with the guest network down |
| 3 | Re-apply Layer 2 nftables at cthuwu, cancel rollback, persist | 0 of 9 segments reach house/internet; telemetry doc count unchanged |
| 4 | Layer 1 default-deny at fw01 via Automation API | Layer 1 alone holds with Layer 2 removed |
| 5 | Move `10.20.0.70` behind fw01 | it no longer appears on `vmbr0` |
| 6 | Resolve l3e7 RAM, migrate VM 100 `rick` → l3e7 | rick running on l3e7; cthuwu holds nothing of value |
| 7 | Enable IOMMU on both hosts | `dmesg` shows AMD-Vi / DMAR enabled |
| 8 | Build detonation zone: no-gateway VLAN, INetSim, agent-off, snapshot policy | sample detonated with zero egress observed in Zeek |
| 9 | Layer 3 at the Firewalla | range source blocked at the house edge |

Steps 1–2 are prerequisites for 3–4. Step 6 is blocked on the RAM decision.

## 7. Open decisions for the operator

1. **l3e7 RAM** — add memory, or trim so01? This gates moving `rick` off the range host.
2. **Does the range keep any real internet?** Recommendation: no. The fake internet already exists
   (pivot01 + 600 dual-stack fakenet names). A documented break-glass toggle covers maintenance.
3. **Detonation zone on cthuwu, or a third physical box?** With IOMMU off and escape in the threat
   model, a separate physical host is the stronger answer; cthuwu-with-nothing-valuable is the
   pragmatic one.

## References

- [QEMU security model](https://qemu-project.gitlab.io/qemu/system/security.html)
- [ESXi VM escape campaign, 2025–26](https://www.huntress.com/blog/esxi-vm-escape-exploit)
- [Breaking the virtual barrier — Sygnia](https://www.sygnia.co/threat-reports-and-advisories/breaking-the-virtual-barrier-web-shell-to-ransomware/)
- [Sandbox evasion techniques — Unit 42](https://unit42.paloaltonetworks.com/sandbox-evasion-memory-detection/)
- [FakeNet-NG](https://github.com/mandiant/flare-fakenet-ng)
- [INetSim fake internet](https://www.netresec.com/?page=Blog&month=2019-12&post=Installing-a-Fake-Internet-with-INetSim-and-PolarProxy)
- [Out-of-band management](https://en.wikipedia.org/wiki/Out-of-band_management)
- [OPNsense firewall automation](https://docs.opnsense.org/manual/firewall_automation.html)
