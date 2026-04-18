#!/usr/bin/env bash
# SessionStart hook — surface a short reminder when autoresearch state exists.
# Stays bash since the logic is trivial.
set -eu

cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

if [ -f "$cwd/autoresearch.md" ] || [ -f "$cwd/autoresearch.jsonl" ]; then
  echo "🔬 autoresearch session detected — run /autoresearch to resume, /autoresearch off to pause, /autoresearch clear to reset."
fi

exit 0
