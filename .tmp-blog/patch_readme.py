import sys
fn = sys.argv[1]
t = open(fn, encoding="utf-8").read()

def repl(old, new):
    global t
    c = t.count(old)
    assert c == 1, f"expected 1, found {c}: {old[:60]!r}"
    t = t.replace(old, new, 1)

# folder structure note
repl(
    "CSP-safe). The public site has no write\nendpoint or attack surface.",
    "CSP-safe). Each post lives in its **own folder** `blog/posts/<slug>/index.html` with its\n"
    "images/related files alongside it; the public URL is `/blog/posts/<slug>/`."
)

# step 3 — buttons + optional summary
repl(
    "   The right-hand live preview uses the same renderer that publishes.",
    "   The right-hand live preview uses the same renderer that publishes. **Summary is optional.**\n"
    "   Toolbar: **Render** (force a preview), **Insert image…** (saves into the post folder),\n"
    "   **Preview page** (full deployable page in a new tab), **New**, **Delete**, and **Open\n"
    "   existing post…** which edits a post **in place** — publish time and URL preserved, no\n"
    "   duplicate, no timeline shift."
)

# step 4 — folder output + Update label
repl(
    "4. **Publish & Go Live** writes `blog/posts/<slug>.html`, updates `blog/posts.json`,",
    "4. **Publish & Go Live** (or **Update & Go Live** when editing) writes `blog/posts/<slug>/index.html`, updates `blog/posts.json`,"
)

# UTC + redirects note
repl(
    "deploy status and reports the live URL.",
    "deploy status and reports the live URL. The public site shows each heading with its **UTC\n"
    "publish timestamp**; old `/blog/posts/<slug>.html` URLs 301 to the folder via `_redirects`."
)

open(fn, "w", encoding="utf-8").write(t)
print("README §F updated")
