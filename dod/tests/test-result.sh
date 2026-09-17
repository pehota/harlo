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

echo
echo "result.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
