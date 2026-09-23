#!/bin/bash
#
# Tests for dod/hooks/prompt.sh — UserPromptSubmit no-contract-open nudge.
#
# Same nudge as track.sh's PostToolUse one, but timed at the START of the
# turn (before any tool call) rather than after the first edit — see
# prompt.sh's header for why PostToolUse alone under-fires in practice.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"

PROMPT="$DIR0/../hooks/prompt.sh"

echo "== prompt.sh =="

run_prompt() {
  local repo="$1"
  CLAUDE_PROJECT_DIR="$repo" bash "$PROMPT" <<EOF
{"session_id":"sid-1","cwd":"$repo"}
EOF
}

open_contract() {
  local repo="$1" key="$2"
  contract_write "$repo/.dod/$key/contract.json" \
    --task-key "$key" --task "do the thing" --task-source "argument" \
    --session-id "sid-1" --works-when "test fixture" --baseline-sha "$(git -C "$repo" rev-parse HEAD)" \
    --requirements '[{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"}]'
}

# --- no contract at all -> nudge ---------------------------------------------
REPO=$(dod__test_make_repo)
OUT=$(run_prompt "$REPO")
RC=$?
eq "no contract: exit 0" "0" "$RC"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
case "$CTX" in
  *"no Definition of Done"*) ok "no contract: nudge in hookSpecificOutput.additionalContext" ;;
  *) bad "no contract: nudge in hookSpecificOutput.additionalContext" "$OUT" ;;
esac
EVENT_NAME=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
eq "no contract: hookEventName is UserPromptSubmit" "UserPromptSubmit" "$EVENT_NAME"

# --- contract open -> silent --------------------------------------------------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
OUT=$(run_prompt "$REPO")
eq "contract open: no nudge printed" "" "$OUT"

# --- contract exists but not open (passed/expired/cancelled) -> nudge --------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
contract_set_status "$REPO/.dod/main/contract.json" "passed"
OUT=$(run_prompt "$REPO")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
case "$CTX" in
  *"no Definition of Done"*) ok "passed contract: nudge printed" ;;
  *) bad "passed contract: nudge printed" "$OUT" ;;
esac

# --- non-git dir -> silent, no crash ------------------------------------------
NONGIT=$(dod__test_mktemp_d)
CLEANUP_DIRS="$CLEANUP_DIRS $NONGIT"
OUT=$(run_prompt "$NONGIT")
RC=$?
eq "non-git dir: exit 0" "0" "$RC"
eq "non-git dir: silent" "" "$OUT"

echo
echo "prompt.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
