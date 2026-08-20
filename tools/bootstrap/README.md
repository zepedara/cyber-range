# Remote build-host bootstrap — staying reachable on hostile networks

A package that installs Claude Code plus a connection stack designed to survive the networks
you actually get in a rack, a lab, or behind a restrictive enterprise/government perimeter.

| File | Target |
|---|---|
| `range-bootstrap.ps1` | **Windows laptop / build workstation** |
| `range-bootstrap.sh` | Debian/Ubuntu, Proxmox VE host, LXC or VM |
| `linkwatch.sh` | Linux watchdog (installed by the `.sh`) |

---

## Why this exists

On 2026-08-19 a Windows build workstation lost its lab NIC three times in one day. On the third,
Tailscale went **flat-dead** — `Online: False`, `LastHandshake: 0001-01-01`, `rx 0` — at an exact
hour boundary. With one path there was no way in *and no way to see why*.

Root cause of the earlier two was a routing bug, not hardware: `10.10.1.0/24` was on-link on a **USB
adapter that was not attached to that switch**, so Windows sent all lab traffic out the wrong NIC.

Two distinct failures, and the package addresses both:
- **You cannot get in** → multiple independent paths, ranked by what survives restrictive networks.
- **You cannot see why** → an outbound-only beacon that works when nothing else does.

---

## ⚠️ Read this before trusting the second path

**WireGuard is UDP-only. On a restrictive network it will simply not work.**

This is the most important finding in this document, and it reverses the obvious design. A
home-router VPN feels like the natural backup path — but UDP is the first thing a hardened
perimeter blocks. WireGuard has no TCP mode.

