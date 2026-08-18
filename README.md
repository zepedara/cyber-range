# Cyber Range

One enterprise, defined once as data, rendered twice — as a container edition and a VM
edition — producing hunt-grade telemetry across network, endpoint, identity, and
application tiers, with a controllable attack platform that reaches the estate through a
pivot server rotating over a shared pool of benign-looking domains.

Built for threat-hunting practice. Runs on Proxmox.

## Status

**Built and producing telemetry.** The range runs on two hypervisors, mirrors every VLAN to a
Security Onion sensor, and carries an instrumented Windows domain alongside a ~30-container Linux
edition of the same company.

- **[`docs/superpowers/plans/2026-08-18-build-the-range-on-c240m4.md`](docs/superpowers/plans/2026-08-18-build-the-range-on-c240m4.md)**
  — **START HERE if you are building this yourself.** A full build plan for a single Cisco UCS
  C240 M4 (24-thread Xeon, 384 GB RAM), with sizing for that hardware, every verification query,
  and an appendix of the traps that cost the first build real time.
- **[`docs/VERIFIED_STATUS.md`](docs/VERIFIED_STATUS.md)** — measured state of every step, with the
  numbers behind each gate and explicit corrections where something was previously claimed without
  measurement.
- **[`docs/BUILD_FROM_SCRATCH.md`](docs/BUILD_FROM_SCRATCH.md)** — build the whole thing yourself using
  native commands and upstream packages, depending on none of the scripts here.
- **[`docs/superpowers/specs/2026-08-14-unified-cyber-range-design.md`](docs/superpowers/specs/2026-08-14-unified-cyber-range-design.md)** — the original design.

Current headline gaps: Sysmon volume runs 2–5× above the 5,000–10,000/endpoint/day target, the
"workstations" are Server 2022 images (so Prefetch artifacts are unobtainable), Office is not installed
anywhere, and adversary emulation is deliberately deferred until the benign baseline is finished.

## The idea

Two earlier projects informed this one. [tiger-team-defense](https://github.com/Icarus4122/tiger-team-defense)
contributed the service catalogue, the internal CA and generated-domain infrastructure,
and the fake-external segment. [lab-env](https://github.com/zepedara/lab-env) contributed
the diurnal traffic model, idempotent change scripts, and — most usefully — the
discipline of measuring every exercise rather than asserting it works.

What is new here:

- **The estate is data.** Hostnames, addresses, roles, users, and domains live in YAML.
  Scripts read the estate; they never contain it. That is what makes two editions
  possible without drift, and migration to different hardware a re-render.
- **Coverage is measured.** Four gates: a demand model built from ATT&CK, a declared
  supply model generated from the rendered estate, static analysis of which detection
  rules *cannot* fire given the deployed logging, and empirical proof via executed
  technique tests asserting that required fields are actually populated.
- **The attack platform is controllable.** Live C2 and ATT&CK emulation rather than
  replayed captures, so beacon interval, jitter, protocol, and technique are parameters —
  and the traffic is internally coherent, because the domain in DNS is the domain in the
  TLS handshake is the name on the certificate.
- **Rotation is an anti-memorization control.** One domain pool serves both benign
  browsing and command-and-control, so the pool can never become the indicator. Finding
  the malicious traffic requires hunting behaviour, not recognizing a naming pattern from
  last session.

## Layout

```
estate/      the enterprise, as data
render/      materializes it as containers or VMs
roles/       one directory per host role, edition-agnostic
noise/       diurnal traffic generation
attack/      pivot, domain rotation, C2, ATT&CK emulation
```

**Status of that layout, measured 2026-08-18:** only `noise/`, `tools/`, `migration/` and `docs/`
exist. **`estate/`, `render/`, `roles/` and `attack/` are NOT YET BUILT.** The first build wrote the
enterprise into scripts and host state rather than into data, so the range runs and produces good
telemetry but cannot be reproduced from this repository — the exact failure the design spec warned
about when it described `lab-env`. Part 9 of the build plan above covers doing it properly, and a
greenfield build is the right moment to fix it.

```
telemetry/   mirroring, agents, ingest pipelines
measure/     the coverage gates and exercise scoring
docs/        specs and runbooks
```

## Credentials and site configuration

The intent is that real hostnames, addresses and credentials live in `site.env`, which is gitignored,
and everything in the repository refers to placeholders.

> ⚠️ **That intent is currently violated.** This repository is **public**, and
> `noise/containers/rangenoise.sh` contains a lab credential in its committed form. Treat every range
> password as compromised and rotate it. Documentation added since is placeholder-only, and
> `docs/BUILD_FROM_SCRATCH.md` supplies no credentials at all — but the history still holds the
> exposed value, so rotation is the only real fix.

## Scope

Built for an isolated lab and a single operator. Nothing here is intended for production.
