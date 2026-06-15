#!/usr/bin/env bash
set -euo pipefail
REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null||pwd)}"; cd "$REPO"; CFG="$REPO/.harness.json"
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
tasks="(no tasks.json)"; [ -f tasks.json ] && tasks=$(jq -r '[.tasks[]|"- ["+.status+"] "+.id+": "+.title]|join("\n")' tasks.json 2>/dev/null||echo "(unparseable)")
gates="typecheck/lint/test"; [ -f "$CFG" ] && gates=$(jq -r '[.commands.typecheck,.commands.lint,.commands.test]|map(select(.!=null and .!=""))|join(" && ")' "$CFG" 2>/dev/null||echo "$gates")
ctx="You are the ORCHESTRATOR. Decompose the spec into tasks.json; do not edit source yourself (a hook denies it). Delegate implementation.
Branch: ${branch}
Tasks:
${tasks}
Gate (must stay green): ${gates}"
jq -nc --arg c "$ctx" --arg t "orchestrate:${branch}" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c,sessionTitle:$t}}'
