#!/usr/bin/env bash
set -euo pipefail
input=$(cat); cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null||pwd)}"; CFG="$REPO/.harness.json"
deny(){ jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }
echo "$cmd" | grep -Eq '(^|[^[:alnum:]])rm[[:space:]]+-rf' && deny "Destructive rm -rf blocked."
echo "$cmd" | grep -Eq 'git[[:space:]]+(push[[:space:]]+--force|reset[[:space:]]+--hard)' && deny "Force-push / hard-reset blocked. Use a feature branch + PR."
if [ -f "$CFG" ]; then
  pm=$(jq -r '.package_manager // "the configured tool"' "$CFG" 2>/dev/null)
  while IFS= read -r p; do [ -z "$p" ] && continue
    case "$cmd" in *"$p"*) deny "Blocked by harness policy ('$p'). Use ${pm}." ;; esac
  done < <(jq -r '.blocked_command_patterns[]?' "$CFG" 2>/dev/null || true)
fi
exit 0
