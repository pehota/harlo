#!/bin/bash
#
# Tests for dod/hooks/gate.sh — one case per Phase 1 branch: 0,1,2,3,5,7,8,10.
# Branches 4,6,9 (expiry, escalation, budget) are Phase 2 (design-v2.plan.md).
#
# Idiom (ported from v1's dod-gate.sh suite): assert block via parsed JSON
# (`jq -e '.decision == "block"'`), assert release via EMPTY stdout.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/result.sh"
. "$DIR0/../lib/state.sh"
. "$DIR0/../lib/gitref.sh"

GATE="$DIR0/../hooks/gate.sh"

echo "== gate.sh =="

is_block() {
  printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1
}

run_gate() {
  local repo="$1" prompt_id="${2:-p1}" stop_active="${3:-false}"
  CLAUDE_PROJECT_DIR="$repo" bash "$GATE" <<EOF
{"session_id":"sid-1","cwd":"$repo","prompt_id":"$prompt_id","stop_hook_active":$stop_active}
EOF
}

open_contract() {
  local repo="$1" key="$2"
  contract_write "$repo/.dod/$key/contract.json" \
    --task-key "$key" --task "do the thing" --task-source "argument" \
    --session-id "sid-1" --baseline-sha "$(git -C "$repo" rev-parse HEAD)" \
    --requirements '[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol"}]'
}

# --- branch 2: no contract -> release, silent --------------------------------
REPO=$(dod__test_make_repo)
OUT=$(run_gate "$REPO")
eq "branch2: no contract releases silently" "" "$OUT"

# --- branch 5: contract open, no claim, no edits -> release, silent ----------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
OUT=$(run_gate "$REPO")
eq "branch5: no claim, no edits releases silently" "" "$OUT"

# --- branch 5 (D8): edited this prompt_id without a latch -> block -----------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
state_log_edit "$REPO/.dod/main/state.json" "p1" "$REPO/root.txt"
OUT=$(run_gate "$REPO" "p1")
if is_block "$OUT"; then
  ok "branch5 (D8): edited this prompt without a latch blocks"
else
  bad "branch5 (D8): edited this prompt without a latch blocks" "$OUT"
fi

# --- branch 5 (D8): edit logged under a DIFFERENT prompt_id -> release -------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
state_log_edit "$REPO/.dod/main/state.json" "p1" "$REPO/root.txt"
OUT=$(run_gate "$REPO" "p2")
eq "branch5 (D8): edit under a different prompt_id releases silently" "" "$OUT"

# --- branch 3: status != open (already passed) -> release, silent ------------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
contract_set_status "$REPO/.dod/main/contract.json" "passed"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate "$REPO")
eq "branch3: status!=open releases silently" "" "$OUT"

# --- branch 7: claimed, no result -> block --------------------------------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate "$REPO")
if is_block "$OUT"; then
  ok "branch7: claimed with no result blocks"
else
  bad "branch7: claimed with no result blocks" "$OUT"
fi
REASON=$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)
case "$REASON" in
  *"run /dod:verify"*) ok "branch7: state=idle -> tells agent to run /dod:verify" ;;
  *) bad "branch7: state=idle -> tells agent to run /dod:verify" "$REASON" ;;
esac

# --- branch 7: claimed, no result, state=verifying -> "wait" wording ---------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
state_set_state "$REPO/.dod/main/state.json" "verifying"
OUT=$(run_gate "$REPO")
if is_block "$OUT"; then
  ok "branch7: state=verifying still blocks"
else
  bad "branch7: state=verifying still blocks" "$OUT"
fi
REASON=$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)
case "$REASON" in
  *"already running"*"wait"*) ok "branch7: state=verifying -> tells agent to wait, not re-run" ;;
  *) bad "branch7: state=verifying -> tells agent to wait, not re-run" "$REASON" ;;
esac

# --- branch 10: claimed, passing result matching diff_hash -> release --------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$(git -C "$REPO" rev-parse HEAD)" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0}]'
OUT=$(run_gate "$REPO")
eq "branch10: all-pass result releases silently" "" "$OUT"
STATUS_AFTER=$(jq -r '.status' "$REPO/.dod/main/contract.json" 2>/dev/null)
eq "branch10: status set to passed" "passed" "$STATUS_AFTER"

# --- branch 8: claimed, failing result matching diff_hash -> block, round++ --
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$(git -C "$REPO" rev-parse HEAD)" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"false","exit":1}]'
OUT=$(run_gate "$REPO")
if is_block "$OUT"; then
  ok "branch8: failing result blocks"
else
  bad "branch8: failing result blocks" "$OUT"
fi
ROUND_AFTER=$(jq -r '.round' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "branch8: round incremented" "1" "$ROUND_AFTER"

# --- branch 7 result stale (diff changed after result written) -> block ------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$(git -C "$REPO" rev-parse HEAD)" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0}]'
echo "more edits" >> "$REPO/root.txt"
OUT=$(run_gate "$REPO")
if is_block "$OUT"; then
  ok "branch7: stale result (diff changed) blocks"
else
  bad "branch7: stale result (diff changed) blocks" "$OUT"
fi

# --- branch 1: stop_hook_active + same category as last block -> release -----
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT1=$(run_gate "$REPO" "p1" "false")
is_block "$OUT1" || bad "branch1 setup: first call should block" "$OUT1"
OUT2=$(run_gate "$REPO" "p1" "true")
eq "branch1: stop_hook_active + same category releases" "" "$OUT2"

# --- branch 1 (A2): stop_hook_active but DIFFERENT category -> still blocks --
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT1=$(run_gate "$REPO" "p1" "false")
is_block "$OUT1" || bad "A2 setup: first call should block (no-result)" "$OUT1"
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$(git -C "$REPO" rev-parse HEAD)" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"false","exit":1}]'
OUT2=$(run_gate "$REPO" "p1" "true")
if is_block "$OUT2"; then
  ok "A2: different block category still blocks under stop_hook_active"
else
  bad "A2: different block category still blocks under stop_hook_active" "$OUT2"
fi

# --- branch 0: harness error (missing lib) -> exit 1, noisy release ----------
BROKEN_GATE_DIR=$(dod__test_mktemp_d)
mkdir -p "$BROKEN_GATE_DIR/hooks" "$BROKEN_GATE_DIR/lib"
CLEANUP_DIRS="$CLEANUP_DIRS $BROKEN_GATE_DIR"
cp "$GATE" "$BROKEN_GATE_DIR/hooks/gate.sh"
# lib/ intentionally left empty -> gate.sh must fail open, not crash
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
CLAUDE_PLUGIN_ROOT="$BROKEN_GATE_DIR" CLAUDE_PROJECT_DIR="$REPO" \
  bash "$BROKEN_GATE_DIR/hooks/gate.sh" <<<'{"session_id":"sid-1","cwd":"'"$REPO"'","prompt_id":"p1","stop_hook_active":false}' \
  >/tmp/dod-test-b0-out.$$ 2>/tmp/dod-test-b0-err.$$
RC=$?
eq "branch0: harness error exits 1" "1" "$RC"
if [ -s /tmp/dod-test-b0-err.$$ ]; then
  ok "branch0: harness error writes to stderr"
else
  bad "branch0: harness error writes to stderr" "empty"
fi
rm -f /tmp/dod-test-b0-out.$$ /tmp/dod-test-b0-err.$$

echo
echo "gate.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
