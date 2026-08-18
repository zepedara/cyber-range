# Remote access tiers for a consulting builder

A second Claude Code session building its own copy of this range often needs to know something about
the **reference** environment. This directory implements a tiered answer to that, from zero risk to
least-privilege live access.

**Two Claude Code sessions cannot talk to each other.** There is no agent-to-agent channel. What
follows gives a remote session access to *answers about the environment*, relayed through its
operator.

---

## The threat model that shapes all of this

The remote peer is an **AI agent that reads untrusted content** — repositories, documentation, web
pages. If a page it reads contains text shaped like an instruction, the agent may act on it.

**Assume that anything the remote agent can execute, an attacker who influences it can also
execute.** That is the entire reason Tier 1 grants *verbs* rather than a shell, and why Tier 0 is
the recommended default.

---

## Tier 0 — published snapshot (default, zero attack surface)

A sanitized, point-in-time capture of the estate, committed to the repo. No live access, no account,
no open port, nothing to attack.

```bash
ssh <hypervisor> 'bash -s' < tools/access/publish-snapshot.sh > docs/ENVIRONMENT_SNAPSHOT.md
git add docs/ENVIRONMENT_SNAPSHOT.md && git commit -m "Refresh environment snapshot"
```

`publish-snapshot.sh` is read-only and **redacts house LAN and tailnet addressing** while keeping
range-internal `10.x` addressing, which is the useful part. Verify redaction before committing:

```bash
grep -cE '192\.168\.[0-9]+\.[0-9]+|100\.[0-9]+\.[0-9]+\.[0-9]+' docs/ENVIRONMENT_SNAPSHOT.md   # expect 0
```

This answers most questions a remote builder will have: estate layout, guest sizing, bridges, VLANs,
storage, container inventory. **Try this before considering Tier 1.**

---

## Tier 1 — read-only enumeration over Tailscale (only if Tier 0 is insufficient)

Two scripts, installed on the Proxmox host:

| Script | Role |
|---|---|
| `range-enum` | SSH **forced-command** wrapper. Implements an allowlist of read-only verbs. |
| `range-access` | One-command `enable` / `disable` / `status` / `test`. |

### Security properties

- **Transport is Tailscale only.** No port is opened, no firewall rule is added, nothing is
  forwarded or exposed to the internet.
- **The account is unprivileged and has no shell** (`/usr/sbin/nologin`).
- **The key is pinned to a forced command.** sshd runs `range-enum` no matter what the client asks
  for. The client cannot choose the command.
- **No client string is ever evaluated by a shell.** The only verb taking an argument
  (`guest-config`) validates it as digits first.
- **Everything is logged** to syslog with the peer address, allowed or denied.
- **Revocation is one command** and takes effect immediately.

### Operating it

```bash
range-access status                                   # is it live? which keys? recent activity?
range-access test                                     # PROVE the restriction restricts
range-access enable 'ssh-ed25519 AAAA... their-key'   # paste THEIR PUBLIC key (never a private key)
range-access disable                                  # revoke instantly
```

**Always run `range-access test` before enabling.** It asserts that an allowlisted verb works, that
`rm -rf /` is refused, and that argument injection (`guest-config 170; id`) is refused. If any check
fails it exits non-zero and tells you not to enable access.

### Verbs available to the remote peer

`host-summary`, `guest-list`, `guest-config <id>`, `bridge-list`, `span-check`, `storage-list`,
`zfs-status`, `container-list`, `vlan-coverage`, `siem-health`, `siem-datasets`, `gates-latest`,
`help`.

All read-only. There is deliberately no `qm set`, no `pct exec`, no `incus exec`, and no shell.

---

## Tier 2 — MCP over Tailscale (not built)

An MCP server exposing the same verbs as tools, with Bearer-token auth over Tailscale. Better
ergonomics for an agent than SSH; the same risk profile as Tier 1. Only worth building if the remote
session queries the environment constantly. Tier 1 covers occasional use at a fraction of the work.

---

## Hardening noted during the audit (independent of remote access)

Both were found while auditing the host and are worth fixing regardless:

- `sshd` has `PasswordAuthentication yes`. Consider disabling it in favour of keys.
- NFS (2049) and rpcbind (111) listen on `0.0.0.0` on the hypervisor that runs the range.
