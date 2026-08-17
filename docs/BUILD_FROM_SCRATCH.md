# Building the range from scratch

A complete build path using **native commands and upstream packages only**. Nothing here depends on the
helper scripts in this repository — every step is something you type, and every configuration file is
shown in full.

Where a value is site-specific it appears as a placeholder in `ANGLE_BRACKETS`. Choose your own
passwords; none are supplied.

> **Scope.** This builds one simulated enterprise rendered twice — once as containers, once as virtual
> machines — behind a single firewall, with all traffic mirrored to a Security Onion sensor. Two
> hypervisors are assumed. Read §1 before buying or allocating anything.

---

## Contents

1. [What you are building](#1-what-you-are-building)
2. [Hardware and host prerequisites](#2-hardware-and-host-prerequisites)
3. [Hypervisor A — networking and bridges](#3-hypervisor-a--networking-and-bridges)
4. [The firewall (OPNsense)](#4-the-firewall-opnsense)
5. [The container host (Debian + Incus)](#5-the-container-host-debian--incus)
6. [The traffic mirror (SPAN over VXLAN)](#6-the-traffic-mirror-span-over-vxlan)
7. [Hypervisor B and Security Onion](#7-hypervisor-b-and-security-onion)
8. [The Windows estate](#8-the-windows-estate)
9. [Active Directory and the user population](#9-active-directory-and-the-user-population)
10. [Endpoint telemetry (Sysmon, audit policy, Elastic Agent)](#10-endpoint-telemetry)
11. [Linux telemetry (auditd)](#11-linux-telemetry-auditd)
12. [Business data and services](#12-business-data-and-services)
13. [User simulation (GHOSTS)](#13-user-simulation-ghosts)
14. [Verification — the gates](#14-verification--the-gates)
15. [Traps, in the order you will hit them](#15-traps-in-the-order-you-will-hit-them)

---

## 1. What you are building

```
                    ┌──────────────────────── HYPERVISOR A ────────────────────────┐
   Internet ──▶ LAN │                                                              │
                    │   fw01 (OPNsense) ── .1 on every VLAN ── policy + DHCP + DNS  │
                    │        │                                                      │
                    │   ┌────┴─────────────────┬──────────────────────────────┐     │
                    │   │ 10.30.<vlan>.x       │ 10.31.<vlan>.x               │     │
                    │   │ CONTAINER EDITION    │ VM EDITION                   │     │
                    │   │ cthost01 (Incus)     │ Windows guests + GHOSTS API  │     │
                    │   │ ~30 containers       │ DC, workstations, file, SQL  │     │
                    │   └──────────────────────┴──────────────────────────────┘     │
                    │        │ tap → tc mirred → veth → vmbr91 → VXLAN 91           │
                    └────────┼─────────────────────────────────────────────────────┘
                             ▼
                    ┌──────────────────────── HYPERVISOR B ────────────────────────┐
                    │   so01  Security Onion  ── bond0 (monitor) ── Zeek + Suricata │
                    └──────────────────────────────────────────────────────────────┘
```

**Two editions, one enterprise.** The same company exists twice: as Linux containers on `10.30.<vlan>.x`
in DNS zone `range.lan`, and as Windows VMs on `10.31.<vlan>.x` in Active Directory domain `lab.local`.
This lets you teach container-era and traditional-Windows forensics from one coherent story.

**VLAN plan** — the firewall holds `.1` on all of them:

| VLAN | Name | Purpose | DHCP |
|---:|---|---|:---:|
| 5 | MGMT | hypervisor and infrastructure management | no |
| 10 | SERVERS | DC, file, SQL, mail, monitoring | no |
| 20 | USERS | workstations | yes |
| 30 | DMZ | public-facing web | no |
| 40 | VOICE | PBX and handsets | yes |
| 45 | OTIOT | building systems, cameras, HVAC | yes |
| 60 | BRANCH | remote-office subnet | yes |
| 70 | GUEST | untrusted wireless | yes |
| 99 | TRANSIT | firewall uplink | no |

Static addressing on 5/10/30/99 keeps servers findable; DHCP everywhere else so client
behaviour (lease renewals, DDNS) is real telemetry rather than absent.

---

## 2. Hardware and host prerequisites

| Role | Minimum | Comfortable | Notes |
|---|---|---|---|
| Hypervisor A | 12 cores / 48 GB / 500 GB SSD | 24+ cores / 64+ GB / 1 TB NVMe | runs the whole range |
| Hypervisor B | 8 cores / 24 GB / 500 GB SSD | 12 cores / 40 GB / 1 TB | Security Onion is RAM-hungry |

Security Onion's own guidance is 16 GB minimum for a standalone node; **allow 24–40 GB** if you want
Elasticsearch to stay responsive while you query it. Below ~16 GB it will run but paging will dominate.

Both hypervisors: **Proxmox VE 8.x or 9.x**. Enable virtualisation extensions in firmware
(`AMD-V`/`SVM` or `VT-x`) — check from the shell:

```bash
grep -Eom1 '(vmx|svm)' /proc/cpuinfo || echo "VIRTUALISATION IS OFF IN FIRMWARE"
lsmod | grep -E '^(kvm_amd|kvm_intel)'
```

If that prints nothing, stop and fix firmware first; nested guests will be unusably slow otherwise.

---

## 3. Hypervisor A — networking and bridges

You need one Linux bridge per VLAN, plus a mirror bridge. Proxmox writes
`/etc/network/interfaces`; edit it directly.

```bash
cp /etc/network/interfaces /etc/network/interfaces.bak-$(date +%F)
```

```ini
# /etc/network/interfaces  — hypervisor A
auto lo
iface lo inet loopback

# physical uplink to your house LAN
iface enp1s0 inet manual

# management bridge: the hypervisor's own address
auto vmbr0
iface vmbr0 inet static
    address <HYPERVISOR_A_IP>/24
    gateway <LAN_GATEWAY>
    bridge-ports enp1s0
    bridge-stp off
    bridge-fd 0

# ── range bridges. No bridge-ports: these are internal-only, reachable
#    solely through fw01. That isolation is the point.
auto vmbr5
iface vmbr5 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0

auto vmbr10
iface vmbr10 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0

# ... repeat for vmbr20 vmbr30 vmbr40 vmbr45 vmbr60 vmbr70 vmbr99

# ── VLAN-aware trunk for the VM edition. One bridge, tags per NIC.
auto vmbr61
iface vmbr61 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 2-4094

# ── mirror bridge. Carries SPAN traffic only.
auto vmbr91
iface vmbr91 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    # MAC LEARNING MUST BE OFF - see §15
    post-up ip link set vmbr91 type bridge ageing_time 0
    post-up ip link set vmbr91 type bridge mcast_snooping 0
```

Apply and verify:

```bash
ifreload -a          # Proxmox's ifupdown2; falls back to systemctl restart networking
ip -br link show type bridge
```

### Jumbo frames on the mirror path

Mirrored frames carry their original size plus VXLAN encapsulation, so the mirror path needs headroom or
you silently drop large packets.

```bash
ip link set vmbr91 mtu 9000
```

> **Trap.** Setting `mtu 9000` inside the `iface` stanza fails on some Proxmox/ifupdown2 versions — the
> bridge comes up at 1500 anyway and mirroring quietly truncates. Use a `post-up` line instead:
> `post-up ip link set vmbr91 mtu 9000`. This cost a real outage; see §15.

---

## 4. The firewall (OPNsense)

Download the OPNsense **amd64 dvd** image from <https://opnsense.org/download/> and verify it:

```bash
sha256sum -c OPNsense-*-dvd-amd64.iso.sha256
```

Create the VM with one NIC per VLAN bridge plus the transit uplink:

```bash
qm create 300 --name fw01 --memory 4096 --cores 2 --ostype other \
  --scsihw virtio-scsi-single --scsi0 local-lvm:32 \
  --cdrom local:iso/OPNsense-25.7-dvd-amd64.iso \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr5  \
  --net2 virtio,bridge=vmbr10 \
  --net3 virtio,bridge=vmbr20 \
  --net4 virtio,bridge=vmbr30 \
  --net5 virtio,bridge=vmbr40 \
  --net6 virtio,bridge=vmbr45 \
  --net7 virtio,bridge=vmbr60 \
  --net8 virtio,bridge=vmbr70 \
  --net9 virtio,bridge=vmbr61
qm start 300
```

Install to disk, then assign interfaces. On each range interface set the address to `.1`:

| Interface | Address |
|---|---|
| VLAN 5 | `10.30.5.1/24` and `10.31.5.1/24` |
| VLAN 10 | `10.30.10.1/24` and `10.31.10.1/24` |
| … | `.1` on every VLAN in both editions |

### Firewall policy

Build the matrix deliberately, and **log every deny** — denied traffic is some of the most useful
telemetry in the range because it shows intent.

Recommended posture:

- **GUEST (70)** and **OTIOT (45)** — internet only. No lateral access to any internal VLAN. These are
  your "penned in" segments and the denies they generate are teaching material.
- **USERS (20)** — may reach SERVERS (10) on service ports only; no management access.
- **SERVERS (10)** — may reach each other; outbound restricted to what services genuinely need.
- **DMZ (30)** — reachable inbound on 80/443; may *not* initiate into SERVERS.
- **MGMT (5)** — reachable only from your admin host.

### DNS

Unbound serves both zones. In the OPNsense UI: *Services → Unbound DNS → Overrides*, add
`range.lan` and `lab.local`, and forward `lab.local` to the Windows DC once it exists.

> **Trap.** If you edit `config.xml` directly, Unbound settings live under
> `<OPNsense><unboundplus>`, **not** `<unbound>`. Editing the wrong element appears to succeed and
> changes nothing.

---

## 5. The container host (Debian + Incus)

```bash
qm create 310 --name cthost01 --memory 16384 --cores 12 --ostype l26 \
  --scsihw virtio-scsi-single --scsi0 local-lvm:200 \
  --net0 virtio,bridge=vmbr5 \
  --net1 virtio,bridge=vmbr10 --net2 virtio,bridge=vmbr20 \
  --net3 virtio,bridge=vmbr30 --net4 virtio,bridge=vmbr40 \
  --net5 virtio,bridge=vmbr45 --net6 virtio,bridge=vmbr60 \
  --net7 virtio,bridge=vmbr70 \
  --cdrom local:iso/debian-13-netinst.iso
```

Install Debian 13, then Incus from the distribution repositories:

```bash
apt update && apt install -y incus incus-client
incus admin init --minimal
```

### One Incus network per VLAN

Each container attaches to the bridge for its segment. Create a profile per VLAN so container
creation is a one-liner:

```bash
for v in 5 10 20 30 40 45 60 70; do
  incus profile create vlan$v 2>/dev/null
  incus profile device add vlan$v eth0 nic nictype=macvtap parent=ens${v} name=eth0
done
```

Create containers with static addresses:

```bash
incus launch images:debian/13 fs01 --profile vlan10
incus exec fs01 -- bash -c 'cat > /etc/systemd/network/10-eth0.network <<EOF
[Match]
Name=eth0
[Network]
Address=10.30.10.11/24
Gateway=10.30.10.1
DNS=10.30.10.10
EOF
systemctl enable --now systemd-networkd'
```

Repeat per role. A representative estate:

| Container | VLAN | Address | Role |
|---|---:|---|---|
| `dc01` | 10 | 10.30.10.10 | DNS / directory (container edition) |
| `fs01` | 10 | 10.30.10.11 | Samba file server |
| `sql01` | 10 | 10.30.10.12 | MariaDB |
| `mail01` | 10 | 10.30.10.13 | Postfix / Dovecot |
| `mon01` | 10 | 10.30.10.14 | monitoring |
| `ca01` | 10 | 10.30.10.15 | internal CA |
| `proxy01` | 30 | 10.30.30.12 | Squid forward proxy |
| `web01` | 30 | 10.30.30.10 | nginx |
| `wk01`–`wk05` | 20 | 10.30.20.10x | Linux workstations |
| `byod01`–`02` | 70 | 10.30.70.10x | guest devices |
| `phone01`–`02` | 40 | 10.30.40.10x | SIP handsets |
| `cam01`–`02`, `hvac01`, `badge01` | 45 | 10.30.45.10x | building systems |
| `br-fs01`, `br-wk01`–`02` | 60 | 10.30.60.10x | branch office |
| `bastion01` | 5 | 10.30.5.11 | jump host |

---

## 6. The traffic mirror (SPAN over VXLAN)

This is the part most builds get wrong. The goal: every frame on every VLAN reaches the sensor **with
its VLAN tag intact**, so segment attribution works in Zeek.

### Step 1 — a veth pair into the mirror bridge

```bash
ip link add spanmir type veth peer name spanmir-br
ip link set spanmir up
ip link set spanmir-br up
ip link set spanmir-br master vmbr91
ip link set spanmir mtu 9000
ip link set spanmir-br mtu 9000
```

> **Why a veth and not the bridge directly.** `tc mirred` pointed at a *bridge master* does **not**
> flood to the bridge's members. You get a mirror that reports success and delivers nothing. Mirror into
> one end of a veth whose peer is a bridge port instead.

### Step 2 — mirror each access port

For every VM tap and container host interface, add an ingress and egress mirror:

```bash
mirror_iface() {
  local IF=$1
  tc qdisc add dev "$IF" handle ffff: ingress 2>/dev/null
  tc filter add dev "$IF" parent ffff: protocol all u32 match u8 0 0 \
     action mirred egress mirror dev spanmir
  tc qdisc add dev "$IF" handle 1: root prio 2>/dev/null
  tc filter add dev "$IF" parent 1: protocol all u32 match u8 0 0 \
     action mirred egress mirror dev spanmir
}

for IF in $(ls /sys/class/net | grep -E '^(tap|veth|ens)'); do mirror_iface "$IF"; done
```

Make it durable with a systemd unit that re-applies on boot and when new taps appear.

### Step 3 — VXLAN to hypervisor B

```bash
ip link add vxlan91 type vxlan id 91 local <HYPERVISOR_A_IP> \
   remote <HYPERVISOR_B_IP> dstport 4789 nolearning
ip link set vxlan91 mtu 9000
ip link set vxlan91 master vmbr91
ip link set vxlan91 up
```

Mirror the same on hypervisor B, attaching `vxlan91` to its own `vmbr91`, which feeds the sensor's
monitor interface.

### Step 4 — prove it before moving on

```bash
tcpdump -i spanmir -c 20 -e -nn        # should show frames from multiple VLANs, tagged
```

If you see nothing, re-read the veth note above. If you see untagged frames only, check that the
mirrored interfaces are the VLAN-tagged taps and not an untagged uplink.

---

## 7. Hypervisor B and Security Onion

Download the Security Onion ISO and **verify the signature** (the project publishes both a hash and a
GPG signature; check both):

```bash
sha256sum -c securityonion-*.iso.sha256
gpg --verify securityonion-*.iso.sig securityonion-*.iso
```

```bash
qm create 170 --name so01 --memory 40960 --cores 12 --ostype l26 \
  --scsihw virtio-scsi-single --scsi0 local-zfs:400 \
  --net0 virtio,bridge=vmbr0 \
  --net1 virtio,bridge=vmbr91 \
  --cdrom local:iso/securityonion.iso
```

Install as **STANDALONE**. During setup nominate `net1` as the monitor interface.

### Post-install, in this order

```bash
# 1. the monitor interface must carry jumbo frames or Zeek reports capture loss
sudo ip link set bond0 mtu 9000
# persist it in /etc/NetworkManager or /etc/sysconfig as your SO version dictates

# 2. disable checksum offloading on the monitor interface
sudo ethtool -K bond0 rx off tx off gso off tso off gro off lro off
```

> **Trap.** Without step 2 Zeek reports large, persistent `capture_loss` because the NIC hands it
> packets with unverified checksums. This looks exactly like a dropped-traffic problem and sends you
> hunting the wrong layer.

### Open the firewall for what you will connect

Security Onion firewalls everything by default. Nothing enrols until you allow it:

```bash
sudo so-firewall includehost elastic_agent_endpoint <RANGE_CIDR>
sudo so-firewall includehost syslog <RANGE_CIDR>
sudo so-firewall apply
```

Without these, agents fail to enrol *and silently roll themselves back*, which reads as "the agent
doesn't work" rather than "the port is closed".

### Talking to Elasticsearch

```bash
# Elasticsearch is HTTPS on 9200 and its curl.config carries no CA, hence -k
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
  "https://localhost:9200/_cat/indices?v" | head
```

Plain `http://` returns **empty** under `-s`, which looks identical to "there is no data".

---

## 8. The Windows estate

Six guests on the VLAN-aware trunk. Note `tag=` per role:

```bash
# domain controller — VLAN 10
qm create 150 --name dc01 --memory 6144 --cores 4 --ostype win11 \
  --scsihw virtio-scsi-single --scsi0 local-lvm:80 \
  --net0 virtio,bridge=vmbr61,tag=10 \
  --cdrom local:iso/Win2022.iso --ide2 local:iso/virtio-win.iso \
  --agent enabled=1

# workstations — VLAN 20
qm create 152 --name ws01 --memory 4096 --cores 2 --ostype win11 \
  --net0 virtio,bridge=vmbr61,tag=20 --agent enabled=1 ...
```

> **Image choice matters more than it looks.** If you build "workstations" from **Windows Server**
> media, you permanently lose workstation-only forensic artifacts. Most notably **Prefetch**: on Server
> SKUs the `SysMain` service *deletes* `EnablePrefetcher` when it starts, so `C:\Windows\Prefetch` stays
> empty no matter what you set in the registry, and a reboot re-deletes it. If you want to teach
> "did it execute?" from Prefetch, **use Windows 10/11 media for workstation roles.** See §15.

Install the QEMU guest agent on every guest (`virtio-win` ISO → `guest-agent\qemu-ga-x86_64.msi`) so the
hypervisor can query them:

```bash
qm guest cmd 152 get-host-name     # prints the name on success
```

> **Trap.** `qm guest cmd <id> ping` prints **nothing at all** when it succeeds. Read that as success,
> not as a broken agent. Use `get-host-name` or `get-osinfo` when you want visible output.

---

## 9. Active Directory and the user population

Promote the DC natively:

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName lab.local -DomainNetbiosName LAB `
  -InstallDns -SafeModeAdministratorPassword (Read-Host -AsSecureString "DSRM password")
```

Join the other guests:

```powershell
Add-Computer -DomainName lab.local -Credential (Get-Credential LAB\Administrator) -Restart
```

### Populating the directory

For a directory with thousands of objects and realistically messy permissions, use
**[BadBlood](https://github.com/davidprowe/BadBlood)** — it creates users, groups, computers, OUs and
deliberately invasive ACLs, differently every run:

```powershell
git clone https://github.com/davidprowe/BadBlood.git
cd BadBlood
.\Invoke-BadBlood.ps1        # edit $NumOfUsers first
```

> **What BadBlood does NOT do — and you must.** It sets **no HR attributes at all**, and it does not set
> `givenName`, `sn` or `displayName`. Straight after a BadBlood run every user has an empty name and no
> department, which makes the directory unenumerable in a way no real one is: no surname search, no name
> in any client, and no way to pivot from an account to a person.

Fill those in natively. Derive names from the sAMAccountName convention and set HR fields:

```powershell
Import-Module ActiveDirectory
$people = Get-ADUser -Filter * -Properties servicePrincipalName -ResultSetSize $null |
          Where-Object { -not $_.servicePrincipalName -and $_.SamAccountName -match '^[A-Za-z]+_[A-Za-z]+$' }

foreach ($u in $people) {
    $p  = $u.SamAccountName -split '_'
    $fn = (Get-Culture).TextInfo.ToTitleCase($p[0].ToLower())
    $ln = (Get-Culture).TextInfo.ToTitleCase($p[1].ToLower())
    Set-ADUser -Identity $u.DistinguishedName `
        -GivenName $fn -Surname $ln -DisplayName "$fn $ln" `
        -Replace @{ mail = "$($fn.ToLower()).$($ln.ToLower())@<MAIL_DOMAIN>" }
}
```

Then departments, titles, offices and a **manager chain** — an org chart is what makes
"is this behaviour normal for their role?" answerable:

```powershell
# assign a department and title, then point each user at a manager in the same department
Set-ADUser -Identity $dn -Replace @{ department='Finance'; title='Financial Analyst';
                                     company='<COMPANY>'; physicalDeliveryOfficeName='Chicago' }
Set-ADUser -Identity $dn -Manager $managerDn
```

Two realism rules worth following:

- **Do not aim for 100% completeness.** Real directories are not uniformly filled. Leave roughly 3% of
  users without a title, 4% without a manager and 7% without a phone number. Uniform completeness is
  itself a tell that the data was generated.
- **Keep the seniority pyramid the right way up** — many ICs, few directors — and make tenure correlate
  with seniority, so your executives are not all recent hires.
- **Leave BadBlood's random groups and messy ACLs alone.** They look like noise, but they *are* the
  AD attack-path exercise. Only add attributes; never tidy the permissions.

### Directory-change auditing (event 5136)

Attribute modification is how RBCD, SPN injection and scriptPath abuse work, and it is **invisible by
default**. It needs **both** halves:

```powershell
# half 1 - the subcategory
auditpol /set /subcategory:"Directory Service Changes" /success:enable
```

```powershell
# half 2 - a SACL that actually covers user attribute writes
$dom = (Get-ADDomain).DistinguishedName
$acl = Get-Acl -Path "AD:$dom" -Audit
$ace = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
    (New-Object System.Security.Principal.NTAccount('Everyone')),
    [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty,
    [System.Security.AccessControl.AuditFlags]::Success,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
    [guid]'bf967aba-0de6-11d0-a285-00aa003049e2')   # the user class
$acl.AddAuditRule($ace)
Set-Acl -Path "AD:$dom" -AclObject $acl
```

> **The default SACL is not enough, and it looks like it is.** A fresh domain root already carries audit
> ACEs, so a casual check says "SACL present, nothing to do". They are Microsoft's defaults scoped to
> `gPLink`/`gPOptions` (objectType `f30e3bbe`/`f30e3bbf`) on **organizationalUnit** — irrelevant to user
> attributes — and the broad one has `inheritance=None`, covering the domain object only. When reading an
> audit ACE you must look at `InheritanceType`, `ObjectType` **and** `InheritedObjectType`; rights and
> flags alone will mislead you.

Verify with a real write, and give it 15 seconds:

```powershell
Set-ADUser -Identity <SOME_USER> -Replace @{ description = "probe-$(Get-Date -f HHmmss)" }
Start-Sleep 15
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=5136; StartTime=(Get-Date).AddMinutes(-2)} |
  Select-Object -First 4 TimeCreated, @{n='attr';e={($_.Properties[10]).Value}}
```

One change produces **two** 5136 events — `%%14674` *Value Added* and `%%14675` *Value Deleted*, and the
Deleted one carries the **previous** value. That old value is the forensically useful part.

---

## 10. Endpoint telemetry

### Sysmon — retrieved from upstream, never hand-written

Pick one upstream configuration and deploy it as-is:

```powershell
# option A - SwiftOnSecurity, the widely deployed enterprise baseline
Invoke-WebRequest https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml `
  -OutFile sysmonconfig.xml

# option B - sysmon-modular, rules split per ATT&CK technique (better coverage mapping)
git clone https://github.com/olafhartong/sysmon-modular.git
cd sysmon-modular
Import-Module .\Merge-SysmonXml.ps1
Merge-AllSysmonXml -Path (Get-ChildItem '?_*') -AsString | Out-File sysmonconfig.xml
```

```powershell
.\Sysmon64.exe -accepteula -i sysmonconfig.xml
.\Sysmon64.exe -c            # confirm which config is live
```

**Never use** `sysmonconfig-excludes-only.xml` or `sysmonconfig-research.xml` — upstream marks both as
do-not-use-in-production because of extreme verbosity.

Deploy **separate configs for domain controllers, servers and workstations**. A single config across all
roles is the usual cause of runaway volume.

**Volume target: 5,000–10,000 events per endpoint per day.** Measure it and tune until you are in band:

```bash
# from the sensor
sudo curl -sSk -K /opt/so/conf/elasticsearch/curl.config \
 "https://localhost:9200/logs-*/_search?size=0" -H 'Content-Type: application/json' -d '{
  "query":{"bool":{"filter":[{"term":{"event.dataset":"windows.sysmon_operational"}},
    {"range":{"@timestamp":{"gte":"now-24h"}}}]}},
  "aggs":{"h":{"terms":{"field":"host.name","size":10}}}}'
```

The usual top offenders are **EID 7 (image load)**, **EID 11 (file create)** and **EID 3 (network)**. If
you are over budget, tune those first — via upstream's own exclusion sets, not filters you invent.

### Windows audit policy

```powershell
auditpol /set /subcategory:"Process Creation"        /success:enable
auditpol /set /subcategory:"Logon"                   /success:enable /failure:enable
auditpol /set /subcategory:"Logoff"                  /success:enable
auditpol /set /subcategory:"Kerberos Authentication Service"      /success:enable /failure:enable
auditpol /set /subcategory:"Kerberos Service Ticket Operations"   /success:enable /failure:enable
auditpol /set /subcategory:"Credential Validation"   /success:enable /failure:enable
auditpol /set /subcategory:"User Account Management"  /success:enable
auditpol /set /subcategory:"Security Group Management" /success:enable
auditpol /set /subcategory:"File Share"              /success:enable
```

Command line in 4688 is a **separate** setting, and without it 4688 is nearly useless:

```powershell
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\Audit" `
  /v ProcessCreationIncludeCmdLine_Enabled /t REG_DWORD /d 1 /f
```

PowerShell logging:

```powershell
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging" `
  /v EnableScriptBlockLogging /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ModuleLogging" `
  /v EnableModuleLogging /t REG_DWORD /d 1 /f
```

**Consider leaving "Detailed File Share" (5145) off, or filter it.** On a domain controller it is
enormous: nearly all of it is `IPC$` access to the `lsarpc` named pipe, which is pure LSA plumbing. Keep
5140, and if you do enable 5145, drop only `lsarpc` — retain `svcctl`, `samr` and `srvsvc`, because
`svcctl` over `IPC$` is exactly how PsExec-style lateral movement appears.

### Elastic Agent

Get the enrolment token from Fleet, then:

```powershell
.\elastic-agent.exe install `
  --url=https://<SENSOR_IP>:8220 `
  --enrollment-token=<TOKEN> `
  --insecure
```

Four traps, all of which produce a confident wrong diagnosis:

1. **Enrolment tokens are base64.** They contain `=` padding. Never parse one with `cut -d=` — you will
   truncate it and see an authentication failure that looks like a bad token.
2. **The Windows service is `"Elastic Agent"` — with a space.** `Get-Service elastic-agent` finds
   nothing and reads as "not installed".
3. **Put the Windows guests in a Windows policy.** A Linux policy contains `journald` and
   `logfile-system` inputs and **no `winlog` integration**, so Security, Sysmon, PowerShell and Defender
   are never collected even though the agent reports healthy.
4. **Check the output host actually resolves and listens.** An agent will happily take policy from one
   host while shipping data to a dead one; every event since enrolment is then dropped on the floor.

```powershell
& "C:\Program Files\Elastic\Agent\elastic-agent.exe" status
& "C:\Program Files\Elastic\Agent\elastic-agent.exe" inspect | Select-String winlog
```

---

## 11. Linux telemetry (auditd)

```bash
apt install -y auditd audispd-plugins
```

Use an upstream ruleset rather than writing your own — the widely used baseline is
**[Neo23x0/auditd](https://github.com/Neo23x0/auditd)**:

```bash
curl -fsSL https://raw.githubusercontent.com/Neo23x0/auditd/master/audit.rules \
  -o /etc/audit/rules.d/audit.rules
augenrules --load
auditctl -l | wc -l          # confirm the rules actually loaded
```

> **Always check the count after loading.** An invalid field silently collapses the whole ruleset — you
> get "No rules" and an effectively unaudited host. Probe a field before relying on it:
> `auditctl -a always,exit -F <field>=<value>` and see whether it is accepted. In particular `comm=` is
> **not** a valid filter field, and `exe=` compares **device+inode**, which makes it blind to processes
> inside containers.

### Keeping auditd volume sane

auditd emits roughly **ten documents per process creation** (execve plus PATH, CWD and PROCTITLE
companions), so the way to reduce it is to create fewer processes, not to filter harder:

- **Call binaries by absolute path** in anything that loops. An unqualified `curl` makes the shell walk
  `$PATH`, and auditd writes a PATH record per directory tried.
- **Use shell builtins for shell work.** `h=$(date +%H)` in a loop is a process every iteration;
  `printf '%(%H)T' -1` is free. Likewise `for ((i=1;i<=n;i++))` instead of `$(seq 1 $n)`.

---

## 12. Business data and services

Empty servers are the fastest way to make a range feel fake. Give each service real content.

### File server (Samba)

```bash
apt install -y samba
```

```ini
# /etc/samba/smb.conf
[global]
   workgroup = LAB
   server string = File Server
   security = user
   log level = 2

[public]
   path = /srv/public
   read only = no
   guest ok = yes

[finance]
   path = /srv/finance
   read only = no
   valid users = @finance
```

Create departmental shares that mirror your AD departments, and populate them with documents whose
names and dates span months — depth matters more than volume:

```bash
mkdir -p /srv/{public,finance,hr,it,legal,sales,engineering}
# generate dated files across a realistic span
for d in finance hr it legal sales engineering; do
  for i in $(seq 1 60); do
    printf 'internal document\n' > "/srv/$d/report-$(date -d "-$((RANDOM%700)) days" +%Y%m%d)-$i.txt"
  done
done
systemctl restart smbd
```

### Database (MariaDB) with a real schema

```bash
apt install -y mariadb-server
```

```sql
CREATE DATABASE corpdb CHARACTER SET utf8mb4;
CREATE TABLE employees (
  id INT PRIMARY KEY, sam_account_name VARCHAR(64), first_name VARCHAR(40),
  last_name VARCHAR(40), email VARCHAR(120), department VARCHAR(40),
  title VARCHAR(60), manager_id INT, hire_date DATE,
  salary DECIMAL(10,2), office VARCHAR(40), INDEX idx_sam (sam_account_name)
);
CREATE TABLE customers (...); CREATE TABLE orders (...);
CREATE TABLE order_items (...); CREATE TABLE invoices (...); CREATE TABLE products (...);
```

**Include `sam_account_name` and populate it from AD.** This one column is what lets an analyst pivot
*SIEM account → HR record → file-share activity*. Without it the join has to be made on first+last name,
which is fragile and ambiguous. Populate `manager_id` too, so the org chart exists on the database side
as well as in the directory.

> On Debian, `mysql --defaults-file=/etc/mysql/debian.cnf` gets you in without a root password.

### Proxy, mail, CA, monitoring

Install `squid`, `postfix`+`dovecot`, a small internal CA (`step-ca` or `openssl` scripts), and
`prometheus`+`grafana`. The point is that clients have somewhere real to go: proxied HTTP produces
`http.uri` diversity, mail produces SMTP conversations, the CA produces certificates that show up in
`x509`.

---

## 13. User simulation (GHOSTS)

[GHOSTS](https://github.com/cmu-sei/GHOSTS) (CMU SEI) drives **real** browsers and applications, which is
why it fixes fingerprint diversity — real Firefox and Chrome produce genuine JA3/JA4 values and real TLS
session resumption as a side effect.

### The API server first — the client is useless without it

The client connects to the API by REST and SignalR and has **no offline mode**. If no API is listening,
the client runs and generates nothing.

Docker route:

```bash
git clone https://github.com/cmu-sei/GHOSTS.git && cd GHOSTS
docker compose up -d           # API, UI, Postgres, Grafana
```

From source, if you would rather not run Docker:

```bash
# Ghosts.Api targets .NET 10 - install the matching SDK, not whatever is newest in apt
wget https://dot.net/v1/dotnet-install.sh
chmod +x dotnet-install.sh && ./dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet
export DOTNET_ROOT=/usr/share/dotnet
export PATH=$PATH:$DOTNET_ROOT
dotnet publish src/Ghosts.Api -c Release -o /opt/ghosts-api
```

```bash
# Postgres: Debian's template1 is SQL_ASCII, which breaks GHOSTS' UTF8 expectations
sudo -u postgres createdb -O ghosts -E UTF8 -T template0 \
  --lc-collate=C.UTF-8 --lc-ctype=C.UTF-8 ghosts
```

> **`dotnet-install.sh` reports success and can leave you with no `dotnet` on PATH** — it edits only the
> current process environment and never sets `DOTNET_ROOT`. Export both yourself and add them to the
> service unit.

### Client and timelines

`C:\ghosts\x64\config\application.json` points at the API:

```json
{ "ApiRootUrl": "http://<GHOSTS_API_IP>:5000/api" }
```

`timeline.json` defines what the simulated user does. Use `UtcTimeOn` / `UtcTimeOff` on each handler for
the diurnal window — this is GHOSTS' native scheduling and needs no external cron:

```json
{
  "TimeLineHandlers": [
    { "HandlerType": "BrowserFirefox", "UtcTimeOn": "08:00:00", "UtcTimeOff": "18:00:00",
      "TimeLineEvents": [
        { "Command": "browse", "CommandArgs": ["https://intranet.<ZONE>/"],
          "DelayAfter": 30000, "Loop": "True" } ] },
    { "HandlerType": "Command", "UtcTimeOn": "08:00:00", "UtcTimeOff": "18:00:00",
      "TimeLineEvents": [ { "Command": "nltest", "CommandArgs": ["/dsgetdc:<DOMAIN>"], "Loop": "True" } ] }
  ]
}
```

Author **per-role timelines** — finance, IT, executive, developer — and assign them with machine groups
so a role is defined once and applied to many machines.

> **Run the client as a regular user, not SYSTEM.** `CreateProcessWithLogonW` cannot be called from
> LocalSystem, so anything credential-based fails from a SYSTEM-run client.

### Making logons realistic

Drive interactive logons so "unusual logon" detection has a baseline. `LogonUser()` from a SYSTEM context
produces a genuine 4624 without needing a spawned process or stored task passwords:

- Type **2** interactive, type **3** network, type **7** unlock all work.
- Type **4** (batch) fails with 1385 unless you grant `SeBatchLogonRight` — and a failed `LogonUser`
  emits a 4625 that pollutes your deliberate failure signal.
- Type **11** (cached) is not a requestable value; it only occurs organically.

**Assign a small stable set of users to each workstation** rather than logging every account in
everywhere. Uniform any-user-anywhere makes anomalous-logon detection *impossible* — nothing can be
unusual when everything appears everywhere. Give each host 1–3 primaries plus an occasional visitor, and
the rarity of the visitor becomes the signal.

---

## 14. Verification — the gates

Do not mark a phase done without a measurement. Each of these is a query, not an opinion.

| # | Gate | How |
|---|---|---|
| 1 | Every guest reports | `logs-*` has docs for each `host.name`, ≥5,000 Windows events/host/day |
| 2 | Command line present | a deliberate `whoami` yields 4688 **with** `process.command_line` and Sysmon EID 1 |
| 3 | Sysmon in band | EIDs 1, 3, 10, 11, 22 all present; **5,000–10,000 per endpoint per day** |
| 4 | Client diversity | ≥60 unique JA3, none >25%; ≥80 user agents, none >20% |
| 5 | Diurnal shape | peak/trough 5–20×, peak inside business hours, distinct weekend shape |
| 6 | Segment attribution | `vlan` field populated in `zeek.conn`, multiple VLANs present |
| 7 | Connection health | `SF` ≥85%; failure rate inside the 5–15% enterprise band |
| 8 | Cross-source pivot | an account seen in the SIEM resolves to an HR record with department and manager |

Two disciplines that matter more than any individual gate:

**Measure over a window that starts strictly after the change.** Compute the window from the change
timestamp and refuse to measure if too little time has elapsed. Measuring across a change is the single
easiest way to produce a confident wrong answer.

**Check `by host` before attributing volume to the range.** Your own tooling generates telemetry. A
sensor that queries itself with `sudo` per query, or an admin loop that opens a fresh SSH connection per
command, can dominate a module's volume — and it will look like a range problem.

---

## 15. Traps, in the order you will hit them

**Networking**

- `tc mirred` to a **bridge master** does not flood to bridge members. Mirror into a **veth** whose peer
  is a bridge port. Symptom: a mirror that reports success and delivers zero packets.
- A SPAN bridge must have **MAC learning off** (`ageing_time 0`), or unicast is learned toward one port
  and never reaches the sensor.
- Set jumbo MTU with **`post-up`**, not inside the `iface` stanza — the in-stanza form is ignored on some
  ifupdown2 versions and the bridge silently stays at 1500.
- The sensor's **monitor interface needs MTU 9000** as well, or you get truncation that looks like loss.
- **Disable checksum offloading** on the monitor interface or Zeek reports permanent `capture_loss`.
- In OPNsense's `config.xml`, Unbound lives under `<OPNsense><unboundplus>`, not `<unbound>`.

**Security Onion / Elastic**

- SO **firewalls everything**; use `so-firewall includehost` + `apply` before enrolling anything.
- Elasticsearch is **HTTPS on 9200**; use `-sSk -K /opt/so/conf/elasticsearch/curl.config`. Plain HTTP
  returns empty under `-s` and reads as "no data".
- SO uses **its own field names**. Zeek datasets are `zeek.conn`, `zeek.http`, … — filtering on a bare
  `conn` silently returns zero. HTTP URI is `http.uri` (not `url.path`), user agent is `http.useragent`
  (one word), JA3 is `hash.ja3` and lives on `zeek.ssl` records, DNS query is `dns.query.name`, and
  Windows security events arrive with `event.module: system`.
- `host.name` is **lowercase** in ES even when the guest reports otherwise.
- Enrolment tokens are **base64** — never `cut -d=`.
- The Windows service is **`"Elastic Agent"`**, with a space.
- Customise ingest through the documented **`logs-<dataset>@custom`** pipeline. Never edit a shipped
  pipeline; it will be overwritten on upgrade.
- In `_simulate` output, a **dropped document is a bare `null` array element** — not `{"doc": null}`.

**Windows**

- On **Server SKUs**, `SysMain` **deletes** `EnablePrefetcher` when it starts, so Prefetch never
  populates and a reboot makes it worse. Use Windows 10/11 media if you want Prefetch artifacts.
- `qm guest cmd <id> ping` prints **nothing** on success.
- 5136 needs the subcategory **and** a SACL that covers user writes; read
  `InheritanceType`/`ObjectType`/`InheritedObjectType` on an audit ACE, not just rights and flags.
- 4738 fires for SAM-level changes; ordinary directory attributes (`department`, `title`, `mail`,
  `manager`) produce **5136**, not 4738. "I wrote N objects" is never evidence that "N events exist".
- **Never use `Administrator` as a test subject.** It is AdminSDHolder-protected and carries an explicit
  broad audit ACE that ordinary users lack, so it audits when nothing else does — the least
  representative object in the domain.
- Allow **≥15 seconds** for a Security event to appear before concluding it did not fire.

**Linux / auditd**

- A single invalid audit field **collapses the entire ruleset** to "No rules". Always check
  `auditctl -l | wc -l` after loading.
- `comm=` is not a valid filter field; `exe=` compares device+inode and is **blind to containers**.
- A child that reads stdin (`incus exec`, `mysql`, `ssh`, `sudo -S`) will **consume the rest of a script
  piped over stdin** and execution stops mid-file with no error. Give such children `</dev/null`.

**Discipline**

- Verify **effective** state, not declared state. `auditpol` reporting *Success* is a claim; a matching
  event in the log is the fact.
- A gate that passes for the wrong reason is worse than no gate. State each condition separately with an
  explicit PASS/FAIL rather than printing one number and a verdict.
- Never size a "% of telemetry" claim from a window that contains your own bulk activity.
