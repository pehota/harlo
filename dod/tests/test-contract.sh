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

# Shared fixture: e2e/scenario/docs all inapplicable, for tests that don't
# care about those three and just need a valid requirements array.
NA3='{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"test fixture"}'

# --- round trip --------------------------------------------------------------
contract_write "$CFILE" \
  --task-key "main" \
  --task "implement the thing" \
  --task-source "argument" \
  --session-id "sid-1" \
  --baseline-sha "abc123" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"npm test\",\"expect_exit\":0,\"source\":\"protocol\"},$NA3,{\"id\":\"review\",\"type\":\"judgement\",\"agent\":\"dod-reviewer\",\"source\":\"protocol\"}]"

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
eq "round-trip waivers default to empty" "[]" "$CONTRACT_WAIVERS"

# --- waivers round-trip --------------------------------------------------------
WFILE="$REPO/.dod/main/waived-contract.json"
contract_write "$WFILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"lint\",\"type\":\"check\",\"cmd\":\"eslint .\",\"expect_exit\":0,\"source\":\"auto-detected\"},$NA3]" \
  --waivers '[{"id":"lint","reason":"user: prototype spike"}]'
contract_read "$WFILE"
COUNT=$(printf '%s' "$CONTRACT_WAIVERS" | jq 'length' 2>/dev/null)
eq "waivers round-trip: one waiver stored" "1" "$COUNT"
WID=$(printf '%s' "$CONTRACT_WAIVERS" | jq -r '.[0].id' 2>/dev/null)
eq "waivers round-trip: waiver id" "lint" "$WID"
WREASON=$(printf '%s' "$CONTRACT_WAIVERS" | jq -r '.[0].reason' 2>/dev/null)
eq "waivers round-trip: waiver reason" "user: prototype spike" "$WREASON"

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
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"true\",\"expect_exit\":0,\"source\":\"protocol\"},$NA3]"
state_arm_latch "$LATCH_SFILE"
state_read "$LATCH_SFILE"
eq "latch-test setup: latched after arming" "true" "$STATE_LATCHED"

# amend: contract_write runs again for the same task_key
contract_write "$LATCH_CFILE" \
  --task-key "latch-test" --task "amended task" --task-source "argument" \
  --session-id "s" --baseline-sha "abc" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"true\",\"expect_exit\":0,\"source\":\"protocol\"},$NA3]"
state_read "$LATCH_SFILE"
eq "contract_write resets a stale latch on amend" "false" "$STATE_LATCHED"

# --- e2e-always-present invariant ---------------------------------------------

# applicable:true with a cmd is accepted
E2E_APPLICABLE_FILE="$REPO/.dod/main/e2e-applicable-contract.json"
if contract_write "$E2E_APPLICABLE_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"npm test\",\"expect_exit\":0,\"source\":\"protocol\"},{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":\"npm run e2e\",\"expect_exit\":0,\"source\":\"task\",\"applicable\":true,\"reason\":\"adds user-facing flow\"},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  ok "contract_write accepts e2e applicable:true with a cmd"
else
  bad "contract_write accepts e2e applicable:true with a cmd" "rejected"
fi

# applicable:false with a non-empty reason is accepted
E2E_INAPPLICABLE_FILE="$REPO/.dod/main/e2e-inapplicable-contract.json"
if contract_write "$E2E_INAPPLICABLE_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"npm test\",\"expect_exit\":0,\"source\":\"protocol\"},$NA3]"; then
  ok "contract_write accepts e2e applicable:false with a reason"
else
  bad "contract_write accepts e2e applicable:false with a reason" "rejected"
fi

# missing e2e entry entirely is rejected
E2E_MISSING_FILE="$REPO/.dod/main/e2e-missing-contract.json"
if contract_write "$E2E_MISSING_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","cmd":"npm test","expect_exit":0,"source":"protocol"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"test fixture"}]'; then
  bad "contract_write rejects a requirements array with no e2e entry" "accepted"
else
  ok "contract_write rejects a requirements array with no e2e entry"
fi

# applicable:true but no cmd is rejected
E2E_NOCMD_FILE="$REPO/.dod/main/e2e-nocmd-contract.json"
if contract_write "$E2E_NOCMD_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":true},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"protocol\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"protocol\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  bad "contract_write rejects e2e applicable:true with no cmd" "accepted"
else
  ok "contract_write rejects e2e applicable:true with no cmd"
