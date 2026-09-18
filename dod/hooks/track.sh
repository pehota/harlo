#!/bin/bash
#
# dod/hooks/track.sh — PostToolUse: log edited files, nudge if no DoD open.
#
# Two responsibilities in one script — one event, one script, since Claude
# Code runs concurrent same-event hooks in parallel with last-write-wins, so
# splitting this would race against itself:
#
#   1. Contract open -> append an edit record to state.edits. This is what
#      lets gate.sh's branch 5 (D8: claim = latch armed OR edits-this-prompt
#      without a latch) detect "edited this prompt without a latch" without
#      depending on the agent remembering to claim.
#   2. No contract open -> emit a one-line non-blocking nudge (D9) so the
#      agent notices a DoD was never opened. Non-blocking: PostToolUse output
#      is not a permission decision on this event, so this can never wedge a
#      session the way a gate mistake could.
#
#      MUST be hookSpecificOutput.additionalContext JSON, not plain stdout or
#      systemMessage. Plain stdout on PostToolUse exit 0 goes only to the
#      debug log (never the model/transcript). systemMessage is a top-level
#      field per the docs, but EMPIRICALLY VERIFIED (live capture in this
#      session, two markers emitted side by side, only additionalContext
#      arrived) to surface only to the human's terminal on PostToolUse, not
#      to the agent's own context — the opposite of what D9 needs, since D9's
#      whole point is for the AGENT to notice and self-correct. Three review
#      rounds got this wrong before the live test settled it: (1) a bare
#      printf, discarded entirely; (2) systemMessage nested one level too
#      deep inside hookSpecificOutput; (3) systemMessage correctly top-level
#      but reaching the wrong audience. Docs disagreed with each other on
#      this point (the hook-development skill claims systemMessage reaches
#      Claude's context on PostToolUse; the official hooks reference and the
#      live capture both say otherwise) — trust the live capture over either
#      doc when they conflict.
#
# Fires only on tools that edit files (Edit, Write, NotebookEdit) — a Read or
# Bash call is not "an edit" for D8 purposes and must not arm anything.
#
# No `set -e`, no `set -u`, no pipefail — every git/jq call guarded
# individually, matching gate.sh's fail-open discipline. A bug here must
# never block a tool call.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

DOD_ERR=""
for lib in io.sh gitref.sh state.sh; do
  if [ -f "$PLUGIN_ROOT/lib/$lib" ]; then
    . "$PLUGIN_ROOT/lib/$lib" 2>/dev/null
  else
    DOD_ERR="missing lib: $lib"
  fi
done

ERRLOG="$PROJECT_DIR/.dod/errors.log"

# Harness error -> log and exit 0. PostToolUse has no block-vs-release
# contract like Stop; silently doing nothing is the correct fail-open here.
if [ -n "$DOD_ERR" ]; then
  if command -v dod_fail_open >/dev/null 2>&1; then
    dod_fail_open "$ERRLOG" "$DOD_ERR"
  fi
  exit 0
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  exit 0
fi

RAW=$(cat 2>/dev/null)
SESSION_ID=$(printf '%s' "$RAW" | jq -r '.session_id // ""' 2>/dev/null)
PROMPT_ID=$(printf '%s' "$RAW" | jq -r '.prompt_id // ""' 2>/dev/null)
TOOL_NAME=$(printf '%s' "$RAW" | jq -r '.tool_name // ""' 2>/dev/null)
FILE_PATH=$(printf '%s' "$RAW" | jq -r \
  '(.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // "")' 2>/dev/null)

case "$TOOL_NAME" in
  Edit|Write|NotebookEdit) : ;;
  *) exit 0 ;;
esac
[ -n "$FILE_PATH" ] || exit 0

TASK_KEY=$(dod_task_key "$PROJECT_DIR")
[ -n "$TASK_KEY" ] || TASK_KEY="session-${SESSION_ID:-unknown}"

DOD_DIR="$PROJECT_DIR/.dod/$TASK_KEY"
CONTRACT_FILE="$DOD_DIR/contract.json"
STATE_FILE="$DOD_DIR/state.json"

# --- no contract open -> nudge, non-blocking ---------------------------------
if [ ! -f "$CONTRACT_FILE" ]; then
  jq -n '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext:
    "dod: no Definition of Done is open for this task. Run /dod:define before continuing, or ignore this if the edit is unrelated to a task."}}' 2>/dev/null
  exit 0
fi

# --- contract open -> log the edit -------------------------------------------
state_log_edit "$STATE_FILE" "$PROMPT_ID" "$FILE_PATH"
exit 0
