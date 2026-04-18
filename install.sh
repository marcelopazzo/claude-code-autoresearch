#!/usr/bin/env bash
# Manual install — symlinks commands, skills, hooks, statusline, and MCP
# server into ~/.claude so the plugin works without the plugin marketplace.
# Prefer `/plugin install ...` in Claude Code; this is a fallback.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

mkdir -p "$CLAUDE_DIR/commands" "$CLAUDE_DIR/skills"

echo "→ Installing commands"
for cmd in "$REPO_DIR/commands"/*.md; do
  ln -sfn "$cmd" "$CLAUDE_DIR/commands/$(basename "$cmd")"
done

echo "→ Installing skills"
for skill in "$REPO_DIR/skills"/*/; do
  name="$(basename "$skill")"
  ln -sfn "$skill" "$CLAUDE_DIR/skills/$name"
done

echo "→ Installing Ruby deps"
(cd "$REPO_DIR/mcp" && bundle install --quiet)

cat <<EOF

Done. To finish setup, add to your ~/.claude/settings.json:

  "mcpServers": {
    "autoresearch": {
      "command": "ruby",
      "args": ["$REPO_DIR/mcp/bin/autoresearch-mcp"]
    }
  },
  "statusLine": {
    "type": "command",
    "command": "$REPO_DIR/statusline/autoresearch.rb"
  },
  "hooks": {
    "UserPromptSubmit": [{"hooks":[{"type":"command","command":"$REPO_DIR/hooks/inject_context.rb"}]}],
    "Stop":             [{"hooks":[{"type":"command","command":"$REPO_DIR/hooks/auto_resume.rb"}]}],
    "SessionStart":     [{"hooks":[{"type":"command","command":"$REPO_DIR/hooks/session_start.sh"}]}]
  }

Then restart Claude Code.
EOF
