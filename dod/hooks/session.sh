#!/bin/bash
#
# dod/hooks/session.sh — SessionStart + SessionEnd (design-v2.md §4, §7.5).
#
# One script for two events (not one per §4's "one event, one script" rule —
# that rule is about splitting a SINGLE event across scripts racing in
# parallel; SessionStart and SessionEnd never fire concurrently with each
# other, so dispatching on hook_event_name here is safe and avoids a third
# near-duplicate file).
#
# Three responsibilities:
#   1. Dependency preflight (SessionStart, any source) — verify git and jq
#      are on PATH. Guarded by a marker file keyed to the plugin version, so
#      it's paid once per version, not once per session (N3 — fast).
#   2. Cancel-on-clear (SessionStart, source == "clear") — a /clear ends the
#      task deliberately (§7.1: "a /clear mid-task does not orphan the
#      contract; it cancels it"), since session_id changes on /clear and
#      state is keyed by branch, not session_id.
#   3. Error banner (SessionStart, any source) — if errors.log has entries
#      newer than the last acknowledged read, print them once so a fail-open
#      harness error (dod_fail_open) doesn't go unnoticed forever (§7.4
#      layer 2 — the only *guaranteed* layer besides the log itself).
#
# No `set -e`, no `set -u`, no pipefail — matches every other hook's
# fail-open discipline. A bug here must never block a session from starting.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

DOD_ERR=""
for lib in io.sh gitref.sh contract.sh state.sh; do
  if [ -f "$PLUGIN_ROOT/lib/$lib" ]; then
    . "$PLUGIN_ROOT/lib/$lib" 2>/dev/null
  else
    DOD_ERR="missing lib: $lib"
  fi
done

ERRLOG="$PROJECT_DIR/.dod/errors.log"

if [ -n "$DOD_ERR" ]; then
  if command -v dod_fail_open >/dev/null 2>&1; then
    dod_fail_open "$ERRLOG" "$DOD_ERR"
  fi
  exit 0
fi

RAW=$(cat 2>/dev/null)
EVENT=$(printf '%s' "$RAW" | jq -r '.hook_event_name // ""' 2>/dev/null)
SOURCE=$(printf '%s' "$RAW" | jq -r '.source // ""' 2>/dev/null)

# --- SessionEnd: nothing to do yet. Cancellation is driven entirely by the
# SessionStart(source=clear) that follows a /clear — a bare SessionEnd (the
# user closing the terminal) leaves the contract in place so it's still
# there if they resume the same branch later. -------------------------------
if [ "$EVENT" = "SessionEnd" ]; then
  exit 0
fi

# --- 1. dependency preflight, once per plugin version -----------------------
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"
PLUGIN_VERSION="unknown"
if command -v jq >/dev/null 2>&1 && [ -f "$PLUGIN_JSON" ]; then
  PLUGIN_VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_JSON" 2>/dev/null)
fi
MARKER="$PROJECT_DIR/.dod/.preflight-ok-$PLUGIN_VERSION"

if [ ! -f "$MARKER" ]; then
  MISSING=""
  command -v git >/dev/null 2>&1 || MISSING="git"
  command -v jq >/dev/null 2>&1 || MISSING="${MISSING:+$MISSING, }jq"
  if [ -n "$MISSING" ]; then
    jq -n --arg m "dod: missing required dependency: $MISSING. Install it, then start a new session — /dod:define will refuse to open a DoD until it's present." \
      '{systemMessage: $m}' 2>/dev/null
    # No marker written — keep warning every session start until fixed.
    exit 0
  fi
  mkdir -p "$PROJECT_DIR/.dod" 2>/dev/null
  rm -f "$PROJECT_DIR/.dod/.preflight-ok-"* 2>/dev/null
  : > "$MARKER" 2>/dev/null
fi

# --- 2. cancel-on-clear -------------------------------------------------------
if [ "$SOURCE" = "clear" ]; then
  TASK_KEY=$(dod_task_key "$PROJECT_DIR" 2>/dev/null)
  if [ -n "$TASK_KEY" ]; then
    DOD_DIR="$PROJECT_DIR/.dod/$TASK_KEY"
    CONTRACT_FILE="$DOD_DIR/contract.json"
    if [ -f "$CONTRACT_FILE" ]; then
      contract_read "$CONTRACT_FILE" 2>/dev/null
      if [ "$CONTRACT_STATUS" = "open" ]; then
        contract_set_status "$CONTRACT_FILE" "cancelled"
        dod_baseline_worktree_remove "$PROJECT_DIR" "$TASK_KEY"
      fi
    fi
  fi
fi

# --- 3. error banner -----------------------------------------------------
if [ -f "$ERRLOG" ]; then
  ACK_MARKER="$PROJECT_DIR/.dod/.errors-acked-line-count"
  TOTAL_LINES=$(wc -l < "$ERRLOG" 2>/dev/null | tr -d ' ')
  [ -n "$TOTAL_LINES" ] || TOTAL_LINES=0
  ACKED=0
  [ -f "$ACK_MARKER" ] && ACKED=$(cat "$ACK_MARKER" 2>/dev/null | tr -d ' \r\n')
  case "$ACKED" in ''|*[!0-9]*) ACKED=0 ;; esac

  if [ "$TOTAL_LINES" -gt "$ACKED" ]; then
    NEW_COUNT=$((TOTAL_LINES - ACKED))
    jq -n --arg m "dod: $NEW_COUNT new harness error(s) logged since last session — see $ERRLOG" \
      '{systemMessage: $m}' 2>/dev/null
    printf '%s' "$TOTAL_LINES" > "$ACK_MARKER" 2>/dev/null
  fi
fi

exit 0
