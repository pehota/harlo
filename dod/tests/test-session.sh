#!/bin/bash
#
# Tests for dod/hooks/session.sh — preflight, cancel-on-clear, error banner.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/gitref.sh"

SESSION="$DIR0/../hooks/session.sh"
PLUGIN_ROOT="$(cd "$DIR0/.." && pwd)"

echo "== session.sh =="

run_session() {
  local repo="$1" event="$2" source="${3:-}"
  CLAUDE_PROJECT_DIR="$repo" CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$SESSION" <<EOF
{"session_id":"sid-1","cwd":"$repo","hook_event_name":"$event","source":"$source"}
EOF
}

open_contract() {
  local repo="$1" key="$2"
  contract_write "$repo/.dod/$key/contract.json" \
    --task-key "$key" --task "do the thing" --task-source "argument" \
    --session-id "sid-1" --baseline-sha "$(git -C "$repo" rev-parse HEAD)" \
    --requirements '[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol"}]'
}

# --- preflight: marker created on first SessionStart, deps present ----------
REPO=$(dod__test_make_repo)
run_session "$REPO" "SessionStart" "startup" >/dev/null
MARKERS=$(find "$REPO/.dod" -maxdepth 1 -name '.preflight-ok-*' 2>/dev/null | wc -l | tr -d ' ')
eq "preflight: marker written after a clean SessionStart" "1" "$MARKERS"

# --- preflight: second SessionStart is a no-op re: markers (still exactly one) --
run_session "$REPO" "SessionStart" "startup" >/dev/null
MARKERS=$(find "$REPO/.dod" -maxdepth 1 -name '.preflight-ok-*' 2>/dev/null | wc -l | tr -d ' ')
eq "preflight: still exactly one marker after a second SessionStart" "1" "$MARKERS"

# --- SessionEnd: no-op, never errors --------------------------------------
REPO=$(dod__test_make_repo)
run_session "$REPO" "SessionEnd" "" >/dev/null
RC=$?
eq "SessionEnd: exits 0" "0" "$RC"

# --- cancel-on-clear: open contract -> cancelled + worktree removed --------
REPO=$(dod__test_make_repo "task")
TASK_KEY=$(dod_task_key "$REPO")
open_contract "$REPO" "$TASK_KEY"
dod_baseline_worktree "$REPO" "$TASK_KEY" "$(git -C "$REPO" rev-parse HEAD)" >/dev/null
run_session "$REPO" "SessionStart" "clear" >/dev/null
contract_read "$REPO/.dod/$TASK_KEY/contract.json"
eq "cancel-on-clear: status becomes cancelled" "cancelled" "$CONTRACT_STATUS"
if [ -d "$REPO/.dod/$TASK_KEY/baseline-worktree" ]; then
  bad "cancel-on-clear: baseline worktree removed" "still present"
else
  ok "cancel-on-clear: baseline worktree removed"
fi

# --- cancel-on-clear: no contract open -> no-op, no crash ------------------
REPO=$(dod__test_make_repo)
run_session "$REPO" "SessionStart" "clear" >/dev/null
RC=$?
eq "cancel-on-clear: no contract, exits 0" "0" "$RC"

# --- cancel-on-clear: already-passed contract left untouched ----------------
REPO=$(dod__test_make_repo "task")
TASK_KEY=$(dod_task_key "$REPO")
open_contract "$REPO" "$TASK_KEY"
contract_set_status "$REPO/.dod/$TASK_KEY/contract.json" "passed"
run_session "$REPO" "SessionStart" "clear" >/dev/null
contract_read "$REPO/.dod/$TASK_KEY/contract.json"
eq "cancel-on-clear: passed contract stays passed, not overwritten to cancelled" "passed" "$CONTRACT_STATUS"

# --- error banner: no errors.log -> silent -----------------------------------
REPO=$(dod__test_make_repo)
OUT=$(run_session "$REPO" "SessionStart" "startup")
eq "error banner: no errors.log, no systemMessage" "" "$OUT"

# --- error banner: unacknowledged errors.log -> one systemMessage -----------
REPO=$(dod__test_make_repo)
mkdir -p "$REPO/.dod"
printf '2026-01-01T00:00:00Z dod gate error: missing lib: io.sh\n' > "$REPO/.dod/errors.log"
OUT=$(run_session "$REPO" "SessionStart" "startup")
MSG=$(printf '%s' "$OUT" | jq -r '.systemMessage // ""' 2>/dev/null)
case "$MSG" in
  *"1 new harness error"*) ok "error banner: reports unacknowledged error count" ;;
  *) bad "error banner: reports unacknowledged error count" "$OUT" ;;
esac

# --- error banner: acknowledged, no new errors -> silent on next start -----
OUT=$(run_session "$REPO" "SessionStart" "startup")
eq "error banner: silent once acknowledged" "" "$OUT"

# --- error banner: a new error after acknowledgement -> reported again -----
printf '2026-01-01T00:00:01Z dod gate error: jq not found\n' >> "$REPO/.dod/errors.log"
OUT=$(run_session "$REPO" "SessionStart" "startup")
MSG=$(printf '%s' "$OUT" | jq -r '.systemMessage // ""' 2>/dev/null)
case "$MSG" in
  *"1 new harness error"*) ok "error banner: reports only the newly appended error" ;;
  *) bad "error banner: reports only the newly appended error" "$OUT" ;;
esac

echo
echo "session.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
