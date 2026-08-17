# Tools

Working scripts from the build. Each one is documented inline with *why* it exists and what it measured,
because most of them were written in response to a specific measured defect.

**None of these are required.** [`docs/BUILD_FROM_SCRATCH.md`](../docs/BUILD_FROM_SCRATCH.md) builds the
same range with native commands only. These exist because doing it by hand across 2,400 directory objects
and 30 containers is tedious, not because the range depends on them.

## Credentials

Every embedded credential has been replaced with a `${PLACEHOLDER}`. Supply them from `site.env`
(gitignored) or your environment before running anything:

| Placeholder | What it is |
|---|---|
| `${SO_PASSWORD}` | Security Onion admin/sudo password |
| `${RANGE_USER_PASSWORD}` | shared password for the simulated workforce accounts |
| `${GHOSTS_DB_PASSWORD}` | Postgres password for the GHOSTS API |
| `${GHOSTS_ADMIN_PASSWORD}` | GHOSTS API admin password |
| `${APPSVC_PASSWORD}` | MariaDB application-service account |
| `<COMPANY_NAME>` | the fictional company name used in AD `company` |

## `ad/` — identity realism

| Script | Purpose |
|---|---|
| `fix-names-and-clean-service-accounts.ps1` | BadBlood sets **no** `givenName`/`sn`/`displayName`. This derives them from the `FIRST_LAST` sAMAccountName convention and assigns clean `first.last@` mail with a numeric suffix only on collision. Also strips HR attributes from service-shaped accounts (digits / `SA` suffix) that were mis-classed as people because they carry no SPN. |
| `populate-hr-attributes.ps1` | Adds department, title, company, office, city, phone and a real **manager chain** (IC → Manager → Director → VP → CEO). Deliberately leaves ~3% without a title, ~4% without a manager and ~7% without a phone — uniform completeness is a generated-data tell. Idempotent; skips users that already have a department. |
| `verify-hr-population.ps1` | The gate. Five named PASS/FAIL conditions, re-read from AD rather than trusting the writer's own count, including whether the org chart is actually **traversable**. |
| `enable-directory-change-auditing.ps1` | Makes 5136 work. Adds the audit ACE the default SACL does not provide (`Everyone` / `WriteProperty` / `Success` / `Descendents` / user class), then proves it with a real attribute write. Auditing only — grants no access. Revert is `RemoveAuditRule` + `Set-Acl`. |

## `db/` — business data

| Script | Purpose |
|---|---|
| `load-corpdb-from-ad.py` | Rebuilds `corpdb.employees` so the HR database and the directory describe the **same people**, adds `sam_account_name` as the join column, and populates `manager_id` (which BadBlood-era data leaves entirely NULL). Generated tenure and salary correlate with seniority. Backs the old table up to `employees_bak_<date>` first, and refuses to run if the export looks wrong. |

## `windows/`

| Script | Purpose |
|---|---|
| `assign-per-host-users.ps1` | Gives each workstation a stable set of assigned users derived from its own hostname, plus 10% visitor logons from outside the set. Without this, every account logs into every host and **no logon can ever be anomalous**. Idempotent, and refuses to install unless the patched script parses. |

## `audit/`

| Script | Purpose |
|---|---|
| `sysmon-volume-gate.sh` | The plan's real Step 3 gate: are Sysmon EIDs 1/3/10/11/22 present, **and** is volume inside 5,000–10,000 per endpoint per day. Also checks the Step 1 threshold. Currently 1 of 6 endpoints is in band. |
| `workstation-realism-audit.ps1` | Profile count and size distribution, browser-history presence, installed-software fingerprint (to detect byte-identical clones), Prefetch count and free disk. |

## A note on gates

Several of these refuse to run if too little time has elapsed since a change. That is deliberate.
Measuring across a change is the fastest way to produce a confident wrong answer, and it happened
repeatedly in this project before the guards were added.
