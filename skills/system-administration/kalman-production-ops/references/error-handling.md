# Error Handling — Runbooks

Detection, triage, and resolution of production errors for both Kalman sites.
All commands assume `$env:CLOUDFLARE_API_TOKEN` is set (see SKILL.md).

## Error taxonomy — what a failing request looks like

| Symptom | Layer | Meaning | Runbook |
|---|---|---|---|
| DNS `NXDOMAIN` / no A record | DNS | Domain not pointed (current state of kalman-systems.com.au) | §DNS |
| Connection refused / timeout | Edge | Cloudflare outage or network path issue | §Edge |
| `403` with `Server: cloudflare`, no site content | WAF/Bot | Cloudflare security rule blocked the client (bots and plain `curl` get this on kalmansystems.com.au — use a browser User-Agent) | §WAF |
| `404` on a page that should exist | Pages | Bad/partial deploy, wrong publish dir | §Pages |
| `500`/`502` JSON from `/api/*` | Worker | Handled error path inside the Worker | §Worker-handled |
| Cloudflare error **1101** page | Worker | **Uncaught exception** — escalate to exception-handling reference | exception-handling.md |
| Cloudflare **522/523/525** | Origin/TLS | Origin unreachable or TLS mismatch (rare here — everything is Pages/Workers) | §Edge |
| Form submits but nothing saved | Worker+D1 | Worker returned 2xx but D1 write failed, or CORS blocked the POST silently | §Data-path |

## §DNS — resolution failures

```powershell
Resolve-DnsName kalmansystems.com.au -Type A
Resolve-DnsName kalman-systems.com.au -Type A     # KNOWN GAP: currently empty
Resolve-DnsName www.kalman-systems.com.au         # currently NXDOMAIN
```

- kalmansystems.com.au must resolve to Cloudflare anycast IPs (`104.21.x.x` /
  `172.67.x.x`). Anything else = zone hijack or registrar change — stop and alert.
- kalman-systems.com.au failing is the **known pending task**, not an incident,
  until the domain-attachment runbook (system-administration.md) has been done.
  After that runbook completes, a resolution failure here IS an incident.

## §Edge — Cloudflare-side failures

1. Check https://www.cloudflarestatus.com/ first — if Cloudflare has an active
   incident affecting Pages/Workers/Sydney (SYD PoP), report and wait; nothing
   local will fix it.
2. Compare the custom domain against the Pages preview URL
   (kalman-commons.pages.dev / kalman-systems-website.pages.dev). Preview OK +
   custom domain failing = domain/zone problem, not a deploy problem.
3. Zone-level analytics (errors by status code):

```powershell
& D:\Tools\npm-global\wrangler.cmd pages deployment list --project-name kalman-commons
# and dashboard: dash.cloudflare.com -> account a6bed40… -> zone -> Analytics -> HTTP traffic
```

## §WAF — 403s from security rules

Cloudflare bot protection on kalmansystems.com.au returns 403 to non-browser
clients. Before treating a 403 as an incident:

```powershell
# Reproduce as a browser:
curl.exe -sI -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36" https://kalmansystems.com.au
```

- Browser UA gets 200, plain client gets 403 → working as designed; if a
  legitimate integration is being blocked, add a WAF skip rule scoped to the
  exact path + verified header, never a blanket allow.
- Browser UA also gets 403 → check WAF events in the dashboard (Security →
  Events) for the rule ID, and review recent rule changes before disabling anything.

## §Pages — deploy and content errors

```powershell
& D:\Tools\npm-global\wrangler.cmd pages deployment list --project-name kalman-systems-website
& D:\Tools\npm-global\wrangler.cmd pages deployment list --project-name kalman-commons
```

1. Identify whether the newest deployment's timestamp matches the last intended
   deploy. An unexpected deployment = investigate who/what deployed (CI, manual).
2. 404s after a deploy usually mean the publish directory was wrong (must be
   `site/` for kalman-commons) or files were dropped from the source repo.
3. Rollback: Cloudflare dashboard → Pages → project → Deployments → "Rollback
   to this deployment" on the last good one. Verify with the health check.
4. `_headers` mistakes (CSP typos) break the site silently — a CSP that blocks
   `connect-src` to the Worker makes forms fail with **no server-side error at
   all**. Check the browser console reproduction path in §Data-path.

## §Worker-handled — structured 4xx/5xx from `/api/*`

These are errors the Worker code anticipated (JSON body with `ok: false`).

1. Read the JSON `error`/`errors` field — the Workers return machine-readable
   reasons (`not_found`, `payment session failed`, …).
2. Map to source: routes live in
   `D:\GitHub\cigars\site\cloudflare\worker\src\index.js` (commons, router ~line 1427)
   and `D:\GitHub\fluffy\Website\Website_Finished_13\cloudflare\worker\src\index.js`
   (requirements, router ~line 243).
3. `502 payment session failed` from `/api/*` on commons = Stripe call failed:
   check Stripe dashboard status + whether `STRIPE_SECRET_KEY` secret is set on
   the Worker (`wrangler secret list`). Do not retry payments on the user's behalf.
4. `503` from `/api/login-link` = `RESEND_API_KEY` not set or Resend outage.

## §Data-path — "form did nothing"

1. Reproduce in a browser with DevTools open (or browser tool): watch the
   Network tab for the POST to the Worker.
2. POST absent → front-end JS error or CSP `connect-src` block (console shows it).
3. POST present, CORS error → the page origin is missing from `ALLOWED_ORIGIN`
   in the Worker's wrangler.toml `[vars]`. Fix there and redeploy the Worker.
4. POST 2xx but no record → query D1 read-only to confirm:

```powershell
& D:\Tools\npm-global\wrangler.cmd d1 execute kalman_requirements --remote --command "SELECT COUNT(*), MAX(created_at) FROM submissions" --json
```

(adjust table names per schema.sql in each worker directory — read the schema
first, don't guess).

## NEL — passive error telemetry

Both sites send Network Error Logging reports to Cloudflare
(`Report-To`/`NEL` headers are already emitted). The dashboard's zone analytics
surface these as client-observed errors — check them when users report errors
you cannot reproduce.

## Escalation rule

If two triage passes don't localize the failure layer, or any incident involves
the Stripe/payment path, stop and report to the user with: symptom, layers ruled
out, current suspicion, and the proposed next action. Do not experiment on the
live payment flow.
