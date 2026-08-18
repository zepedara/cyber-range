# C240 M4 target preparation — storage controller

Status 2026-08-18: operator has **deleted the virtual drives and the configured RAID**, moving to JBOD.
Blocking question 1 from the migration plan is **answered: JBOD, using the onboard controller.**

## ⚠️ There is one more step, and it is not where you would look

Per Cisco's own guide for this exact controller, enabling JBOD is a **three**-step sequence:

1. Delete any existing Virtual Drives ✅ *done*
2. Deleting the VDs releases the physical disks into **`Unconfigured Good`** ✅ *this is where they are now*
3. **Enable JBOD in the pre-boot RAID configuration menu (`Ctrl+R` during POST)** ⬅️ **STILL REQUIRED**

> "JBOD is disabled on the controller by default, and cannot be enabled on the 12G Controller via the
> CIMC, only the pre-boot RAID Configuration menu (CTRL+R)."
> — Cisco, *C-Series: Enable JBOD on Cisco 12G SAS Modular Raid Controller*

**`Unconfigured Good` is NOT JBOD.** In that state the disks are claimed by the controller and are not
presented to the OS as raw devices, so a Proxmox installer / `lsblk` may show nothing usable and ZFS
will have no disks to build a pool from. This is the classic "looks finished, isn't" state.

**It cannot be done from CIMC's web UI.** CIMC KVM can *display* the pre-boot menu, but the JBOD toggle
does not exist in CIMC's own storage pages. Plan for `Ctrl+R` at POST.

## Verify JBOD actually took, before trusting it

On the controller (pre-boot menu): each physical disk should report state **JBOD**, not
`Unconfigured Good`, not `Online` (Online = still a RAID member).

Once Proxmox boots, all three of these must hold:

```bash
# 1. every data disk appears as a whole raw block device
lsblk -dno NAME,SIZE,MODEL,TRAN

# 2. SMART passes through the controller - proves it is not hiding the disk behind a RAID abstraction
smartctl -i /dev/sda            # expect real model/serial, not a virtual-disk identity
#    if it is still behind MegaRAID, this is the fallback form:
#    smartctl -i -d megaraid,0 /dev/sda

# 3. the controller is in the expected personality
lspci -nn | grep -i -E 'raid|sas'
storcli64 /c0 show 2>/dev/null | grep -iE 'JBOD|Personality'   # if storcli is installed
```

If SMART only answers via `-d megaraid,N`, the disks are still behind the RAID layer — ZFS will work
but loses direct SMART, per-disk error handling and predictable disk replacement. Fix it at the
controller rather than accepting it.

## Why this matters more than usual for this build

- The plan targets a **5 TB ZFS pool**, and this cannot be corrected after data lands on it.
- ZFS wants direct disk access. Cisco/TrueNAS guidance is that the **UCSC-SAS12GHBA** is the preferred
  part for ZFS; the 12G Modular RAID in JBOD works, but is second best.
- **Do NOT fall back to per-disk single-drive RAID0** if JBOD proves unavailable. It is the common
  workaround and it is wrong here: it masks SMART, interposes the controller cache, and makes disk
  replacement painful. If JBOD cannot be enabled, source an HBA instead.

## Remaining hardware unknowns

- Controller cache / BBU behaviour once in JBOD — confirm write cache is not being applied to JBOD disks.
- Whether the boot device (1 TB OS) is on the same controller. If it is, it also needs a decision:
  JBOD + ZFS-on-root, or leave a single RAID1/RAID0 VD purely for boot while the 5 TB data disks are JBOD.
  The plan assumes **1 TB OS + 5 TB ZFS** as separate concerns — worth confirming at the controller.

## Sources

- Cisco, *C-Series: Enable JBOD on Cisco 12G SAS Modular Raid Controller* —
  https://www.cisco.com/c/en/us/support/docs/servers-unified-computing/ucs-c-series-rack-servers/200509-C-Series-Enable-JBOD-on-Cisco-12G-SAS.html
- Cisco UCS C240 M4 SFF spec sheet —
  https://www.cisco.com/c/dam/en/us/products/collateral/servers-unified-computing/ucs-c-series-rack-servers/c240m4-sff-spec-sheet.pdf
- TrueNAS community, ZFS on Cisco C-series controllers —
  https://www.truenas.com/community/threads/truenas-on-cisco-c460-m4-server-questions-about-optimal-setup.114735/
