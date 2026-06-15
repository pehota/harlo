#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
[ "${HARNESS_ROLE:-}" = "implement" ] && exit 0
agent_id=$(jq -r '.agent_id // empty' <<<"$input"); [ -n "$agent_id" ] && exit 0
fp=$(jq -r '.tool_input.file_path // empty' <<<"$input")
case "$fp" in */tasks.json|tasks.json|*/plans/*|*/.claude/state/*|*/REFLECTION.md|*/PROGRESS.md) exit 0 ;; esac
REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null||pwd)}"; CFG="$REPO/.harness.json"
globs=$(jq -r '.source_globs[]?' "$CFG" 2>/dev/null || true); [ -z "$globs" ] && globs=$'src\napps\npackages'
while IFS= read -r g; do [ -z "$g" ] && continue
  case "$fp" in *"/$g/"*|"$g/"*)
    jq -nc '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"Planning/orchestrator role must not write source. Decompose into tasks.json; the loop implements each task in role=implement."}}'
    exit 0 ;; esac
done <<<"$globs"
exit 0
