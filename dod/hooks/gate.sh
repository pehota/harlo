#!/bin/bash
#
# dod/hooks/gate.sh — the Stop decision tree (docs/design-v2.md §5.1, §6.2).
#
# Exit contract (amendment A1 — JSON block, not `exit 2`):
#   stdout {"decision":"block","reason":"…"} + exit 0  -> block
#   silent + exit 0                                    -> release (normal)
#   stderr one line + exit 1                            -> release (harness error)
#
# No `set -e`, no `set -u`, no pipefail — every git/jq call guarded
# individually so a harness bug degrades to fail-open (branch 0), never a
# wedged session.
#
# Phase 1 branches only: 0,1,2,3,5,7,8,10. Branches 4 (expiry), 6/9
# (escalation) are Phase 2 (docs/design-v2.plan.md) — status stays "open"
# and the round budget is not yet enforced past incrementing.

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

ERRLOG="$PROJECT_DIR/.dod/errors.log"

# --- branch 0: harness error (missing lib / no jq / no git) -----------------
if [ -n "$DOD_ERR" ]; then
  # dod_fail_open may itself be unavailable if io.sh failed to load.
  if command -v dod_fail_open >/dev/null 2>&1; then
    dod_fail_open "$ERRLOG" "$DOD_ERR"
  else
    printf 'dod gate error: %s\n' "$DOD_ERR" >&2
  fi
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  dod_fail_open "$ERRLOG" "jq not found"
  exit 1
fi
if ! command -v git >/dev/null 2>&1; then
  dod_fail_open "$ERRLOG" "git not found"
  exit 1
fi

dod_hook_read
SESSION_ID="$DOD_HOOK_SESSION_ID"
[ -n "$SESSION_ID" ] || SESSION_ID="unknown-session"
STOP_HOOK_ACTIVE="$DOD_HOOK_STOP_ACTIVE"

# --- non-git / detached HEAD / mid-rebase -> release, silent -----------------
GIT_DIR=$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null)
if [ -z "$GIT_DIR" ]; then
  dod_release
  exit 0
fi
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PROJECT_DIR/$GIT_DIR" ;; esac
if [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -d "$GIT_DIR/rebase-merge" ]; then
  dod_release
  exit 0
fi
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse -q --verify HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  dod_release
  exit 0
fi
if ! git -C "$PROJECT_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
  dod_release
  exit 0
fi

TASK_KEY=$(dod_task_key "$PROJECT_DIR")
[ -n "$TASK_KEY" ] || TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$PROJECT_DIR/.dod/$TASK_KEY"
CONTRACT_FILE="$DOD_DIR/contract.json"
RESULT_FILE="$DOD_DIR/result.json"
STATE_FILE="$DOD_DIR/state.json"
LAST_BLOCK_FILE="$DOD_DIR/last-block"

# block <category> <reason> — A2: category-scoped recursion brake. Releases
# under stop_hook_active only if this category equals the last one recorded;
# a DIFFERENT category still blocks even under stop_hook_active.
gate__block() {
  local category="$1" reason="$2" prev=""
  [ -f "$LAST_BLOCK_FILE" ] && prev=$(cat "$LAST_BLOCK_FILE" 2>/dev/null | tr -d '\r\n')
  if [ "$STOP_HOOK_ACTIVE" = "true" ] && [ "$category" = "$prev" ]; then
    dod_release
    exit 0
  fi
  mkdir -p "$DOD_DIR" 2>/dev/null
  printf '%s\n' "$category" > "$LAST_BLOCK_FILE" 2>/dev/null
  dod_block "$reason"
  exit 0
}

gate__clear_last_block() { rm -f "$LAST_BLOCK_FILE" 2>/dev/null; }

# --- branch 2: no contract -> release, silent --------------------------------
if [ ! -f "$CONTRACT_FILE" ]; then
  gate__clear_last_block
  dod_release
  exit 0
fi

contract_read "$CONTRACT_FILE" || {
  dod_fail_open "$ERRLOG" "contract.json unreadable at $CONTRACT_FILE"
  exit 1
}

# --- branch 3: status != open -> release, silent -----------------------------
if [ "$CONTRACT_STATUS" != "open" ]; then
  gate__clear_last_block
  dod_release
  exit 0
fi

# --- branch 5: claimed or edited this prompt? --------------------------------
state_read "$STATE_FILE"
LATCHED="$STATE_LATCHED"
[ "$LATCHED" = "true" ] || LATCHED="false"

if [ "$LATCHED" != "true" ]; then
  gate__clear_last_block
  dod_release
  exit 0
fi

# --- branch 1: stop_hook_active loop guard (category-scoped via gate__block) -
# (No unconditional release here — A2 requires checking the category, which
# only gate__block can do once it knows which branch we're about to hit.)

DIFF_HASH=$(dod_diff_hash "$PROJECT_DIR")

# --- branch 7: no result, or result stale (diff_hash mismatch) -> block ------
if [ ! -f "$RESULT_FILE" ]; then
  gate__block "no-result" "task DoD present but no verification result exists for this changeset — run /dod:verify, then stop again."
fi

result_read "$RESULT_FILE" || {
  gate__block "no-result" "verification result is malformed or unreadable — run /dod:verify, then stop again."
}

if [ "$RESULT_DIFF_HASH" != "$DIFF_HASH" ]; then
  gate__block "no-result" "verification result does not match the current changeset — run /dod:verify, then stop again."
fi

# --- branch 8/10: result matches diff -> check for blocking failures --------
case "$RESULT_BLOCKING_FAIL" in
  ''|*[!0-9]*)
    gate__block "no-result" "verification result is malformed (bad blocking-fail count) — run /dod:verify, then stop again."
    ;;
esac

if [ "$RESULT_BLOCKING_FAIL" -gt 0 ]; then
  state_bump_round "$STATE_FILE"
  state_set_last_failed_diff_hash "$STATE_FILE" "$DIFF_HASH"
  gate__block "findings" "verification result for this changeset has ${RESULT_BLOCKING_FAIL} failing requirement(s) — fix them, run /dod:verify, then stop again."
fi

# --- branch 10: all pass -> release, mark passed -----------------------------
contract_set_status "$CONTRACT_FILE" "passed"
gate__clear_last_block
dod_release
exit 0
