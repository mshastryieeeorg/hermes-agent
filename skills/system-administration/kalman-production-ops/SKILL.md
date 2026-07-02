---
name: kalman-production-ops
description: Use when operating, monitoring, or troubleshooting the Kalman production websites — kalmansystems.com.au (Kalman | Systems⁺) and kalman-systems.com.au (Kalman Commons). Covers error handling (uptime, HTTP errors, deploy failures), exception handling (Worker exceptions, D1 errors, Stripe webhook failures), and system administration (DNS, Cloudflare Pages/Workers deploys, D1 backups, secrets) on the shared Cloudflare account.
version: 1.0.0
author: Kalman | Systems⁺
license: MIT
platforms: [windows]
metadata:
  hermes:
    tags: [kalman, production, cloudflare, sysadmin, monitoring, error-handling]
    related_skills: [systematic-debugging]
---

# Kalman Production Operations

## Overview

Two production websites share one Cloudflare account (`a6bed40bd99b2dd2ef5716f9c270e5ca`).
This skill is the operating manual: what exists, where the source and credentials live,
and the runbooks for the three recurring task areas — **error handling**,
**exception handling**, and **system administration**.

| | kalmansystems.com.au | kalman-systems.com.au |
|---|---|---|
| Product | Kalman \| Systems⁺ (main company site) | Kalman Commons (membership network) |
| Source repo | `D:\GitHub\fluffy\Website\Website_Finished_13` | `D:\GitHub\cigars\site` |
| Pages project | `kalman-systems-website` | `kalman-commons` (preview: kalman-commons.pages.dev) |
| Worker | `kalman-requirements-api` | `kalman-commons-intake` (+ `-dev` env) |
| Worker URL | kalman-requirements-api.shastry-mahesh.workers.dev | kalman-commons-intake.shastry-mahesh.workers.dev |
| D1 database | `kalman_requirements` (`e7c676e8-481a-4213-88d9-21963127c912`) | `kalman_commons_intake` (`929ad91b-17a8-4c3b-94fa-4a9d5ec35be4`) |
| Extras | EspoCRM sync (local) | **Stripe LIVE**, Resend email, Email Routing (groups.*), daily cron `17 3 * * *` |
| Domain registrar | Cloudflare zone (site live) | AWS / Route 53 |

## Credentials and Tools

Never print token file contents into chat, logs, or cron output — pass them to commands.

| Thing | Location |
|---|---|
| Cloudflare API token | `D:\CFConfig\cloudflare-api-token.txt` |
| Kalman Commons deploy token | `D:\CFConfig\kalman-commons-deploy-token.txt` |
| Stripe secret key (LIVE) | `D:\CFConfig\stripe-secret-key.txt` |
| wrangler 4.x | `D:\Tools\npm-global\wrangler.cmd` |
| AWS CLI | `D:\Tools\AWSCLIV2\Amazon\AWSCLIV2\aws.exe` |
| Terraform | `D:\Tools\terraform\terraform.exe` |

Set the token for wrangler non-interactively:

```powershell
$env:CLOUDFLARE_API_TOKEN = (Get-Content D:\CFConfig\cloudflare-api-token.txt -Raw).Trim()
```

## Known State (verified 2026-07-02 — re-verify before acting)

1. **kalman-systems.com.au is LIVE** (since 2026-07-02): proxied CNAMEs apex+www
   → kalman-commons.pages.dev, both attached to the `kalman-commons` Pages
   project and active; www 301s to apex via a zone redirect rule (same canonical
   rule on kalmansystems.com.au). A third zone `kalman-systems.com` (.com) also
   exists on the account, currently unused by Pages.
2. **Both Workers expose `GET /api/health`** (200 = D1 probe OK, 503 = D1
   failing) and wrap top-level handlers in try/catch (fixed + deployed
   2026-07-02). Cloudflare error 1101 should no longer occur; if seen, the
   guard itself is broken — escalate.
3. **Stripe is in LIVE mode** on kalman-commons-intake. Never exercise checkout
   or webhook endpoints with real requests as a "test".
4. **The main site's Pages deployment publicly serves its Worker source**
   (`/cloudflare/worker/src/index.js`, wrangler.toml, READMEs). Fixed for
   kalman-commons (staged redeploy 2026-07-02); the main site needs a
   coordinated clean redeploy — do NOT redeploy it from the git tree without
   confirming the live blog content is not ahead of the repo (blog is
   editor-published).
5. **Token gaps:** the API token in `D:\CFConfig\cloudflare-api-token.txt` has
   Pages + alerting-read only — no Zone/DNS, no Workers Scripts, no D1, no
   Notification write. Worker/D1 wrangler commands on this machine use the
   cached OAuth login (`D:\CFConfig\.wrangler`), which works. CI and DNS
   automation stay blocked until the token is rescoped.

## When to Use

- Any report that either site is down, erroring, or slow
- Reviewing Worker logs/exceptions, D1 errors, or Stripe webhook failures
- Deploying, rolling back, or changing DNS/domains/secrets for either site
- Setting up or running scheduled health checks and backups

Don't use for: content/design edits to the sites (work in the source repos
directly), or EspoCRM back-office work (local-only, separate concern).

## Task 1 — Error Handling

Full runbooks: [references/error-handling.md](references/error-handling.md)

