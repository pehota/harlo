#!/bin/bash
#
# task-DoD plugin — PostToolUse nudge.
#
# PostToolUse on `Bash|Write|Edit`. Fires ONCE per task: the first time the
# changeset touches product surface with no task-dod/<task_key>.json on disk, it
# prints a one-line reminder and drops a marker so it never fires again. Every
# other call is silent.
#
# PostToolUse CANNOT block. The reminder goes out as
# `hookSpecificOutput.additionalContext` (agent-visible), the same channel
# baseline-snapshot.sh uses for its proactive steering — plus a `systemMessage`
# so it also shows in the user's terminal. Fail-safe is SILENT: any missing
# dependency → exit 0, no output.
#
# Guard discipline matches commit-ledger.sh (the reference PostToolUse hook): no
# `set -e`, no catch-all trap, sources harness-common.sh, uses
# hc_read_hook_input / hc_resolve, never fails the tool.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
# CLAUDE_PLUGIN_ROOT points at this plugin's own root when it loads, so the
# shared lib and the classifier lib are both under scripts/. Fall back to a
# path derived from this script's location for direct test invocation.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi
if [ -f "$PLUGIN_ROOT/scripts/lib-classify.sh" ]; then
  . "$PLUGIN_ROOT/scripts/lib-classify.sh" 2>/dev/null
fi

# No jq → cannot reason about the changeset or emit a clean JSON object → stay
# silent (fail-safe, matches the gate's no-jq posture but without any output).
hc_has_jq || exit 0
hc_has_fn hc_read_hook_input || exit 0

hc_read_hook_input
SESSION_ID="$HC_HOOK_SESSION_ID"
[ -n "$SESSION_ID" ] || exit 0

# Not a git repo → no changeset baseline possible → nothing to nudge about.
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

hc_has_fn hc_resolve || exit 0
hc_resolve "$SESSION_ID" 2>/dev/null
[ -n "$HARNESS_DIR" ] || exit 0
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${HC_TASK_KEY}.json"
NUDGE_MARKER="$DOD_DIR/.nudged-${HC_TASK_KEY}"

# Already nudged this task, or the DoD already exists → nothing to do.
[ -f "$NUDGE_MARKER" ] && exit 0
[ -f "$DOD_FILE" ] && exit 0

# Only nudge when the changeset actually touches product surface.
hc_has_fn dod_changeset_has_product || exit 0
dod_changeset_has_product "$SESSION_ID" || exit 0

# Fire — once. Write the marker FIRST so a crash after this point still cannot
# double-nudge (the marker's existence is the whole signal; content is a hint).
mkdir -p "$DOD_DIR" 2>/dev/null
printf 'nudged %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" > "$NUDGE_MARKER" 2>/dev/null

MSG="[task-dod] This changeset touches the product surface and no task DoD exists yet. Write .claude/.harness/task-dod/${HC_TASK_KEY}.json now — requirements (each with an origin: prompt|follow-up|derived), a blast_radius {tier, reason} — while the prompt is still fresh. See docs/base-dod.md. It is append-only after the first write."

jq -n --arg m "$MSG" '
  {
    systemMessage: $m,
    hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $m }
  }
' 2>/dev/null || printf '{"systemMessage":"%s"}\n' "$MSG"

exit 0
