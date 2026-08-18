# Phase 1.1 — external dependency audit

Measured 2026-08-18 ~11:40Z, read-only, from cthost01 across all 32 containers.

## Verdict

The container estate is **almost** self-contained. One real dependency, one class of false
positive, and one thing that could not be verified.

## 1. REAL — ✅ FIXED AND VERIFIED 2026-08-18 ~11:48Z

| Guest | File | Line | Finding |
|---|---|---|---|
| `extdns01` | `/etc/dnsmasq.d/range.conf` | 15 | `server=192.168.1.1` — forwarded to the **house Firewalla** |

**Fixed:** line commented out. Backup at `/root/range.conf.bak-premigration` — deliberately NOT in
`/etc/dnsmasq.d/`, because conf-dir reads every file there and a stray `.bak` loads as config
(that exact mistake took dc01 down on 2026-08-16).

Verified, in order: `dnsmasq --test` → "syntax check OK" **before** restarting; service `active`
after; and the control lookup is **unchanged** across the change —
`update-manifest-svc.net → 10.30.30.10`, both from a client (`wk01`) and on `extdns01` itself.
Active house forwarders now **0 on dc01 and 0 on extdns01**.

`no-resolv` is set (range.conf:14 and zz-no-upstream.conf:2), but **`no-resolv` only stops dnsmasq
reading `/etc/resolv.conf` — it does not cancel an explicit `server=` directive**, and dnsmasq
accumulates `server=` lines across conf-dir files. So this forwarder is live.

It is currently harmless *only because egress containment drops it*. In the rack, 192.168.1.1
does not exist at all. This is config that "works by being blocked" — precisely what Phase 1
exists to catch.

**Action:** remove or re-point line 15 before packaging. `extdns01` is the range's *external*
DNS persona, so the correct target is the internal fake-internet resolver, not a house address.

## 2. FALSE POSITIVES — no action

Every container matched on two stock Debian files:

- `/etc/dhcp/dhclient-exit-hooks.d/rfc3442-classless-routes`
- `/etc/ssl/openssl.cnf`

Both contain example/documentation addresses shipped by the distro. 16 of the 192.168.1.1
references estate-wide resolve to these. Do not "fix" them.

## 3. CLEAN — verified good

- `dc01` — no active house reference; `no-resolv` in both `range.conf:7` and
  `zz-no-upstream.conf:2`. It is the range's primary resolver and is self-contained.
- Container `resolv.conf` is range-internal on every host checked
  (`wk01`, `app01`, `mail01`, `proxy01` → `10.30.10.10`; `dc01` → `127.0.0.1`, correct since it
  *is* the resolver).
- `dc01` NTP → `10.30.10.10` (internal).

## 3b. HOST-LEVEL sweep (fw01 + cthost01) — measured ~11:55Z

These sit outside `qm config` and were the last blind spot.

### fw01 — one inert config item, otherwise clean

| Item | Value | Verdict |
|---|---|---|
| system DNS | `10.30.10.10` | ✅ internal |
| NTP config | `0-3.opnsense.pool.ntp.org` | ⚠️ public pool **but inert** |
| house refs | `192.168.1.146`, `192.168.1.1`, `192.168.1.0` (3 total) | `.146` is **so01**, which the plan preserves |
| WAN | `vtnet1`, `dhcp` | decided by blocking question 3 |
| VLAN ifs | 18 = 9 VLANs × 2 editions (5/10/20/30/40/45/60/70/99 + 01xx) | matches design |

**The NTP entries are already dead.** `ntpq -pn` shows all four peers at `reach 0` — containment has
never let a packet through — and `stratum=12, refid=127.0.0.1` means fw01 disciplines itself from its
own local clock. That is why the domain chain measures stratum 12-13-14. So fw01 already behaves as a
self-contained time root; clean the config for honesty, but it is **not** a migration blocker.

### cthost01 — TWO REAL dependencies, must be fixed

| Item | Value | Impact in the rack |
|---|---|---|
| DNS uplink | `192.168.1.1` (house Firewalla) | container host loses name resolution |
| NTP | `51.81.226.229` = `0.debian.pool.ntp.org`, **Stratum 3, synchronized: yes** | host clock drifts |

Unlike the range containers, cthost01 sits on the mgmt bridge (`10.20.0.60`, default route
`10.20.0.1`) with NAT out, so it genuinely reaches the house LAN and the internet **today**. Both
disappear in the rack. This matters more than it looks: cthost01 runs all 30 containers and its
journald timestamps feed the SIEM, so a drifting host clock corrupts cross-host correlation — the
same class of failure as the 7-hour Windows skew.

**Action:** point cthost01 DNS at `10.30.10.10` and NTP at fw01 before packaging.

## 4. NOT VERIFIED — do not assume

- **Live forwarding behaviour.** The probe (`dig`/`getent` from `wk01`) returned nothing because
  `dig` is not installed in the containers, so it neither confirms nor refutes self-containment.
  Re-test from a host that has a resolver client before signing Phase 1 off.
- **NTP on non-dc01 containers** reports `<none>` — meaning no timesyncd/ntp/chrony config was
  found, not that time is unmanaged. Worth confirming how those containers get time, since the
  rack has no house NTP either.
- **Windows guests not yet audited** (Task 1.1 Step 2). Build history records the golden image
  carried house DNS, RustDesk, Elastic and GHOSTS endpoints; `WEB01` was cleaned, the others
  need checking via `qm guest exec`.
- **fw01 and cthost01 host-level** config not yet swept — the 9-VLAN matrix and any upstream
  DNS/NTP on the firewall live there, not in `qm config`.