fi

# applicable:false but empty/missing reason is rejected
E2E_NOREASON_FILE="$REPO/.dod/main/e2e-noreason-contract.json"
if contract_write "$E2E_NOREASON_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"\"},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"protocol\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"protocol\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  bad "contract_write rejects e2e applicable:false with empty reason" "accepted"
else
  ok "contract_write rejects e2e applicable:false with empty reason"
fi

E2E_NOREASONFIELD_FILE="$REPO/.dod/main/e2e-noreasonfield-contract.json"
if contract_write "$E2E_NOREASONFIELD_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"protocol\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"protocol\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  bad "contract_write rejects e2e applicable:false with missing reason field" "accepted"
else
  ok "contract_write rejects e2e applicable:false with missing reason field"
fi

# --- scenario-always-present invariant -----------------------------------------
# Mirrors the e2e block above — scenario is a distinct required requirement,
# same shape rules, enforced by contract__validate_scenario.

SCENARIO_APPLICABLE_FILE="$REPO/.dod/main/scenario-applicable-contract.json"
if contract_write "$SCENARIO_APPLICABLE_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"npm test\",\"expect_exit\":0,\"source\":\"protocol\"},{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":\"npm run scenario\",\"expect_exit\":0,\"source\":\"task\",\"applicable\":true,\"reason\":\"changes observable behavior\"},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  ok "contract_write accepts scenario applicable:true with a cmd"
else
  bad "contract_write accepts scenario applicable:true with a cmd" "rejected"
fi

SCENARIO_INAPPLICABLE_FILE="$REPO/.dod/main/scenario-inapplicable-contract.json"
if contract_write "$SCENARIO_INAPPLICABLE_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"npm test\",\"expect_exit\":0,\"source\":\"protocol\"},$NA3]"; then
  ok "contract_write accepts scenario applicable:false with a reason"
else
  bad "contract_write accepts scenario applicable:false with a reason" "rejected"
fi

SCENARIO_MISSING_FILE="$REPO/.dod/main/scenario-missing-contract.json"
if contract_write "$SCENARIO_MISSING_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","cmd":"npm test","expect_exit":0,"source":"protocol"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"}]'; then
  bad "contract_write rejects a requirements array with no scenario entry" "accepted"
else
  ok "contract_write rejects a requirements array with no scenario entry"
fi

SCENARIO_NOCMD_FILE="$REPO/.dod/main/scenario-nocmd-contract.json"
if contract_write "$SCENARIO_NOCMD_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":true},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  bad "contract_write rejects scenario applicable:true with no cmd" "accepted"
else
  ok "contract_write rejects scenario applicable:true with no cmd"
fi

SCENARIO_NOREASON_FILE="$REPO/.dod/main/scenario-noreason-contract.json"
if contract_write "$SCENARIO_NOREASON_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"e2e\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"},{\"id\":\"scenario\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"\"},{\"id\":\"docs\",\"type\":\"check\",\"cmd\":null,\"expect_exit\":null,\"source\":\"task\",\"applicable\":false,\"reason\":\"test fixture\"}]"; then
  bad "contract_write rejects scenario applicable:false with empty reason" "accepted"
else
  ok "contract_write rejects scenario applicable:false with empty reason"
fi

# --- docs-always-present invariant ----------------------------------------------
# Mirrors the e2e/scenario blocks above, but docs' applicable branch uses
# doc_paths instead of cmd — nothing runs it, dod-reviewer checks it.

DOCS_APPLICABLE_FILE="$REPO/.dod/main/docs-applicable-contract.json"
if contract_write "$DOCS_APPLICABLE_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","cmd":"npm test","expect_exit":0,"source":"protocol"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":true,"doc_paths":["README.md"],"reason":"changes documented behavior"}]'; then
  ok "contract_write accepts docs applicable:true with doc_paths"
else
  bad "contract_write accepts docs applicable:true with doc_paths" "rejected"
fi
contract_read "$DOCS_APPLICABLE_FILE"
DOCS_PATHS=$(printf '%s' "$CONTRACT_REQUIREMENTS" | jq -r '.[] | select(.id == "docs") | .doc_paths[0]' 2>/dev/null)
eq "docs applicable round-trips doc_paths" "README.md" "$DOCS_PATHS"

