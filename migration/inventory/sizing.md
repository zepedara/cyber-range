# Migration sizing — measured 2026-08-18T11:29Z

Source: `migration/inventory/192.168.1.144.txt` (cthuwu), `192.168.1.145.txt` (l3e7).
Collector: `migration/inventory/collect.sh` (read-only).

## Hosts today

| | cthuwu (192.168.1.144) | l3e7 (192.168.1.145) |
|---|---|---|
| Proxmox | 8.4.19, kernel 6.8.12-39-pve | (see capture) |
| CPU | AMD Threadripper 3960X, 48 threads | |
| RAM | 125 GB total, 60 used, 64 available | |
| Guests | 29 defined, 11 running | 1 running (so01) |

## RAM — the target is not RAM-bound

| Consumer | GB |
|---|---|
| cthuwu running guests | 76.0 |
| l3e7 so01 | 40.0 |
| **Combined running** | **116.0** |
| ZFS ARC (capped, plan Task 5.2) | 32 |
| Proxmox host + overhead | 8 |
| **Available to guests on 384 GB** | **~344** |
| **Headroom after consolidation** | **~228 GB** |

The 384 GB target absorbs the entire current estate with ~228 GB spare, which is what makes the
Phase 3 expansion estate affordable. RAM is not the constraint — **disk is**.

## Disk — this is the binding constraint, and rick dominates it

Bootdisk totals from `qm list`:

| Set | GB |
|---|---|
| cthuwu, all 29 guests | 3,413.9 |
| — of which **rick (VM 100)** | **1,863.0  (55%)** |
| cthuwu WITHOUT rick | 1,550.9 |
| l3e7 so01 (must also travel) | 300.0 |
| **Payload WITH rick** | **3,713.9** |
| **Payload WITHOUT rick** | **1,850.9** |

Against a 5 TB target pool:
- **without rick → 1.85 TB (37% of pool)** — comfortable, leaves room for expansion guests + PBS.
- **with rick → 3.71 TB (74% of pool)** — tight, and leaves little for the Phase 3 expansion.

**✅ OPERATOR DECISION 2026-08-18: EXCLUDE RICK.** Blocking question 2 is closed — `rick` (VM 100)
does not travel. Payload is therefore **1,850.9 GB**.

The measurement supported it independently: excluding `rick` halves the payload, and it is *required*
anyway because rick holds `hostpci0: 0000:01:00` (the RTX 4090), which cannot follow to the C240 —
the same reason the cthuwu→l3e7 move was abandoned on 2026-08-16.
It also decides the external drive: **2 TB suffices without rick; with rick it does not.**

Practical consequences of excluding it, to carry into Phase 5:
- `vzdump` must be given an explicit guest list or `--exclude 100`; a bare "backup everything" sweep
  would silently pull in 1.86 TB and overflow the drive.
- rick stays on cthuwu and keeps running. Anything in the range that depends on rick's services
  (ntfy, qdrant, ollama, rustdesk relay) will NOT exist in the rack — none surfaced in the Phase 1.1
  dependency audit, but re-check before cutover.

## Network to recreate on the C240

Bridges referenced by guest NICs: `vmbr0 vmbr30 vmbr40 vmbr60 vmbr61 vmbr91`
VLAN tags on VM NICs: `10 20 30 99`

Note the VM-edition NICs only show 4 tags because the remaining VLANs terminate *inside*
cthost01 (Incus) and on fw01's own interfaces — the 9-VLAN matrix is not visible from
`qm config` alone and must be captured from fw01 + cthost01 separately (Phase 1).

`vmbr91` is the VXLAN span path to l3e7. Once so01 is consolidated onto the same host
(Phase 2), that path collapses to a local bridge — plan Task 2.3.

## MAC addresses — captured, 33 NIC lines on cthuwu + 2 on l3e7

⚠️ **The plan's own verification step is wrong.** Task 0.1 Step 3 runs
`grep -c 'macaddr' migration/inventory/*.txt` and expects a non-zero count. Proxmox does not
emit a `macaddr=` token — it writes `net0: virtio=BC:24:11:86:A8:43,bridge=vmbr0`. The grep
returns **0 on a perfectly good capture**, which would read as "no MACs recorded, the restore
will break DHCP reservations".

Correct check:

```bash
grep -cE '^VM[0-9]+ net[0-9]+: [a-z0-9]+=([0-9A-F]{2}:){5}[0-9A-F]{2}' migration/inventory/*.txt
```

All guest MACs are in the OUI range `BC:24:11:*` (Proxmox-assigned).

## Parsing note

`qm list` output includes one row (`VM400`) that parses as name=`running`, which is a column
artefact, not a real guest — do not treat it as an estate member.
