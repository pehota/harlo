#!/usr/bin/env bash
set -euo pipefail
input=$(cat); fp=$(jq -r '.tool_input.file_path // empty' <<<"$input")
REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null||pwd)}"; CFG="$REPO/.harness.json"; cd "$REPO"
[ -f "$CFG" ] || exit 0
exts=$(jq -r '(.test_file_exts // ["ts","tsx"])|join("|")' "$CFG" 2>/dev/null || echo 'ts|tsx')
echo "$fp" | grep -Eq "\.($exts)\$" || exit 0
safe_fp=$(printf '%q' "$fp")
FMT=$(jq -r '.commands.format // empty' "$CFG" 2>/dev/null || true)
LF=$(jq -r '.commands.lint_file // empty' "$CFG" 2>/dev/null || true)
[ -n "$FMT" ] && eval "$FMT $safe_fp" >/dev/null 2>&1 || true
if [ -n "$LF" ]; then out=$(eval "$LF $safe_fp" 2>&1 || true)
  [ -n "$out" ] && jq -nc --arg c "Lint findings in ${fp}:\n${out}" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
fi
exit 0