**Tailscale, by contrast, survives** because DERP relay traffic is carried over **HTTPS on TCP 443**.
When UDP is filtered it falls back to relaying, at the cost of latency, and keeps working.
([Tailscale firewall docs](https://tailscale.com/docs/reference/faq/firewall-ports),
[connection types](https://tailscale.com/docs/reference/connection-types))

So rank your paths by what actually survives:

| Tier | Path | Transport | Survives UDP block? | Survives HTTPS-only + proxy? |
|---|---|---|---|---|
| 1 | Tailscale (DERP fallback) | TCP 443 | **Yes** | Usually — see proxy caveat |
| 2 | ntfy beacon / channel | TCP 443 | **Yes** | **Yes** |
| 3 | Tailscale direct | UDP 41641 | No | No |
| 4 | WireGuard to home router | UDP | **No** | **No** |

**Do not rely on WireGuard as your only backup on a restricted network.** Keep it for
permissive sites, where it is genuinely useful and faster.

---

## Firewall allowlist — the minimum that must be open

### Tailscale
```
TCP  443   →  *                    control plane + DERP relays (REQUIRED)
TCP  80    →  *                    captive-portal detection, control preference
UDP  41641 →  *                    direct WireGuard tunnels (optional, for performance)
UDP  3478  →  *                    STUN, NAT type discovery (optional)
```
Hostnames, if the perimeter filters by name rather than address:
```
controlplane.tailscale.com
login.tailscale.com
console.tailscale.com
log.tailscale.com
derp1-all.tailscale.com  …  derp28-all.tailscale.com
```
**With only TCP 443 open, Tailscale still works** — every connection relays through DERP.

### Claude Code
All HTTPS on 443:
```
api.anthropic.com        the API
claude.ai                sign-in
platform.claude.com      sign-in
downloads.claude.ai      installer
```
([Anthropic network config](https://code.claude.com/docs/en/network-config.md))

---

## Working behind a proxy or TLS inspection

### Claude Code
Supports `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY`. **SOCKS proxies are not supported** — HTTP and
HTTPS only. For proxies requiring **NTLM or Kerberos**, the documented path is to put an LLM gateway
in front rather than fight the auth.

Claude Code does **not pin certificates**, so it works through full TLS inspection once it trusts
your root CA:
```powershell
setx NODE_EXTRA_CA_CERTS "C:\path\corp-root-ca.pem" /M
setx HTTPS_PROXY "http://proxy.corp.example:8080" /M
```
```bash
export NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/corp-root-ca.crt
export HTTPS_PROXY=http://proxy.corp.example:8080
```

**Never set `NODE_TLS_REJECT_UNAUTHORIZED=0`.** It disables verification globally and is the wrong
fix for a certificate error.

**The subtle one that will bite you:** Claude Code streams responses over **long-lived HTTPS (SSE)**,
not WebSocket. If the proxy buffers responses or applies a short idle timeout, streamed replies stall
or truncate mid-output — and it looks like a model problem, not a network one. Ask for streaming
connections to be exempted from buffering and given a generous idle timeout.

### Tailscale
Proxy support is **partial and worth knowing precisely**: `HTTP_PROXY` / `HTTPS_PROXY` affect
`tailscaled`'s connection to the **control plane only**, not tunnelled data.
([#11053](https://github.com/tailscale/tailscale/issues/11053),
[#10235](https://github.com/tailscale/tailscale/issues/10235) — `tailscaled` does not read the
user's shell environment or `/etc/environment`, so set it in the **service unit**,
[#17698](https://github.com/tailscale/tailscale/issues/17698) — Windows proxy bugs)

On Linux, set it where the daemon will actually see it:
```bash
mkdir -p /etc/systemd/system/tailscaled.service.d
cat > /etc/systemd/system/tailscaled.service.d/proxy.conf <<'EOF'
[Service]
Environment="HTTPS_PROXY=http://proxy.corp.example:8080"
Environment="NO_PROXY=localhost,127.0.0.1,10.0.0.0/8"
EOF
systemctl daemon-reload && systemctl restart tailscaled
```

**If the perimeter blocks Tailscale entirely** (SNI filtering on `*.tailscale.com`), the ntfy beacon
on 443 to an unrelated host is your remaining channel — which is precisely why tier 2 exists and why
it is not optional.

---

## What the beacon is, and what it deliberately is not

`phone-home` / `RangePhoneHome` posts host status outbound every 15 minutes: uptime, Tailscale state
and IP, WireGuard state, which links are up, and default routes with metrics.

It is **outbound-only by design**. It is *not* a command channel, and you should resist making it
one: a public topic that executes commands is remote code execution for anyone who guesses the
topic name. Status out is safe; commands in are not. If you need inbound control, use Tailscale
SSH or an authenticated tunnel — not a public pub/sub topic.

This is the component that kept working through the entire 2026-08-19 outage while SSH, the lab
NIC and eventually Tailscale itself all failed.

---

## Usage

### Windows (elevated PowerShell)
```powershell
.\range-bootstrap.ps1 -Check                       # report only, changes nothing
.\range-bootstrap.ps1 -TsAuthKey "tskey-auth-…" -NtfyTopic "yourtopic"
.\range-bootstrap.ps1 -TsAuthKey "…" -NtfyTopic "…" `
                      -SshPubKey "ssh-ed25519 AAAA… you@host" `
                      -WgConf C:\path\home.conf
```

### Linux / Proxmox
```bash
sudo ./range-bootstrap.sh --check
sudo TS_AUTHKEY=tskey-auth-… NTFY_TOPIC=yourtopic ./range-bootstrap.sh
sudo TS_AUTHKEY=… ./range-bootstrap.sh --with-wireguard /root/home-wg0.conf
linkwatch --selftest      # verify the watchdog without changing anything
```

Both are idempotent — safe to re-run.

---

## Windows specifics that cost people hours

- **Admin SSH keys do not live in `~\.ssh\authorized_keys`.** For any account in the Administrators
  group they must be in `C:\ProgramData\ssh\administrators_authorized_keys`, with inheritance removed
  and only `SYSTEM` and `BUILTIN\Administrators` granted. Put the key in the wrong file and sshd
  ignores it silently.
- **`tailscale up --unattended`** is required on an unattended box. Without it Tailscale disconnects
  when the user logs out, which kills remote access with no obvious cause.
- **Fast Startup breaks Wake-on-LAN.** The script disables `HiberbootEnabled`.
- **Multi-WAN route metrics decide your path**, and an unattached USB adapter can win. This caused
  the original outage. Pin it:
  ```powershell
  Get-NetRoute -DestinationPrefix 0.0.0.0/0 | Format-Table ifIndex,InterfaceAlias,RouteMetric
  New-NetRoute -DestinationPrefix "10.10.1.0/24" -InterfaceIndex <LAB_IF> `
               -NextHop <LAB_GW> -RouteMetric 1 -PolicyStore PersistentStore
  Test-NetConnection <lab-host> -TraceRoute    # confirm it leaves the intended adapter
  ```

## PRE-AUTHORISATION CHECKLIST — do all of this BEFORE you go on site

The assumption here is the hard one: **on site you will have no phone, no browser,
and no way to complete an interactive login.** Anything that would prompt for auth
must be provisioned in advance, or the host is dead on arrival.

Four things can prompt. Three are solvable now; one only you can do.

### 1. Claude Code auth — SOLVED, and verified

Claude cannot complete an OAuth login on a headless host. An **API key** authenticates
with no interaction at all.

```bash
# stage it, root-only, on the target
install -m 600 -D /path/to/keyfile /etc/range/anthropic.key
```

`claude-connect` reads `/etc/range/anthropic.key`, then `~/.claude/.overflow_key`,
exports `ANTHROPIC_API_KEY`, and never echoes the value. It refuses to proceed
silently if neither a key nor cached credentials exist — better a clear warning
than an interactive prompt nobody can answer.

**Verified working:** a staged key returned `HTTP 200` from `api.anthropic.com`, so
this path needs no login whatsoever.

⚠️ **Cost:** an API key bills that key's account directly rather than a
subscription. That is the price of working without a login — budget for it, and
consider a cheaper default model for unattended work.

### 2. Tailscale — ONLY YOU CAN DO THIS, and it is the most likely thing to strand you

`tailscale up` **opens a browser for login** unless you supply a pre-authorised
auth key. The CLI on a node **cannot mint one** — it requires the admin console.

Create the key at `https://login.tailscale.com/admin/settings/keys` with:

| Setting | Value | Why |
|---|---|---|
| **Reusable** | **Yes** | A single-use key is consumed by one failed attempt and then you are stuck |
| **Expiry** | 90 days (max) | Note the date. An expired key fails exactly like a wrong one |
| **Pre-approved** | **YES if device approval is enabled on your tailnet** | ← **the trap.** With device approval on, a new node stays blocked until someone approves it **in the console** — which needs the login you do not have |
| **Ephemeral** | No | Ephemeral nodes vanish when they go offline; you want it to persist through outages |
| **Tags** | e.g. `tag:build` | Tagged nodes do not expire with your user session |

Then pass it in: `TS_AUTHKEY=tskey-auth-... ./range-bootstrap.sh`

**Check whether device approval is on before you leave.** If it is and your key is
not pre-approved, the host will connect to the control plane, be refused, and look
exactly like a network fault.

Also set **key expiry disabled** on the node afterwards, or it drops off the tailnet
in 180 days regardless.

### 3. SSH — already done, both directions

- Their key is authorised on the range hosts (`revoke-c240` reverses it).
- A dedicated keypair exists for reaching the build host; only the **public** half
  was ever transmitted.

Stage the private key on the target at `~/.ssh/id_ed25519` (mode 600) if the host
needs to initiate SSH home.

### 4. ntfy — no auth by design

The beacon posts to a public topic and needs no credential. That is deliberate: it
is the one channel that keeps working when every authenticated path has failed. It
is **outbound-only** and must never be made a command channel.

### Optional, if you want the extra rungs

- **WireGuard:** export a peer profile from the router **now** and stage it as
  `offline/wg0.conf`. Generating one on site needs router admin access.
- **sshd on 443 at home:** rung 7, one of the most reliably-open paths — but it
  needs an inbound port forward, so decide deliberately.
- **Custom DERP:** only if `*.tailscale.com` is SNI-blocked. Needs a domain and a
  cert, so build it before you need it.

### Pre-flight verification — run this before you travel

```bash
sudo ./range-bootstrap.sh --check          # confirms every artifact is staged
claude-connect --route                     # confirms a working route AND auth
tailscale status                           # confirms the node is authorised, not just connected
```

If `--check` reports a missing artifact or `claude-connect` cannot pick a route,
fix it **at home**. Every one of those failures is unrecoverable on site without
the login you will not have.

---

## When Anthropic itself is blocked

This is the hard case, and it is common on government and enterprise perimeters. If
`api.anthropic.com` is unreachable, **no tunnel out of the host helps by itself** — Claude Code
still has to reach Anthropic. The fix is to make its API traffic **egress from somewhere that
isn't blocked**, i.e. your home network.

Four options, best first.

### Option 1 — Don't run Claude on the restricted host at all (most robust)

Invert the problem. Run Claude Code **at home**, where Anthropic is reachable, and have it SSH into
the restricted host over Tailscale. The restricted side then needs **zero** Anthropic reachability —
it only needs to accept an SSH connection.

```bash
# from the home session
ssh root@<remote-tailscale-ip> 'commands…'
```

This is what the reference build did all session, and it never once hit an egress restriction.
Prefer it unless you specifically need Claude running locally on that box.

### Option 2 — HTTP proxy at home, reachable over Tailscale (best if Claude must run locally)

Claude Code supports `HTTPS_PROXY` (HTTP/HTTPS proxies only — **not SOCKS**). Run a plain proxy at
home bound **only** to its Tailscale address, and point the remote host at it. Only Claude's traffic
is proxied; everything else stays local.

At home:
```bash
apt-get install -y tinyproxy
# bind to the tailscale address ONLY - never 0.0.0.0
sed -i 's/^Listen .*/Listen <HOME_TAILSCALE_IP>/' /etc/tinyproxy/tinyproxy.conf
sed -i 's/^Port .*/Port 3128/' /etc/tinyproxy/tinyproxy.conf
systemctl restart tinyproxy
```
On the restricted host:
```powershell
setx HTTPS_PROXY "http://<HOME_TAILSCALE_IP>:3128" /M
setx HTTP_PROXY  "http://<HOME_TAILSCALE_IP>:3128" /M
setx NO_PROXY    "localhost,127.0.0.1,10.0.0.0/8,100.64.0.0/10" /M
```
Binding to the tailnet address matters: an open proxy on `0.0.0.0` is an abuse vector, and on a
lab network it is a lateral-movement gift.

### Option 3 — Tailscale exit node (simplest, heaviest)

Routes **all** traffic from the remote host through home, no per-app config.
([exit node docs](https://tailscale.com/docs/features/exit-nodes))

At home:
```bash
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.d/99-tailscale.conf
sysctl -p /etc/sysctl.d/99-tailscale.conf
tailscale up --advertise-exit-node
```
Approve the node in the admin console, then on the remote host:
```
tailscale up --exit-node=<HOME_TAILSCALE_IP> --exit-node-allow-lan-access
```
`--exit-node-allow-lan-access` is essential on a build host — without it you lose access to the
local lab subnet you are there to work on.

Trade-off: all traffic now traverses your home link, including large downloads, and your egress
becomes your home IP.

### Option 4 — When `*.tailscale.com` itself is blocked (SNI filtering)

Perimeters that block Tailscale usually do it with a **single SNI wildcard** against the DERP
subdomains. The counter is a **self-hosted DERP server on your own domain**, which is not on
anyone's blocklist. ([DERP servers](https://tailscale.com/docs/reference/derp-servers),
[Headscale DERP notes](https://headscale.net/stable/ref/derp/))

- Run `derper` on a host you control with a domain and a valid certificate.
- Add it to the tailnet policy file under `derpMap` with a **region ID in the 900–999 range**
  (that range is reserved for custom regions).
- Set **`OmitDefaultRegions`** so the client stops timing out trying to reach blocked default DERPs
  — without this, connections stall even though your custom relay works.
- **SNI pass-through** lets the same host serve DERP and normal web traffic on 443, so the endpoint
  looks like an ordinary website.

This is the deepest option and the most work. Reach for it only when 1–3 are genuinely unavailable.

### Quick decision guide

| What's blocked | Use |
|---|---|
| Nothing unusual | Direct — Tailscale + local Claude |
| `api.anthropic.com` only | **Option 1** (Claude at home) or **Option 2** (home proxy) |
| UDP blocked, 443 open | Tailscale DERP fallback — already automatic |
| All egress except 443 via proxy | Option 2 + set proxy on `tailscaled` service unit |
| `*.tailscale.com` blocked | **Option 4** — self-hosted DERP on your own domain |
| Everything but one HTTPS host | ntfy beacon on that host; treat it as your only channel |

---

## Out-of-band — the only thing that works when the OS is down

Everything above needs a booted OS with a network stack. When that is what failed, you need
out-of-band management:

- **Cisco UCS C240 M4 → CIMC.** Dedicated management NIC, remote power control and KVM independent
  of the host OS. Configure it, put it on a management network, and it answers when the host does
  not.
- A remotely switchable PDU achieves the same for power, without KVM.

Without one of these, recovery from a hard hang requires someone physically present — which is what
this whole package exists to avoid.

---

## Multi-WAN: using an independent carrier as your way out

The cleanest path off a restrictive line is a **different line you already own** — a
cellular puck, a second carrier, a hotspot. That is not a workaround; it is a
separate network with its own policy.

### The trap that makes this fail silently

**Windows selects routes by `interface metric + route metric`, lowest wins — and
"Automatic Metric" is ON by default, assigning metrics by LINK SPEED.**
([Microsoft](https://learn.microsoft.com/en-us/troubleshoot/windows-server/networking/automatic-metric-for-ipv4-routes))

So a 1 Gb lab NIC automatically beats a slower cellular puck, and Windows sends
internet traffic out the lab line whether you want it or not. The same mechanism
lets an unattached-but-linked USB adapter win the default route — which is exactly
how lab traffic left the wrong NIC in the 2026-08-19 outage.

### Windows

```powershell
.\wan-policy.ps1 -Show          # see metrics and which adapter owns 0.0.0.0/0
.\wan-policy.ps1 -InternetVia "Puck" -LabVia "Ethernet" `
                 -LabSubnets 10.10.0.0/16 -LabGateway 10.10.100.1
.\wan-policy.ps1 -Verify -LabSubnets 10.10.0.0/16
```

It disables Automatic Metric (or link speed silently overrides you), pins the
internet WAN as preferred, and pins lab subnets to the lab NIC with **specific
persistent routes** — a specific route beats a default route regardless of metric,
which is what keeps lab traffic on the lab line even though its metric is worse.

`-PolicyStore PersistentStore` matters: routes added without it vanish on reboot,
and a working split quietly reverts overnight.

### Linux / Proxmox — policy routing

`ip rule` decides *which* packets get special treatment; `ip route` populates the
table they point at. Rules are evaluated by priority, lowest first, first match wins.

```bash
# a named table
echo "100 wanpuck" >> /etc/iproute2/rt_tables

# default route for that table, out the cellular interface
ip route add default via <PUCK_GW> dev <PUCK_IF> table wanpuck

# send everything from this host out the puck...
ip rule add from <PUCK_IP> table wanpuck priority 100
# ...except lab subnets, which stay on the main table
ip rule add to 10.10.0.0/16 table main priority 50
```

**`ip rule` and `ip route` are NOT persistent.** Put them in a netplan `routing-policy`
stanza or a startup unit, or they are gone at the next reboot.

Verify the split actually holds — a route table that looks right and behaves wrong
is the failure mode that costs hours:

```bash
ip route get 1.1.1.1        # should leave via the puck
ip route get 10.10.1.1      # should leave via the lab NIC
```