DOCS_INAPPLICABLE_FILE="$REPO/.dod/main/docs-inapplicable-contract.json"
if contract_write "$DOCS_INAPPLICABLE_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements "[{\"id\":\"tests\",\"type\":\"check\",\"cmd\":\"npm test\",\"expect_exit\":0,\"source\":\"protocol\"},$NA3]"; then
  ok "contract_write accepts docs applicable:false with a reason"
else
  bad "contract_write accepts docs applicable:false with a reason" "rejected"
fi

DOCS_MISSING_FILE="$REPO/.dod/main/docs-missing-contract.json"
if contract_write "$DOCS_MISSING_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"tests","type":"check","cmd":"npm test","expect_exit":0,"source":"protocol"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"}]'; then
  bad "contract_write rejects a requirements array with no docs entry" "accepted"
else
  ok "contract_write rejects a requirements array with no docs entry"
fi

DOCS_EMPTYPATHS_FILE="$REPO/.dod/main/docs-emptypaths-contract.json"
if contract_write "$DOCS_EMPTYPATHS_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":true,"doc_paths":[]}]'; then
  bad "contract_write rejects docs applicable:true with empty doc_paths" "accepted"
else
  ok "contract_write rejects docs applicable:true with empty doc_paths"
fi

DOCS_NOPATHSFIELD_FILE="$REPO/.dod/main/docs-nopathsfield-contract.json"
if contract_write "$DOCS_NOPATHSFIELD_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":true}]'; then
  bad "contract_write rejects docs applicable:true with missing doc_paths field" "accepted"
else
  ok "contract_write rejects docs applicable:true with missing doc_paths field"
fi

DOCS_NOREASON_FILE="$REPO/.dod/main/docs-noreason-contract.json"
if contract_write "$DOCS_NOREASON_FILE" \
  --task-key "main" --task "x" --task-source "argument" --session-id "s" \
  --baseline-sha "abc" \
  --requirements '[{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":""}]'; then
  bad "contract_write rejects docs applicable:false with empty reason" "accepted"
else
  ok "contract_write rejects docs applicable:false with empty reason"
fi

# --- contract_read tolerates a legacy contract missing scenario/docs ----------
# A contract written before `scenario`/`docs` became required (an older
# plugin version, or hand-edited) has neither entry. contract_read must
# synthesize an implicit applicable:false for each rather than rejecting the
# whole contract — contract_write already enforces both on every NEW write;
# this only covers reading contracts that predate that enforcement.
LEGACY_FILE="$REPO/.dod/main/legacy-no-scenario-contract.json"
cat > "$LEGACY_FILE" <<'EOF'
{
  "version": 1,
  "task_key": "main",
  "status": "open",
  "task": "legacy task",
  "task_source": "argument",
  "session_id": "s",
  "baseline": { "sha": "abc", "dirty_files": [] },
  "waivers": [],
  "requirements": [
    {"id":"tests","type":"check","cmd":"npm test","expect_exit":0,"source":"protocol"},
    {"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","applicable":false,"reason":"legacy fixture"}
  ]
}
EOF
if contract_read "$LEGACY_FILE"; then
  ok "contract_read accepts a legacy contract missing scenario and docs"
else
  bad "contract_read accepts a legacy contract missing scenario and docs" "rejected"
fi
SCENARIO_COUNT=$(printf '%s' "$CONTRACT_REQUIREMENTS" | jq '[.[] | select(.id == "scenario")] | length' 2>/dev/null)
eq "contract_read synthesizes exactly one scenario entry" "1" "$SCENARIO_COUNT"
SCENARIO_APPLICABLE=$(printf '%s' "$CONTRACT_REQUIREMENTS" | jq -r '.[] | select(.id == "scenario") | .applicable' 2>/dev/null)
eq "contract_read synthesizes scenario as applicable:false" "false" "$SCENARIO_APPLICABLE"
DOCS_COUNT=$(printf '%s' "$CONTRACT_REQUIREMENTS" | jq '[.[] | select(.id == "docs")] | length' 2>/dev/null)
eq "contract_read synthesizes exactly one docs entry" "1" "$DOCS_COUNT"
DOCS_APPLICABLE=$(printf '%s' "$CONTRACT_REQUIREMENTS" | jq -r '.[] | select(.id == "docs") | .applicable' 2>/dev/null)
eq "contract_read synthesizes docs as applicable:false" "false" "$DOCS_APPLICABLE"

echo
echo "contract.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
