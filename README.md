# Cyber Range

One enterprise, defined once as data, rendered twice — as a container edition and a VM
edition — producing hunt-grade telemetry across network, endpoint, identity, and
application tiers, with a controllable attack platform that reaches the estate through a
pivot server rotating over a shared pool of benign-looking domains.

Built for threat-hunting practice. Runs on Proxmox.

## Status

Design phase. See [`docs/superpowers/specs/2026-08-14-unified-cyber-range-design.md`](docs/superpowers/specs/2026-08-14-unified-cyber-range-design.md).

Nothing is deployed yet.

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
telemetry/   mirroring, agents, ingest pipelines
measure/     the coverage gates and exercise scoring
docs/        specs and runbooks
```

## Credentials and site configuration

None are committed. Real hostnames, addresses, and credentials live in `site.env`, which
is gitignored. Everything in the repository refers to placeholders.

## Scope

Built for an isolated lab and a single operator. Nothing here is intended for production.
