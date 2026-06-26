# Blog system — Kalman | Systems⁺

A private Markdown + LaTeX editor that publishes **static** blog pages. The public
site stays static (no write endpoint, no attack surface); only you can author,
via a token-gated editor reachable on localhost / your tunnel.

## How it fits together

| Piece | Path | Deployed? |
|-------|------|-----------|
| Public blog index | `blog.html` | ✅ |
| Public posts (one folder each) | `blog/posts/<slug>/index.html` | ✅ |
| Per-post related files (images, etc.) | `blog/posts/<slug>/<file>` | ✅ |
| Vendored KaTeX (CSS + woff2 fonts) | `blog/vendor/katex/` | ✅ |
| Blog styles | `blog/blog.css` | ✅ |
| Post manifest + source | `blog/posts.json` | ✅ |
| Old-URL redirects | `_redirects` | ✅ |
| **Private editor (UI + renderer)** | `blog-admin/` | ❌ never |

Each post lives in **its own folder** — `blog/posts/<slug>/index.html` — with any
images/related files sitting alongside it. The public URL is `/blog/posts/<slug>/`
(the static host serves `index.html` for the directory); legacy `…/<slug>.html`
URLs 301 to the folder via `_redirects`.

Math is rendered **server-side at publish time** with KaTeX, so published pages
need only the self-hosted CSS + fonts — no client JavaScript, no flash of raw
TeX, and nothing that violates the site's strict `script-src 'self'` CSP.

> After changing `server.js` or `blog-admin/render.mjs`, **restart the server**
> (stop the running `node server.js`, then `npm start`) — those load once at
> startup. `editor.html` is read per request, so UI tweaks show on refresh.

## Writing a post

1. Install deps once and start the local server (from `Website_Finished_13/`):
   ```
   npm install
   npm start          # -> http://localhost:3000
   ```
2. Open the editor with your access token (set in `.env` as `BLOG_ADMIN_TOKEN`):
   ```
   http://localhost:3000/admin/blog?key=YOUR_TOKEN
   ```
   Through your tunnel, use the tunnel hostname with the same `?key=...`.
3. Write **title** / date / **summary (optional)** / tags, and the body in
   **Markdown**:
   - Inline math: `$E = mc^2$`  ·  display math: `$$ \int_0^\infty e^{-x}\,dx = 1 $$`
   - Code fences, tables, blockquotes, images, and raw HTML all work.
   - **Insert image…** uploads a file straight into the post's folder and drops a
     link at the cursor (renders in both the preview and the published page).
   - **Render** forces a fresh Markdown → HTML (KaTeX) preview on demand.
   - **Preview page** opens the *complete* deployable page (images + math) in a
     new tab, so you can review it before publishing.
4. Click **Publish & Go Live** (it reads **Update & Go Live** when you're editing
   an existing post). This writes `blog/posts/<slug>/index.html`, updates
   `blog/posts.json`, regenerates `blog.html`, and — unless disabled — deploys the
   static site. The editor shows deploy progress and the final live URL. Each
   public heading is shown with its **UTC publish timestamp**.
5. **Open existing post…** loads a post for **in-place** editing: its identity is
   locked, so an edit *updates* the post — it never creates a duplicate, and its
   original publish time (and URL) is preserved, so the timeline never shifts.
   **New** clears the form for a fresh post; **Delete** permanently removes a post
   (its folder + manifest entry) and redeploys.

## How "Publish & Go Live" deploys

On publish the server kicks off `scripts/deploy-cloudflare.ps1 -SkipWorker` in
the background (build → `wrangler pages deploy`). The publish request returns
immediately; the editor polls `/admin/blog/api/deploy-status` and reports
`Live ✓` with the URL when done. This needs a valid Cloudflare API token
(`D:\CFConfig\cloudflare-api-token.txt`) with **Cloudflare Pages → Edit**.

- Set `BLOG_PUBLISH_DEPLOY=false` in `.env` to publish locally only and deploy
  manually:
  ```
  powershell -ExecutionPolicy Bypass -File .\scripts\deploy-cloudflare.ps1 -SkipWorker
  ```
- If a deploy fails (e.g. bad token), the post is still saved locally; fix the
  token and re-trigger via Publish again or `POST /admin/blog/api/deploy`.

## Editor API (all under `/admin/blog`, token-gated)

| Route | Purpose |
|-------|---------|
| `GET  /` | the editor UI |
| `POST /api/preview` | render Markdown → HTML (live preview) |
| `POST /api/render-page` | render the full post page (Preview page) |
| `GET  /api/posts` · `GET /api/posts/:slug` | list / fetch posts |
| `POST /api/posts` | publish (create/update) a post |
| `POST /api/upload` | save a related file into the post's folder |
| `POST /api/delete` | delete an entire post |
| `GET  /api/deploy-status` · `POST /api/deploy` | deploy status / manual deploy |

## Security notes

- The editor is **disabled** unless `BLOG_ADMIN_TOKEN` (≥ 8 chars) is set in `.env`.
- All `/admin/blog*` routes require the token (constant-time compared).
- The static handler hard-blocks `/blog-admin/*`, so the editor source is never
  served — even over the tunnel.
- Keep `BLOG_ADMIN_TOKEN` out of git (it lives in `.env`, which is gitignored).
- Only run the tunnel while you are actively authoring.
