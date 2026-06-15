#!/usr/bin/env bash
# SessionEnd — persist state so the next session resumes cleanly (Ralph-loop external memory).
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}"
ts=$(date -u +%FT%TZ)
{
  echo "## ${ts}"
  git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's/^/branch: /'
  [ -f tasks.json ] && jq -r '.tasks[] | "  [" + .status + "] " + .id' tasks.json 2>/dev/null
} >> PROGRESS.md 2>/dev/null || true
exit 0
