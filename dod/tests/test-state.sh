#!/bin/bash
#
# Tests for dod/lib/state.sh: state_read/write + mutators.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/state.sh"

echo "== state.sh =="

REPO=$(dod__test_make_repo)
SFILE="$REPO/.dod/main/state.json"

# --- write defaults + round trip ---------------------------------------------
state_write "$SFILE"
if [ -f "$SFILE" ]; then
  ok "state_write creates the file"
else
  bad "state_write creates the file" "missing"
fi

state_read "$SFILE"
eq "default latched" "false" "$STATE_LATCHED"
eq "default round" "0" "$STATE_ROUND"
eq "default escalation" "none" "$STATE_ESCALATION"

# --- malformed input rejected -------------------------------------------------
BADFILE="$REPO/.dod/main/bad-state.json"
printf 'nope not json' > "$BADFILE"
if state_read "$BADFILE"; then
  bad "state_read rejects malformed JSON" "accepted"
else
  ok "state_read rejects malformed JSON"
fi

# --- N6: state has no requirements array, so validate a plain shape check ----
NOTOBJ="$REPO/.dod/main/notobj-state.json"
printf '[1,2,3]' > "$NOTOBJ"
if state_read "$NOTOBJ"; then
  bad "state_read rejects a non-object JSON value" "accepted"
else
  ok "state_read rejects a non-object JSON value"
fi

# --- mutators ------------------------------------------------------------
state_write "$SFILE"
state_arm_latch "$SFILE"
state_read "$SFILE"
eq "state_arm_latch sets latched" "true" "$STATE_LATCHED"

state_bump_round "$SFILE"
state_read "$SFILE"
eq "state_bump_round increments round" "1" "$STATE_ROUND"
state_bump_round "$SFILE"
state_read "$SFILE"
eq "state_bump_round increments round again" "2" "$STATE_ROUND"

echo
echo "state.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
