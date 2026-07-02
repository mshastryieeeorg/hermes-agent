# System Administration — Runbooks

DNS, deploys, backups, secrets, and email routing for both Kalman sites.
Set `$env:CLOUDFLARE_API_TOKEN` first (SKILL.md). Hard rule: DNS/nameserver
changes, resource deletion, and Stripe key rotation require explicit user
confirmation before execution.

## Domain layout (kalman-systems.com.au went live 2026-07-02)

- Zone `kalman-systems.com.au` (id `e1c9f6e1e47791e42e5f5039a7781a4b`): proxied
  CNAMEs apex + www → kalman-commons.pages.dev; both hostnames active on the
  `kalman-commons` Pages project; www→apex 301 redirect rule; apex Email
  Routing MX/SPF/DKIM records exist.
- Zone `kalmansystems.com.au` (id `b3626f56873d7da3edb5be02a55eed66`): apex +
  www active on `kalman-systems-website`; www→apex 301 redirect rule.
- Zone `kalman-systems.com` (.com, id `74e78870d10771f8c71a0b55a46211d8`):
  active but unused — decide whether to redirect it to one of the .au sites.
- Pages project UUIDs (needed by alerting filters): kalman-commons
  `717004e0-ba63-497d-990e-7a37a83e5962`, kalman-systems-website
  `a889816a-a343-4f29-9282-11e8f536a24c`.

Still open on these zones (blocked: token lacks DNS/rules write; auto-mode also
declines global-key DNS changes — do in dashboard or rescope token first):

1. DMARC TXT on both .au zones: `_dmarc.<zone>` =
   `"v=DMARC1; p=none; rua=mailto:shastry.mahesh@gmail.com; fo=1"`.
2. WAF custom rule on both zones blocking
   `starts_with(http.request.uri.path, "/cloudflare/")`, `/README.md`,
   `/README.txt`, `*.ps1` (main site still serves worker source until its
   clean redeploy).
3. Email Routing for `groups.kalman-systems.com.au` (subdomain MX + catch-all
   route → kalman-commons-intake Worker) and Resend domain verification.

Token fix (preferred long-term): add `Zone → DNS → Edit` + `Zone → Config
Rules → Edit` scoped to the kalman zones, plus account `Workers Scripts: Edit`,
`D1: Edit`, `Notification Services: Edit`.

## Deploys

### kalman-commons (site + worker)

```powershell
cd D:\GitHub\cigars\site
# Site + worker + D1 schema, uses D:\CFConfig token automatically:
powershell -ExecutionPolicy Bypass -File .\scripts\deploy-cloudflare.ps1
# Worker only:
cd cloudflare\worker; & D:\Tools\npm-global\wrangler.cmd deploy
# DEV worker (isolated, safe for testing):
& D:\Tools\npm-global\wrangler.cmd deploy --env dev
```

### kalman-systems-website (main site)

```powershell
cd D:\GitHub\fluffy\Website\Website_Finished_13
# Check for a deploy script first; otherwise:
& D:\Tools\npm-global\wrangler.cmd pages deploy . --project-name kalman-systems-website
cd cloudflare\worker; & D:\Tools\npm-global\wrangler.cmd deploy
```

Pre-deploy checklist (both): `git status` clean in the source repo; you are
deploying from `main`/the intended branch; for commons, you are NOT passing
`--env dev` to a production deploy or vice versa.

Rollback: dashboard → Pages → project → Deployments → Rollback. Workers keep
versions: `wrangler deployments list` then `wrangler rollback` (confirm the
version ID with the user for the commons worker — it serves live payments).

## D1 — backup, inspect, restore

```powershell
$stamp = Get-Date -Format yyyyMMdd-HHmm
New-Item -ItemType Directory -Force D:\CFConfig\backups\d1 | Out-Null
& D:\Tools\npm-global\wrangler.cmd d1 export kalman_commons_intake --remote --output D:\CFConfig\backups\d1\kalman_commons_intake-$stamp.sql
& D:\Tools\npm-global\wrangler.cmd d1 export kalman_requirements  --remote --output D:\CFConfig\backups\d1\kalman_requirements-$stamp.sql
```

- A backup is valid only if the file is non-empty and contains `CREATE TABLE`.
- **Before ANY write** (`d1 execute … --remote` with INSERT/UPDATE/DELETE/DDL):
  take a fresh export. D1 also has point-in-time Time Travel
  (`wrangler d1 time-travel info <db>`) — check the restore bookmark before
  risky operations.
- Restore = user-confirmed operation, never unilateral: import the export into
  a NEW database first, verify counts, then discuss cutover.

## Secrets and tokens

| Secret | Lives on | Rotation procedure |
|---|---|---|
| `CLOUDFLARE_API_TOKEN` | `D:\CFConfig\cloudflare-api-token.txt` | Dashboard → My Profile → API Tokens → roll; update the file; verify with `wrangler whoami` |
| `STRIPE_SECRET_KEY` (LIVE) | Worker secret + `D:\CFConfig\stripe-secret-key.txt` | **User confirmation required.** Stripe dashboard → roll key; `wrangler secret put STRIPE_SECRET_KEY` on kalman-commons-intake; update file; verify one checkout session creation succeeds |
| `STRIPE_WEBHOOK_SECRET` | Worker secret | Rotating it breaks webhook verification until updated — rotate secret and `wrangler secret put` in the same window; then check Stripe webhook deliveries are 2xx |
| `RESEND_API_KEY` | Worker secret | Resend dashboard → new key; `wrangler secret put`; test with a login-link request |
| `CRM_SYNC_TOKEN` | Worker secret + local CRM sync job | Rotate both sides together |
| `GROUPS_REPO_TOKEN` (GitHub PAT) | Worker secret | Fine-grained PAT, Contents R/W on the kalman-groups repo; PATs expire — check expiry during the weekly audit |

List what is set (names only, never values): `wrangler secret list` in each
worker directory.

## Email Routing (groups + aliases)

`GROUPS_DOMAIN = groups.kalman-systems.com.au` requires the zone on Cloudflare
(blocked on the PENDING TASK above), Email Routing enabled, and a catch-all
route → Send to Worker → `kalman-commons-intake`. Also route
`members@kalman-systems.com.au` → the user's private inbox. `MAIL_FROM` uses
`no-reply@kalman-systems.com.au`, which must be a Resend-verified domain —
verify in the Resend dashboard after the zone is live.

## Cache and CSP

- Purge after content deploys that seem "stuck": dashboard → zone → Caching →
  Purge (purge by URL, not Purge Everything, unless the user asks).
- CSP lives in `_headers` in each site's source (`connect-src` must include the
  site's own Worker URL). Changing a Worker URL/name without updating `_headers`
  breaks all forms — grep `_headers` for the old URL whenever renaming anything.

## Routine audit (weekly cron)

1. Health check green (or only the documented pending gap).
2. TLS cert expiry > 21 days on all live hostnames (health-check script reports it).
3. `wrangler whoami` works (token valid); `wrangler secret list` unchanged names.
4. D1 backups: newest file < 8 days old and non-empty for both databases.
5. GitHub PAT (GROUPS_REPO_TOKEN) not within 14 days of expiry.
6. Pages deployments list shows no deployments you cannot account for.
7. Report a one-paragraph summary; open items become tasks with the runbook
   section named.
