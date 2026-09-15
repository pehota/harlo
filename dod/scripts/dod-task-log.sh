#!/bin/bash
#
# task-DoD plugin — TaskCompleted hook. OBSERVE-ONLY audit trail.
#
# The plugin previously wrote nothing at all when a task completed, which was
# the original complaint: there was no record of what the agent declared done.
# This hook closes that gap and does NOTHING else.
#
# It records the payload's task_id / task_subject / task_description, plus a UTC
# recorded_at, to $HARNESS_DIR/task-log/<task_id>.json. Any of the three fields
# may be absent; an absent field is simply recorded empty.
#
# THE PAYLOAD SCHEMA IS BEST-AVAILABLE, NOT GUARANTEED. Every TaskCompleted
# field is TOP-LEVEL — session_id, prompt_id, transcript_path, cwd,
# scratchpad_dir, permission_mode, hook_event_name, task_id, task_subject,
# task_description, teammate_name, team_name — but this shape is NOT fully
# published in the public hook docs (there is an open docs-gap issue), so the
# names above are the best information available rather than a contract. That
# is why the RAW payload is persisted alongside the extracted fields, in `raw`:
# if a field is renamed upstream, a record that is silently empty is exactly the
# failure this hook could not otherwise detect, and the raw copy makes it
# obvious at a glance. (The earlier version of this script read `task_state`,
# which does not exist, and therefore wrote an empty string every single time.)
#
# IT CAN NEVER BLOCK and must never learn how. TaskCompleted is a BLOCKING hook
# — exit code 2 PREVENTS task completion — so this script must ALWAYS exit 0,
# whatever happens: missing jq, no payload, malformed payload, an unwritable
# state dir, a failing jq/printf/mkdir on the last line. Every early return is
# an explicit `exit 0` and the file ends in one, so the status of the final
# command can never become the script's exit code. Beyond the blocking risk,
# TaskCompleted is agent-driven, so anything it cleared would be an
# agent-authored relaxation — barred by the asymmetry rule. It only writes; the
# Stop gate never reads this directory.
#
# ALWAYS exit 0, ALWAYS silent.
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
TASK_SUBJECT=$(printf '%s' "$PAYLOAD" | jq -r '.task_subject // ""' 2>/dev/null)

# The id is agent-supplied and reaches the filesystem as a path component, so
# it is sanitised before use. No id at all → a UNIQUE "unknown-task-..." name,
# so the record is still kept rather than dropped — and, crucially, does not
# clobber the previous id-less record. A fixed "unknown-task" basename made the
# audit trail self-overwriting: every id-less completion destroyed the last one,
# leaving exactly one survivor. Timestamp plus PID keeps them apart.
[ -n "$TASK_ID" ] || TASK_ID="unknown-task-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)-$$"
if hc_has_fn hc__sanitize; then
  SAFE_ID=$(hc__sanitize "$TASK_ID")
else
  SAFE_ID=$(printf '%s' "$TASK_ID" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null)
fi
[ -n "$SAFE_ID" ] || exit 0

[ -n "${HARNESS_DIR:-}" ] || HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
LOG_DIR="$HARNESS_DIR/task-log"
mkdir -p "$LOG_DIR" 2>/dev/null || exit 0

# `raw: .` keeps the payload verbatim next to the extracted fields — see the
# schema note in the header. The payload is fed on stdin (it already passed
# `jq empty` above) rather than via --argjson so it is stored as JSON, not as a
# string. A failure here is swallowed: the explicit `exit 0` below is the only
# status this script ever returns.
printf '%s' "$PAYLOAD" | jq \
  --arg id "$TASK_ID" \
  --arg subject "$TASK_SUBJECT" \
  --arg desc "$TASK_DESC" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" \
  '{ task_id: $id, task_subject: $subject, task_description: $desc, recorded_at: $at, raw: . }' \
  > "$LOG_DIR/${SAFE_ID}.json" 2>/dev/null

exit 0
