#!/bin/bash
#
# task-DoD plugin — TaskCompleted hook. OBSERVE-ONLY audit trail.
#
# The plugin previously wrote nothing at all when a task completed, which was
# the original complaint: there was no record of what the agent declared done.
# This hook closes that gap and does NOTHING else.
#
# It records the payload's task_id / task_description / task_state, plus a UTC
# recorded_at, to $HARNESS_DIR/task-log/<task_id>.json. Any of the three fields
# may be absent; an absent field is simply recorded empty.
#
# IT CAN NEVER BLOCK and must never learn how. TaskCompleted is agent-driven,
# so anything it cleared would be an agent-authored relaxation — barred by the
# asymmetry rule. It only writes; the Stop gate never reads this directory.
#
# ALWAYS exit 0, ALWAYS silent — including on missing jq, no payload, or an
# unwritable state dir.
#
# Only the ORCHESTRATOR runs dod; no SubagentStop and no PostToolUse hook is
# registered by this plugin.
#
# No `set -e`, no catch-all EXIT trap; every jq call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=harness-common.sh
if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi

hc_has_jq || exit 0

PAYLOAD=$(cat 2>/dev/null)
[ -n "$PAYLOAD" ] || exit 0
printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1 || exit 0

TASK_ID=$(printf '%s' "$PAYLOAD" | jq -r '.task_id // ""' 2>/dev/null)
TASK_DESC=$(printf '%s' "$PAYLOAD" | jq -r '.task_description // ""' 2>/dev/null)
TASK_STATE=$(printf '%s' "$PAYLOAD" | jq -r '.task_state // ""' 2>/dev/null)

# The id is agent-supplied and reaches the filesystem as a path component, so
# it is sanitised before use. No id at all → "unknown-task", so the record is
# still kept rather than dropped.
[ -n "$TASK_ID" ] || TASK_ID="unknown-task"
if hc_has_fn hc__sanitize; then
  SAFE_ID=$(hc__sanitize "$TASK_ID")
else
  SAFE_ID=$(printf '%s' "$TASK_ID" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null)
fi
[ -n "$SAFE_ID" ] || exit 0

[ -n "${HARNESS_DIR:-}" ] || HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
LOG_DIR="$HARNESS_DIR/task-log"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

jq -n \
  --arg id "$TASK_ID" \
  --arg desc "$TASK_DESC" \
  --arg state "$TASK_STATE" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
  '{ task_id: $id, task_description: $desc, task_state: $state, recorded_at: $at }' \
  > "$LOG_DIR/${SAFE_ID}.json" 2>/dev/null

exit 0