Quick health check (safe, read-only, run any time):

```powershell
powershell -ExecutionPolicy Bypass -File "${HERMES_SKILL_DIR}\scripts\health-check.ps1"
```

Exit code 0 = all green; non-zero = at least one check failed, with a per-check
report on stdout. Checks: both domains, `www` variants, both Pages previews,
both Workers, and TLS certificate expiry.

Triage order for "site is down/erroring":

1. Run the health check — distinguishes DNS failure vs origin error vs Worker error.
2. `4xx/5xx` from Cloudflare edge → check Cloudflare status + zone analytics.
3. Worker error (1101/500) → follow exception-handling runbook.
4. Pages deploy broken → `wrangler pages deployment list --project-name <project>`;
   roll back via the Cloudflare dashboard or redeploy the last good commit.
5. Record findings and the fix; if the same failure recurs, add a detection to
   the health-check script.

## Task 2 — Exception Handling

Full runbooks: [references/exception-handling.md](references/exception-handling.md)

Live exception stream (keep it running while reproducing an error):

```powershell
& D:\Tools\npm-global\wrangler.cmd tail kalman-commons-intake --format pretty
& D:\Tools\npm-global\wrangler.cmd tail kalman-requirements-api --format pretty
```

Key rules:

- An exception in `kalman-commons-intake` can mean a **paid member's action was
  lost** (Stripe checkout, login link, group email). Always check D1 for
  half-completed state after an exception during a write path.
- `scheduled()` (daily cron `17 3 * * *`) and `email()` handlers fail silently
  from the user's perspective — after any Worker change, tail during the next
  cron window or trigger with `wrangler dev --test-scheduled`.
- The permanent fix for recurring 1101s is wrapping the top-level `fetch`
  routers in try/catch that returns structured JSON 500 and logs the stack —
  the reference file has the exact patch plan per Worker.

## Task 3 — System Administration

Full runbooks: [references/system-administration.md](references/system-administration.md)

Covers: attaching kalman-systems.com.au to the Pages project (the pending DNS
task), deploy/rollback procedures for both sites, D1 backup and export, secret
rotation (Cloudflare token, Stripe keys, Resend, CRM sync token, groups repo
PAT), Email Routing for groups.kalman-systems.com.au, and cache purge.

Safety rails — hard rules:

- **Confirm with the user before**: DNS/nameserver changes, deleting any
  Cloudflare resource, rotating the Stripe key, or anything that can interrupt
  live payment flows.
- Deploy production only from a clean git state in the site's source repo;
  never deploy `--env dev` config to the production Worker name.
- D1 has no undo: run `wrangler d1 export` (backup) before any `execute` that
  writes, and never run schema files against `--remote` without a fresh export.

## Scheduled Automations (Hermes cron)

Register these once with the Hermes scheduler (`hermes cron` / cronjob tool);
each job should invoke this skill so the runbooks are in context. All scripts
live in `${HERMES_SKILL_DIR}\scripts\` and use exit codes (0 = green, 1 = act,
2 = could not run):

| Job | Schedule | Script / action |
|---|---|---|
| Site health check | every 30 min | `health-check.ps1` — both domains, Pages, Worker `/api/health`, TLS expiry. Alert on FAIL only |
| D1 backup + growth | daily 02:30 | `d1-backup-and-growth.ps1` — exports both DBs, row counts, 60-day retention. Alert on failed/empty backup |
| Stripe ↔ D1 reconcile | weekly Mon 07:30 | `stripe-d1-reconcile.ps1` — paid Checkout sessions without an active member row = P1 alert |
| Header drift audit | weekly Mon 08:00 | `header-drift-audit.ps1` — live headers vs repo `_headers`; drift = a bad deploy or tampering |
| Link + sitemap crawl | monthly 1st 08:30 | `link-crawl.ps1` — every sitemap URL must return 200 |
| Email DNS audit | monthly 1st 09:00 | `email-dns-audit.ps1` — SPF/DMARC/MX for Resend + Email Routing domains |
| Repo drift check | weekly Fri 17:00 | `repo-drift-check.ps1` — fluffy vs fluffy-hermes website trees; never deploy from the stale copy |
| Worker cron verify | weekly Mon 08:15 | Dashboard (or `wrangler tail` during 13:03 AEST window): confirm kalman-commons-intake's daily `17 3 * * *` sweep ran without exceptions |
| Backup restore drill | quarterly | Import the newest export into a scratch D1 (`wrangler d1 create` a temp DB), verify table counts vs production, delete the temp DB |

One-time (after token rescope): `setup-alerting.ps1` creates the
Cloudflare-native notification policies (Pages deploy failures, SSL events,
L7 DDoS, SYD incidents → email).

Alert delivery: whatever gateway platform the user is active on; include the
failing check names and the first matching runbook step, not raw logs.

## Verification Checklist

After any operation from this skill:

- [ ] `scripts/health-check.ps1` exits 0 (or the known kalman-systems.com.au DNS
      gap is the only failure and is noted)
- [ ] No new exceptions in `wrangler tail` for the touched Worker while
      exercising the changed path once
- [ ] Any D1 write was preceded by an export whose file is non-empty
- [ ] No token or secret value appears in the transcript or cron output
- [ ] Findings/fixes recorded to memory if the failure mode was new
