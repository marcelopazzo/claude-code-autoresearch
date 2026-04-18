#!/usr/bin/env bash
# Manual fallback if the MCP server's self-install shim fails.
# Run from anywhere: bash path/to/mcp/install.sh
set -euo pipefail

cd "$(dirname "$0")"

if ! command -v bundle >/dev/null 2>&1; then
  echo "autoresearch: 'bundle' not found on PATH. Install Ruby ≥ 3.1 with Bundler." >&2
  exit 1
fi

exec bundle install
