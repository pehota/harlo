#!/bin/bash
#
# dod/hooks/prompt.sh — UserPromptSubmit: nudge to open a DoD BEFORE the
# agent plans the turn, not after it has already edited a file.
#
# track.sh's PostToolUse nudge (D9) fires too late to help the common case:
# the agent decides how to act, edits a file, and only then sees the
# reminder — by which point the edit already happened without a contract,
# and self-invoking /dod:define after the fact is easy to skip under task
# momentum. This hook puts the same reminder at the START of the turn,
# before any tool call, so the agent can self-invoke /dod:define as part of
# planning rather than as a correction.
#
# Non-blocking, same as track.sh's nudge: additionalContext only, never a
# permission decision. Fires on every prompt while no contract is open for
# this task key (no per-prompt dedup) — matches track.sh's existing
# no-state-tracking model and keeps this hook stateless.
#
# No `set -e`, no `set -u`, no pipefail — matches every other hook's
# fail-open discipline. A bug here must never block a prompt from being
# submitted.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

DOD_ERR=""
for lib in io.sh gitref.sh contract.sh result.sh state.sh; do
  if [ -f "$PLUGIN_ROOT/lib/$lib" ]; then
    . "$PLUGIN_ROOT/lib/$lib" 2>/dev/null
  else
    DOD_ERR="missing lib: $lib"
  fi
done

# Harness error -> silently do nothing. Same fail-open discipline as
# track.sh: a UserPromptSubmit hook must never block prompt submission.
if [ -n "$DOD_ERR" ]; then
  exit 0
fi
if ! command -v jq >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  exit 0
fi

TASK_KEY=$(dod_task_key "$PROJECT_DIR" 2>/dev/null)
[ -n "$TASK_KEY" ] || exit 0

CONTRACT_FILE="$PROJECT_DIR/.dod/$TASK_KEY/contract.json"
if [ -f "$CONTRACT_FILE" ]; then
  contract_read "$CONTRACT_FILE" 2>/dev/null
  if [ "$CONTRACT_STATUS" = "open" ]; then
    # Pending advisory decision (gate.sh branch 11): an all-pass result with
    # advisories and no decision recorded yet leaves the contract open but
    # releases the Stop — nothing else reminds the agent on a LATER prompt,
    # so a user who moves on lets the old contract keep gating new edits
    # with the decision never asked for. Same read pattern as gate.sh:
    # result.sh/state.sh own their files (N6), never jq into them directly.
    RESULT_FILE="$PROJECT_DIR/.dod/$TASK_KEY/result.json"
    STATE_FILE="$PROJECT_DIR/.dod/$TASK_KEY/state.json"
    if result_read "$RESULT_FILE" 2>/dev/null \
      && [ "$RESULT_BLOCKING_FAIL" = "0" ] \
      && [ "$RESULT_ADVISORY_IDS" != "[]" ] \
      && state_read "$STATE_FILE" 2>/dev/null \
      && [ "$STATE_DECISIONS" = "[]" ]; then
      IDS=$(printf '%s' "$RESULT_ADVISORY_IDS" | jq -r 'join(", ")' 2>/dev/null)
      jq -n --arg ids "$IDS" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext:
        "dod: an advisory decision is still pending on the open contract — advisory id(s) \($ids). Get the user'"'"'s fix/skip for each before other work, then record the decision (dod-verify SKILL.md, \"Advisory decision\")."}}' 2>/dev/null
      exit 0
    fi
    exit 0
  fi
fi

jq -n '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext:
  "dod: no Definition of Done is open for this task. If this prompt starts or continues implementation work, self-invoke /dod:define before making any edits."}}' 2>/dev/null
exit 0
