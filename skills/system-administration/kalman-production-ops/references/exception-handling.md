# Exception Handling — Runbooks

Uncaught and caught exceptions in the two Cloudflare Workers, plus the D1,
Stripe-webhook, email, and cron paths that can fail invisibly.

## Current code posture (audited 2026-07-02)

| Worker | try/catch coverage | Risk |
|---|---|---|
| `kalman-commons-intake` (`D:\GitHub\cigars\site\cloudflare\worker\src\index.js`) | 34 try/catch blocks in handlers, but the top-level `fetch` router (~line 1427) is **unwrapped** | Any exception in routing or an unguarded handler → Cloudflare 1101 page to the visitor |
| `kalman-requirements-api` (`D:\GitHub\fluffy\Website\Website_Finished_13\cloudflare\worker\src\index.js`) | **1 catch in the entire file**; top-level `fetch` (~line 243) unwrapped | Almost any handler bug → 1101; a D1 outage makes every form submission throw |

## Observing exceptions

### Live tail (primary tool)

```powershell
$env:CLOUDFLARE_API_TOKEN = (Get-Content D:\CFConfig\cloudflare-api-token.txt -Raw).Trim()
& D:\Tools\npm-global\wrangler.cmd tail kalman-commons-intake --format pretty
& D:\Tools\npm-global\wrangler.cmd tail kalman-requirements-api --format pretty
```

- `tail` only shows events while it is attached — start it, then reproduce.
- Look for `"outcome": "exception"` events; the log includes the JS stack.
- Filter noise: `--status error` shows only failures.

### After the fact

Workers → the worker → Observability/Logs in the dashboard (retention is short;
capture stacks into the incident notes immediately — do not rely on going back
later).

## Triage runbook — Worker threw (1101 / outcome: exception)

1. Capture: exact URL/method, timestamp (UTC), stack from tail/logs.
2. Locate the handler in the source file (routers listed above map path → function).
3. Classify the throw:
   - **Input-shaped** (bad JSON, missing field, malformed email) → the handler
     needs a guard that returns 400 JSON; write the fix in the source repo, test
     with `wrangler dev`, deploy.
   - **Dependency** (D1 error, Stripe/Resend/GitHub API failure) → check the
     dependency first (§below); the code fix is a catch that returns 502/503
     JSON and preserves any partial state consistently.
   - **Logic bug** → reproduce under `wrangler dev` with the captured input
     before touching production.
4. **Write-path exceptions on commons demand a D1 consistency check** — a throw
   between Stripe success and the D1 insert can strand a paid member:

```powershell
# Compare recent Stripe checkouts against members rows (read-only):
& D:\Tools\npm-global\wrangler.cmd d1 execute kalman_commons_intake --remote --json --command "SELECT id, email, status, created_at FROM members ORDER BY created_at DESC LIMIT 20"
```

Cross-check against Stripe dashboard → Payments for the same window. Any paid
checkout without a member row is a **P1**: report to the user with the Stripe
session ID; do not attempt to hand-insert rows without confirmation.

## Silent failure surfaces (no visitor-facing error at all)

| Surface | Failure mode | How to check |
|---|---|---|
| `scheduled()` daily cron `17 3 * * *` (commons) | Retention sweep / token cleanup throws; nobody sees it | `wrangler tail` during the window (13:03 AEST), or dashboard cron logs; locally `wrangler dev --test-scheduled` |
| `email()` handler (commons groups) | Inbound group mail rejected — sender gets a bounce, members see nothing | Tail while sending a test mail to a group address; check `setReject` events (~line 1475) |
| Stripe webhook `/api/stripe/webhook` | Signature mismatch after secret rotation → members paid but never activated | Stripe dashboard → Developers → Webhooks → recent deliveries; failed deliveries retry, but investigate on first failure |
| Git mirror (GROUPS_REPO) | PAT expired → forum posts stop being archived | Check recent commits in the kalman-groups repo vs recent forum posts |
| Resend email | API key invalid → login links and notifications silently skipped (`503` only on login-link) | Resend dashboard delivery log |

## Permanent remediation plan (do when asked to "fix exception handling")

Per Worker, in its source repo, as a normal reviewed change:

1. Wrap the body of `export default { async fetch }` in try/catch. The catch:
   `console.error` the stack (shows up in tail/logs), return
   `json({ ok:false, error:"internal" }, 500)` **with the same CORS headers the
   route would have used** — a bare 500 without CORS headers turns one bug into
   two (browser reports CORS, hiding the real error).
2. Same wrap for `scheduled()` and `email()` — catch, log, and for `email()`
   keep the existing `setReject("Temporary processing error")` behavior.
3. Add `GET /api/health` returning `{ ok: true, worker: <name>, ts: <iso> }`
   with a cheap D1 probe (`SELECT 1`). Then point `scripts/health-check.ps1` at
   it (replace the "any-response = alive" heuristic).
4. Test under `wrangler dev` (commons has a dev env: `--env dev` deploys to
   `kalman-commons-intake-dev` — use it), then deploy production and verify with
   one tailed request.
5. Never widen a catch to swallow-and-continue on write paths; failing loudly
   with a 5xx is correct when D1 state would otherwise be inconsistent.

## Escalation rule

Anything touching money (Stripe path exceptions, webhook failures, stranded
members) → report to the user before mutating any data. Everything else:
fix-forward in the source repo with a test, deploy, verify, then summarize.
