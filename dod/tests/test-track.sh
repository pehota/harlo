#!/bin/bash
#
# Tests for dod/hooks/track.sh — PostToolUse edit logging + no-contract nudge.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/state.sh"

TRACK="$DIR0/../hooks/track.sh"

echo "== track.sh =="

run_track() {
  local repo="$1" tool="$2" file="$3" prompt_id="${4:-p1}"
  CLAUDE_PROJECT_DIR="$repo" bash "$TRACK" <<EOF
{"session_id":"sid-1","cwd":"$repo","prompt_id":"$prompt_id","tool_name":"$tool","tool_input":{"file_path":"$file"}}
EOF
}

open_contract() {
  local repo="$1" key="$2"
  contract_write "$repo/.dod/$key/contract.json" \
    --task-key "$key" --task "do the thing" --task-source "argument" \
    --session-id "sid-1" --baseline-sha "$(git -C "$repo" rev-parse HEAD)" \
    --requirements '[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"test fixture"}]'
}

# --- no contract open -> nudge via hookSpecificOutput.additionalContext -----
# Empirically verified (live capture, two markers emitted side by side in a
# real Claude Code turn): systemMessage does NOT reach the agent's context on
# PostToolUse (goes to the human's terminal only, or nowhere observable to
# Claude); additionalContext does. Two prior fix attempts (plain stdout, then
# top-level systemMessage) both looked plausible from docs alone and were
# both wrong — this is the one that was actually confirmed to work.
REPO=$(dod__test_make_repo)
OUT=$(run_track "$REPO" "Edit" "$REPO/a.txt")
RC=$?
eq "no contract: exit 0" "0" "$RC"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
case "$CTX" in
  *"no Definition of Done"*) ok "no contract: nudge in hookSpecificOutput.additionalContext" ;;
  *) bad "no contract: nudge in hookSpecificOutput.additionalContext" "$OUT" ;;
esac
EVENT_NAME=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName // ""' 2>/dev/null)
eq "no contract: hookEventName is PostToolUse" "PostToolUse" "$EVENT_NAME"
NO_SYSMSG=$(printf '%s' "$OUT" | jq -r '.systemMessage // "absent"' 2>/dev/null)
eq "no contract: no top-level systemMessage (verified not the working channel)" "absent" "$NO_SYSMSG"

# --- contract open -> edit logged to state.edits -------------------------------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
OUT=$(run_track "$REPO" "Edit" "$REPO/a.txt" "p1")
eq "contract open: no nudge printed" "" "$OUT"
state_read "$REPO/.dod/main/state.json"
COUNT=$(printf '%s' "$STATE_EDITS" | jq 'length' 2>/dev/null)
eq "contract open: one edit logged" "1" "$COUNT"
LOGGED_PATH=$(printf '%s' "$STATE_EDITS" | jq -r '.[0].path' 2>/dev/null)
eq "contract open: logged path" "$REPO/a.txt" "$LOGGED_PATH"
LOGGED_PROMPT=$(printf '%s' "$STATE_EDITS" | jq -r '.[0].prompt_id' 2>/dev/null)
eq "contract open: logged prompt_id" "p1" "$LOGGED_PROMPT"

# --- non-edit tool (Read/Bash) -> ignored, nothing logged ---------------------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
run_track "$REPO" "Bash" "$REPO/a.txt" "p1" >/dev/null
state_read "$REPO/.dod/main/state.json"
COUNT=$(printf '%s' "$STATE_EDITS" | jq 'length' 2>/dev/null)
eq "non-edit tool: nothing logged" "0" "$COUNT"

# --- state_has_edit_for_prompt helper ------------------------------------------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
run_track "$REPO" "Edit" "$REPO/a.txt" "p1" >/dev/null
if state_has_edit_for_prompt "$REPO/.dod/main/state.json" "p1"; then
  ok "state_has_edit_for_prompt: true for logged prompt"
else
  bad "state_has_edit_for_prompt: true for logged prompt" "false"
fi
if state_has_edit_for_prompt "$REPO/.dod/main/state.json" "p2"; then
  bad "state_has_edit_for_prompt: false for different prompt" "true"
else
  ok "state_has_edit_for_prompt: false for different prompt"
fi

echo
echo "track.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
