#!/bin/bash
#
# Tests for dod/lib/result.sh: result_read/write/validate.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/result.sh"

echo "== result.sh =="

REPO=$(dod__test_make_repo)
RFILE="$REPO/.dod/main/result.json"

# --- round trip --------------------------------------------------------------
result_write "$RFILE" \
  --diff-hash "abc123" \
  --baseline-sha "def456" \
  --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"pass","cmd":"npm test","exit":0}]'

if [ -f "$RFILE" ]; then
  ok "result_write creates the file"
else
  bad "result_write creates the file" "missing"
fi

result_read "$RFILE"
eq "round-trip diff_hash" "abc123" "$RESULT_DIFF_HASH"
eq "round-trip baseline_sha" "def456" "$RESULT_BASELINE_SHA"
eq "round-trip round" "1" "$RESULT_ROUND"
eq "round-trip blocking_fail count" "0" "$RESULT_BLOCKING_FAIL"

# --- malformed input rejected -------------------------------------------------
BADFILE="$REPO/.dod/main/bad-result.json"
printf 'not json at all' > "$BADFILE"
if result_read "$BADFILE"; then
  bad "result_read rejects malformed JSON" "accepted"
else
  ok "result_read rejects malformed JSON"
fi

# --- N6: requirement must be check or judgement, never neither ---------------
UNTYPED="$REPO/.dod/main/untyped-result.json"
if result_write "$UNTYPED" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[{"id":"mystery","verdict":"pass"}]'; then
  bad "result_write rejects a requirement with neither type" "accepted"
else
  ok "result_write rejects a requirement with neither type"
fi
if [ -f "$UNTYPED" ]; then
  bad "result_write does not create a file on validation failure" "created"
else
  ok "result_write does not create a file on validation failure"
fi

# --- f1: a judgement finding must carry a non-empty string id ----------------
# A null/missing id can never be decided (state_record_decisions requires
# string ids), which would leave an advisory-decision contract stuck open
# forever — reject at the write boundary instead.
NULLID="$REPO/.dod/main/nullid-result.json"
if result_write "$NULLID" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[{"id":"review","type":"judgement","verdict":"pass",
    "findings":[{"id":null,"severity":"advisory","file":"a.ts","line":1,"summary":"x"}]}]'; then
  bad "result_write rejects a judgement finding with a null id" "accepted"
else
  ok "result_write rejects a judgement finding with a null id"
fi
if [ -f "$NULLID" ]; then
  bad "result_write does not create a file on null-id validation failure" "created"
else
  ok "result_write does not create a file on null-id validation failure"
fi

MISSINGID="$REPO/.dod/main/missingid-result.json"
if result_write "$MISSINGID" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[{"id":"review","type":"judgement","verdict":"pass",
    "findings":[{"severity":"advisory","file":"a.ts","line":1,"summary":"x"}]}]'; then
  bad "result_write rejects a judgement finding with a missing id" "accepted"
else
  ok "result_write rejects a judgement finding with a missing id"
fi

# --- blocking failure counted correctly --------------------------------------
FAILFILE="$REPO/.dod/main/fail-result.json"
result_write "$FAILFILE" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"npm test","exit":1},{"id":"lint","type":"check","verdict":"pass","cmd":"npm lint","exit":0}]'
result_read "$FAILFILE"
eq "blocking_fail counts fail verdicts" "1" "$RESULT_BLOCKING_FAIL"

# --- judgement requirement round-trips with nested findings -------------------
JFILE="$REPO/.dod/main/judgement-result.json"
result_write "$JFILE" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[
    {"id":"review","type":"judgement","verdict":"fail",
     "findings":[{"id":"f1","severity":"blocking","file":"a.ts","line":1,"summary":"bug"},
                 {"id":"f2","severity":"advisory","file":"b.ts","line":2,"summary":"naming"}]}
  ]'
result_read "$JFILE"
eq "judgement: blocking_fail counts a failed judgement" "1" "$RESULT_BLOCKING_FAIL"
FINDINGS_COUNT=$(printf '%s' "$RESULT_REQUIREMENTS" | jq '.[0].findings | length' 2>/dev/null)
eq "judgement: findings round-trip intact" "2" "$FINDINGS_COUNT"

# --- judgement requirement, all-advisory findings -> requirement still passes -
JPASSFILE="$REPO/.dod/main/judgement-pass-result.json"
result_write "$JPASSFILE" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[
    {"id":"review","type":"judgement","verdict":"pass",
     "findings":[{"id":"f1","severity":"advisory","file":"b.ts","line":2,"summary":"naming"}]}
  ]'
result_read "$JPASSFILE"
eq "judgement: advisory-only findings do not block" "0" "$RESULT_BLOCKING_FAIL"

# --- RESULT_ADVISORY_IDS: advisory finding ids across judgements --------
result_read "$RFILE"
eq "advisory ids: none in a check-only result" "[]" "$RESULT_ADVISORY_IDS"
result_read "$JFILE"
eq "advisory ids: only severity advisory" '["f2"]' "$RESULT_ADVISORY_IDS"

# --- f1: RESULT_ADVISORY_IDS is deduplicated ----------------------------------
DUPFILE="$REPO/.dod/main/dup-result.json"
result_write "$DUPFILE" \
  --diff-hash "x" --baseline-sha "y" --round 1 \
  --requirements '[
    {"id":"review","type":"judgement","verdict":"pass",
     "findings":[{"id":"f1","severity":"advisory","file":"a.ts","line":1,"summary":"x"},
                 {"id":"f1","severity":"advisory","file":"a.ts","line":1,"summary":"x"}]}
  ]'
result_read "$DUPFILE"
eq "advisory ids: duplicate ids are deduplicated" '["f1"]' "$RESULT_ADVISORY_IDS"

PRIOR="$REPO/.dod/main/prior-result.json"
result_write "$PRIOR" \
  --diff-hash "x" --baseline-sha "y" --round 2 \
  --requirements '[{"id":"tests","type":"check","verdict":"pass","cmd":"t","exit":0}]'

# --- result_next_round: prior round + 1 for the same contract, else 1 ------
eq "next round: no prior result -> 1" "1" "$(result_next_round "$REPO/.dod/main/no-such-result.json" "y")"
eq "next round: same baseline, prior round 2 -> 3" "3" "$(result_next_round "$PRIOR" "y")"
eq "next round: different baseline -> 1" "1" "$(result_next_round "$PRIOR" "other-baseline")"
eq "next round: malformed prior -> 1" "1" "$(result_next_round "$BADFILE" "y")"

echo
echo "result.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
