---
description: Start, resume, stop, clear, or open the autoresearch dashboard
argument-hint: <goal | off | clear | export | dashboard>
---

# /autoresearch

The user typed: **$ARGUMENTS**

Dispatch based on the argument:

- `off` — Run: `ruby ${CLAUDE_PLUGIN_ROOT}/mcp/bin/autoresearch-mode off` (disables auto-resume; preserves autoresearch.jsonl).
- `clear` — Confirm with the user, then delete `autoresearch.jsonl`, `autoresearch.md`, `autoresearch.sh`, `autoresearch.checks.sh`, `autoresearch.ideas.md`, and the `.autoresearch-mode` flag.
- `export` — Run: `ruby ${CLAUDE_PLUGIN_ROOT}/mcp/lib/autoresearch/dashboard/server.rb &` and tell the user the URL (default http://127.0.0.1:8765). To view from another device on the LAN (e.g. a phone), prefix with `AUTORESEARCH_HOST=0.0.0.0` (port overridable via `AUTORESEARCH_PORT`). No auth — only expose on trusted networks.
- `dashboard` — Read `autoresearch.jsonl`, render a compact results table inline (commit, metric, status, description, confidence).
- Anything else (the normal case) — invoke the `autoresearch-create` skill, passing the user's text as the goal. If `autoresearch.md` already exists in the project, resume the loop and use `$ARGUMENTS` as additional context. If it doesn't exist, set up a new session.

**Examples:**

```
/autoresearch optimize bundle exec rake test runtime, monitor test pass rate
/autoresearch experiment with bootsnap + spring tweaks for Rails boot time
/autoresearch export
/autoresearch off
/autoresearch clear
```
