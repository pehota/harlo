#!/bin/bash
#
# Tests for dod/lib/contract.sh: contract_read/write/validate.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/state.sh"

echo "== contract.sh =="

REPO=$(dod__test_make_repo)
CFILE="$REPO/.dod/main/contract.json"

# --- round trip --------------------------------------------------------------
contract_write "$CFILE" \
  --task-key "main" \
  --task "implement the thing" \
  --task-source "argument" \
  --session-id "sid-1" \
  --baseline-sha "abc123" \
  --requirements '[{"id":"tests","type":"check","cmd":"npm test","expect_exit":0,"source":"protocol"},{"id":"review","type":"judgement","agent":"dod-reviewer","source":"protocol"}]'

if [ -f "$CFILE" ]; then
  ok "contract_write creates the file"
else
  bad "contract_write creates the file" "missing"
fi

contract_read "$CFILE"
eq "round-trip task_key" "main" "$CONTRACT_TASK_KEY"
eq "round-trip status" "open" "$CONTRACT_STATUS"
eq "round-trip task" "implement the thing" "$CONTRACT_TASK"
eq "round-trip baseline_sha" "abc123" "$CONTRACT_BASELINE_SHA"

# --- malformed input rejected -------------------------------------------------
BADFILE="$REPO/.dod/main/bad-contract.json"
printf '{not valid json' > "$BADFILE"
if contract_read "$BADFILE"; then
  bad "contract_read rejects malformed JSON" "accepted"
else
  ok "contract_read rejects malformed JSON"
fi

# --- N6: requirement must be check or judgement, never neither ---------------
UNTYPED_FILE="$REPO/.dod/main/untyped-contract.json"
if contract_write "$UNTYPED_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"mystery","source":"protocol"}]'; then
  bad "contract_write rejects a requirement with neither type" "accepted"
else
  ok "contract_write rejects a requirement with neither type"
fi
if [ -f "$UNTYPED_FILE" ]; then
  bad "contract_write does not create a file on validation failure" "created"
else
  ok "contract_write does not create a file on validation failure"
fi

# check requirement missing cmd is rejected
NOCMD_FILE="$REPO/.dod/main/nocmd-contract.json"
if contract_write "$NOCMD_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","expect_exit":0,"source":"protocol"}]'; then
  bad "contract_write rejects a check requirement missing cmd" "accepted"
else
  ok "contract_write rejects a check requirement missing cmd"
fi

# --- contract_write resets a stale claim latch on the sibling state.json ----
# Regression: a task passes (latch armed), then the same task_key is amended
# (a fresh contract_write with status back to "open"). Without a reset, the
# gate would treat the very next question-only turn as already latched and
# demand a claim nobody made this time.
LATCH_DIR="$REPO/.dod/latch-test"
LATCH_CFILE="$LATCH_DIR/contract.json"
LATCH_SFILE="$LATCH_DIR/state.json"

contract_write "$LATCH_CFILE" \
  --task-key "latch-test" --task "first pass" --task-source "argument" \
  --session-id "s" --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol"}]'
state_arm_latch "$LATCH_SFILE"
state_read "$LATCH_SFILE"
eq "latch-test setup: latched after arming" "true" "$STATE_LATCHED"

# amend: contract_write runs again for the same task_key
contract_write "$LATCH_CFILE" \
  --task-key "latch-test" --task "amended task" --task-source "argument" \
  --session-id "s" --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol"}]'
state_read "$LATCH_SFILE"
eq "contract_write resets a stale latch on amend" "false" "$STATE_LATCHED"

echo
echo "contract.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
