#!/bin/bash
#
# Tests for dod/hooks/gate.sh — one case per branch: 0,1,2,3,4,5,6,7,8,9,10,11,12.
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

NA_BRIEF='{"applicable":false,"reason":"test fixture"}'

open_contract() {
  local repo="$1" key="$2"
  contract_write "$repo/.dod/$key/contract.json" \
    --task-key "$key" --task "do the thing" --task-source "argument" \
    --session-id "sid-1" --works-when "test fixture" --baseline-sha "$(git -C "$repo" rev-parse HEAD)" \
    --brief "$NA_BRIEF" \
    --requirements '[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol","proves":"test fixture"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"}]'
}

# --- branch 2: no contract -> release, silent --------------------------------
REPO=$(dod__test_make_repo)
OUT=$(run_gate "$REPO")
eq "branch2: no contract releases silently" "" "$OUT"

# --- branch 4: baseline SHA not an ancestor of HEAD -> expire, release -------
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
# Rewrite history so the recorded baseline sha drops off HEAD's ancestry:
# amend the root commit into a brand new one, orphaning the original.
git -C "$REPO" commit -q --amend -m "rewritten root"
OUT=$(run_gate "$REPO")
eq "branch4: expired baseline releases silently" "" "$OUT"
contract_read "$REPO/.dod/main/contract.json"
eq "branch4: contract status becomes expired" "expired" "$CONTRACT_STATUS"

# --- branch 4: a later Stop on an already-expired contract stays released ----
OUT=$(run_gate "$REPO")
eq "branch4: subsequent Stop on expired contract still releases (via branch 3)" "" "$OUT"

# --- branch 4: baseline still an ancestor (normal case) -> does not expire ---
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
echo "more" >> "$REPO/root.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "a later, ancestor-preserving commit"
OUT=$(run_gate "$REPO")
eq "branch4: baseline still ancestor, no claim/edits -> releases via branch5, not expiry" "" "$OUT"
contract_read "$REPO/.dod/main/contract.json"
eq "branch4: contract status stays open when baseline is still an ancestor" "open" "$CONTRACT_STATUS"

# --- branch 4: git-call failure (not a confirmed non-ancestor) -> fail-open --
# A malformed baseline sha makes `git merge-base --is-ancestor` error out
# (exit 128), not cleanly answer "no" (exit 1). This must NOT be treated as
# "history rewritten" — it must route through branch 0's fail-open, leaving
# contract.json untouched.
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
jq '.baseline.sha = "not-a-valid-sha-at-all!!"' "$REPO/.dod/main/contract.json" > "$REPO/.dod/main/contract.json.tmp"
mv "$REPO/.dod/main/contract.json.tmp" "$REPO/.dod/main/contract.json"
ERR=$(run_gate "$REPO" 2>&1 >/dev/null)
RC=$(run_gate "$REPO" >/dev/null 2>&1; echo $?)
case "$ERR" in
  *"dod gate error"*) ok "branch4: git-call failure logs 'dod gate error' on stderr" ;;
  *) bad "branch4: git-call failure logs 'dod gate error' on stderr" "$ERR" ;;
esac
eq "branch4: git-call failure exits 1" "1" "$RC"
contract_read "$REPO/.dod/main/contract.json"
eq "branch4: git-call failure leaves contract status unchanged (open)" "open" "$CONTRACT_STATUS"

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

# --- branch 5: the latch is scoped to the session that claimed it ----------
# Regression (dogfood, Oct 1 orphan): state.latched persisted across
# sessions, so a claim made in session X kept "claiming" every Stop of a
# later session Y — even one with zero edits — and the gate blocked it on
# X's stale contract forever. dod-claim.sh now records the claiming
# session ($CLAUDE_CODE_SESSION_ID); a latch from another session is
# ignored at branch 5. Edits this prompt still claim on their own.
run_gate_sid() {
  local repo="$1" sid="$2" prompt_id="${3:-p1}"
  CLAUDE_PROJECT_DIR="$repo" bash "$GATE" <<JSON
{"session_id":"$sid","cwd":"$repo","prompt_id":"$prompt_id","stop_hook_active":false}
JSON
}
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
CLAUDE_CODE_SESSION_ID="sid-X" bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate_sid "$REPO" "sid-Y" "py1")
eq "branch5: latch claimed in another session, no edits -> releases" "" "$OUT"
OUT=$(run_gate_sid "$REPO" "sid-X" "px1")
if is_block "$OUT"; then
  ok "branch5: latch claimed in this session still gates"
else
  bad "branch5: latch claimed in this session still gates" "$OUT"
fi
state_log_edit "$REPO/.dod/main/state.json" "py2" "$REPO/root.txt"
OUT=$(run_gate_sid "$REPO" "sid-Y" "py2")
if is_block "$OUT"; then
  ok "branch5: another session's latch + edits this prompt still blocks"
else
  bad "branch5: another session's latch + edits this prompt still blocks" "$OUT"
fi

# empty session id on either side -> pre-scoping behaviour (latch claims), so
# a host that doesn't expose the id never under-blocks.
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
env -u CLAUDE_CODE_SESSION_ID bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate_sid "$REPO" "sid-Y" "py1")
if is_block "$OUT"; then
  ok "branch5: latch with no recorded session id still gates any session"
else
  bad "branch5: latch with no recorded session id still gates any session" "$OUT"
fi
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
CLAUDE_CODE_SESSION_ID="sid-X" bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate_sid "$REPO" "" "py1")
if is_block "$OUT"; then
  ok "branch5: Stop with no session id still honours the latch"
else
  bad "branch5: Stop with no session id still honours the latch" "$OUT"
fi

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
# as /dod:verify would have left behind after resolving a failing check's
# baseline_verdict earlier in the task — branch 10 must reclaim it on pass.
dod_baseline_worktree "$REPO" "main" "$BASELINE" >/dev/null
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$(git -C "$REPO" rev-parse HEAD)" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0}]'
OUT=$(run_gate "$REPO")
eq "branch10: all-pass result releases silently" "" "$OUT"
STATUS_AFTER=$(jq -r '.status' "$REPO/.dod/main/contract.json" 2>/dev/null)
eq "branch10: status set to passed" "passed" "$STATUS_AFTER"
if [ -d "$REPO/.dod/main/baseline-worktree" ]; then
  bad "branch10: tears down the baseline worktree on pass" "still exists"
else
  ok "branch10: tears down the baseline worktree on pass"
fi

# --- branch 11: all pass WITH advisories, no decision -> await, release -----
ADV_PASS='[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0},
  {"id":"review","type":"judgement","verdict":"pass","findings":[
    {"id":"a1","severity":"advisory","file":"root.txt","line":1,"summary":"nit one"},
    {"id":"a2","severity":"advisory","file":"root.txt","line":2,"summary":"nit two"}]}]'
adv_repo() {
  REPO=$(dod__test_make_repo)
  open_contract "$REPO" "main"
  bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
  BASELINE=$(git -C "$REPO" rev-parse HEAD)
  DH=$(dod_diff_hash "$REPO" "$BASELINE")
  result_write "$REPO/.dod/main/result.json" \
    --diff-hash "$DH" --baseline-sha "$BASELINE" --round 1 --requirements "$ADV_PASS"
  result_read "$REPO/.dod/main/result.json"
}
adv_repo
OUT=$(run_gate "$REPO")
eq "branch11: all pass with advisories releases (agent may stop)" "" "$OUT"
eq "branch11: contract stays open" "open" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"
OUT=$(run_gate "$REPO" "p2")
eq "branch11: a later Stop while awaiting still releases" "" "$OUT"
eq "branch11: contract still open while awaiting" "open" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

# --- a partial reply is not recorded -> still awaiting, contract open -------
if state_record_decisions "$REPO/.dod/main/state.json" '[{"id":"a1","decision":"skip"}]' "$DH" "$RESULT_ADVISORY_IDS"; then
  bad "partial decision: rejected (a2 undecided)" "accepted"
else
  ok "partial decision: rejected (a2 undecided)"
fi
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate "$REPO" "p3")
eq "partial decision: Stop still releases" "" "$OUT"
eq "partial decision: contract stays open" "open" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

# --- decision skip-all -> the next Stop closes the contract -----------------
state_record_decisions "$REPO/.dod/main/state.json" '[{"id":"a1","decision":"skip"},{"id":"a2","decision":"skip"}]' "$DH" "$RESULT_ADVISORY_IDS"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate "$REPO" "p3")
eq "decision skip-all: releases" "" "$OUT"
eq "decision skip-all: contract passed" "passed" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

# --- branch 12: fix decided, result not re-verified since -> block ----------
adv_repo
run_gate "$REPO" >/dev/null
state_record_decisions "$REPO/.dod/main/state.json" '[{"id":"a1","decision":"fix"},{"id":"a2","decision":"skip"}]' "$DH" "$RESULT_ADVISORY_IDS"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate "$REPO" "p2")
if is_block "$OUT"; then
  ok "branch12: fix decided but result predates the fix blocks"
else
  bad "branch12: fix decided but result predates the fix blocks" "$OUT"
fi
case "$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)" in
  *"/dod:verify"*) ok "branch12: reason tells agent to fix and run /dod:verify" ;;
  *) bad "branch12: reason tells agent to fix and run /dod:verify" "$OUT" ;;
esac
eq "branch12: contract stays open" "open" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

# fixed + re-verified (new diff): a new advisory in that round is no new
# decision — the contract closes.
echo "fixed a1" >> "$REPO/root.txt"
DH2=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH2" --baseline-sha "$BASELINE" --round 2 \
  --requirements '[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0},
    {"id":"review","type":"judgement","verdict":"pass","findings":[
      {"id":"a9","severity":"advisory","file":"root.txt","line":3,"summary":"new nit"}]}]'
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT=$(run_gate "$REPO" "p3")
eq "decision fix, re-verified: releases" "" "$OUT"
eq "decision fix, re-verified: contract passed despite a new advisory" "passed" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

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

# --- issue #33: latch consumed by a block must not re-claim a later --------
# question-only turn. Sequence: /dod:verify claims + fails (block, as above),
# then a NEW prompt_id with zero edits and no re-claim must release silently
# instead of falling through branch 5 into branch 7/8 on the stale result.
LATCH_AFTER=$(jq -r '.latched' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "issue33 setup: gate disarms the latch after consuming it for the block" "false" "$LATCH_AFTER"
OUT_Q=$(run_gate "$REPO" "p-question-only")
eq "issue33: question-only turn after a block releases silently (N1)" "" "$OUT_Q"

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
# same stop_hook_active=true recursion as OUT1 (same turn) — the latch
# read by OUT1 was NOT disarmed (stop_hook_active guard), so it's still
# claimed here without a re-claim call, matching real recursive Stop.
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

# --- branch 9: round reaches budget (2) -> block once, escalation armed -----
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)

# round 1: fail
DH1=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH1" --baseline-sha "$BASELINE" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"false","exit":1}]'
OUT1=$(run_gate "$REPO" "p1")
is_block "$OUT1" || bad "branch9 setup: round1 failure should block" "$OUT1"
ROUND1=$(jq -r '.round' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "branch9 setup: round bumped to 1" "1" "$ROUND1"

# round 2: still failing, but progress made (different diff) -> reaches budget
echo "more edits" >> "$REPO/root.txt"
DH2=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH2" --baseline-sha "$BASELINE" --round 2 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"false","exit":1}]'
# real /dod:verify re-arms the latch on every run (step 7) — round 1's block
# consumed and disarmed it (issue #33 fix), so round 2 must re-claim too.
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT2=$(run_gate "$REPO" "p2")
if is_block "$OUT2"; then
  ok "branch9: budget-exhausted round blocks"
else
  bad "branch9: budget-exhausted round blocks" "$OUT2"
fi
REASON2=$(printf '%s' "$OUT2" | jq -r '.reason' 2>/dev/null)
case "$REASON2" in
  *"BUDGET EXHAUSTED"*"Report"*) ok "branch9: reason names budget exhaustion and tells agent to report" ;;
  *) bad "branch9: reason names budget exhaustion and tells agent to report" "$REASON2" ;;
esac
case "$REASON2" in
  *"advisories of the last review"*) ok "branch9: reason tells agent to report the last review's advisories" ;;
  *) bad "branch9: reason tells agent to report the last review's advisories" "$REASON2" ;;
esac
case "$REASON2" in
  *"NO PROGRESS"*) bad "branch9: headline must not say NO PROGRESS when budget, not lack of progress, is the trigger" "$REASON2" ;;
  *) ok "branch9: headline does not say NO PROGRESS when budget is the actual trigger" ;;
esac
ESCALATION_AFTER=$(jq -r '.escalation' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "branch9: state.escalation armed" "armed" "$ESCALATION_AFTER"

# --- branch 6: escalation already armed -> release, status := escalated -----
# Create a baseline worktree first, as /dod:verify would have on a failing
# check, so this case also proves branch 6 tears it down — an escalated task
# is terminal (branch 3 releases every later Stop before branch 6 runs
# again), so this is the only chance to reclaim it.
dod_baseline_worktree "$REPO" "main" "$BASELINE" >/dev/null
[ -d "$REPO/.dod/main/baseline-worktree" ] || bad "branch6 setup: baseline worktree should exist before the escalated Stop" "missing"

# escalation is checked at branch 6, downstream of branch 5's CLAIMED gate —
# real usage reaches this only via another /dod:verify call, which re-arms.
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT3=$(run_gate "$REPO" "p3")
eq "branch6: escalation-armed turn releases silently" "" "$OUT3"
STATUS_AFTER=$(jq -r '.status' "$REPO/.dod/main/contract.json" 2>/dev/null)
eq "branch6: status set to escalated" "escalated" "$STATUS_AFTER"
if [ -d "$REPO/.dod/main/baseline-worktree" ]; then
  bad "branch6: tears down the baseline worktree on escalation" "still exists"
else
  ok "branch6: tears down the baseline worktree on escalation"
fi

# --- branch 9 (D26 no-progress), ISOLATED from the budget trigger -----------
# DOD_ROUND_BUDGET is raised to 5 for this case so round 2 does NOT also
# satisfy "round >= budget" on its own — the only thing that can fire here is
# the no-progress OR-arm, proving it works independently of the budget check
# rather than merely producing a different reason string on a round that was
# going to escalate anyway.
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$BASELINE" --round 1 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"false","exit":1}]'
DOD_ROUND_BUDGET=5 run_gate "$REPO" "p1" >/dev/null

# no edits between rounds -> same diff_hash, re-verify without progress.
# Round is about to become 2, nowhere near budget=5 — only no-progress can
# trigger branch 9 here.
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$BASELINE" --round 2 \
  --requirements '[{"id":"tests","type":"check","verdict":"fail","cmd":"false","exit":1}]'
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT_NP=$(DOD_ROUND_BUDGET=5 run_gate "$REPO" "p2")
if is_block "$OUT_NP"; then
  ok "branch9 (D26): no-progress round blocks even though round < budget"
else
  bad "branch9 (D26): no-progress round blocks even though round < budget" "$OUT_NP"
fi
REASON_NP=$(printf '%s' "$OUT_NP" | jq -r '.reason' 2>/dev/null)
case "$REASON_NP" in
  *"NO PROGRESS"*"no progress: diff unchanged between rounds"*) ok "branch9 (D26): headline and reason both name no-progress specifically, not budget" ;;
  *) bad "branch9 (D26): headline and reason both name no-progress specifically, not budget" "$REASON_NP" ;;
esac
case "$REASON_NP" in
  *"BUDGET EXHAUSTED"*) bad "branch9 (D26): headline must not say BUDGET EXHAUSTED for a pure no-progress trigger" "$REASON_NP" ;;
  *) ok "branch9 (D26): headline does not say BUDGET EXHAUSTED for a pure no-progress trigger" ;;
esac
ESCALATION_NP=$(jq -r '.escalation' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "branch9 (D26): state.escalation armed on no-progress" "armed" "$ESCALATION_NP"

# --- branch 8a: scope creep -> block once, no round bump, contract open -----
# (ADR 0004) A blocking review finding with lens:"scope" kind:"creep" must
# NOT go through the ordinary round-bump/escalation machinery — it blocks
# exactly once with a revert/accept-and-amend message, then every Stop on
# the SAME result (same diff_hash, no new /dod:verify) releases silently
# until a new result.json exists.
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$BASELINE" --round 1 \
  --requirements '[
    {"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0},
    {"id":"review","type":"judgement","verdict":"fail","findings":[
      {"id":"c1","severity":"blocking","lens":"scope","kind":"creep","file":"root.txt","line":1,"summary":"unrequested change"}
    ]}
  ]'
OUT=$(run_gate "$REPO" "p1")
if is_block "$OUT"; then
  ok "branch8a: scope creep blocks"
else
  bad "branch8a: scope creep blocks" "$OUT"
fi
REASON=$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)
case "$REASON" in
  *"revert"*"accept"*) ok "branch8a: reason asks the user revert / accept & amend" ;;
  *) bad "branch8a: reason asks the user revert / accept & amend" "$REASON" ;;
esac
ROUND_AFTER=$(jq -r '.round' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "branch8a: round NOT bumped" "0" "$ROUND_AFTER"
eq "branch8a: contract stays open" "open" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

# a later Stop on the SAME result (no new /dod:verify) releases silently
OUT2=$(run_gate "$REPO" "p2")
eq "branch8a: next Stop on the same result releases silently (one-shot)" "" "$OUT2"
eq "branch8a: contract still open after the one-shot release" "open" "$(jq -r '.status' "$REPO/.dod/main/contract.json")"

# a NEW result (fresh /dod:verify) with the same creep finding blocks again
echo "more edits" >> "$REPO/root.txt"
DH2=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH2" --baseline-sha "$BASELINE" --round 1 \
  --requirements '[
    {"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0},
    {"id":"review","type":"judgement","verdict":"fail","findings":[
      {"id":"c1","severity":"blocking","lens":"scope","kind":"creep","file":"root.txt","line":1,"summary":"unrequested change"}
    ]}
  ]'
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
OUT3=$(run_gate "$REPO" "p3")
if is_block "$OUT3"; then
  ok "branch8a: a new result re-blocks (one-shot resets on a new result)"
else
  bad "branch8a: a new result re-blocks (one-shot resets on a new result)" "$OUT3"
fi

# --- branch 8 regression: gap-only blocking failure unchanged ---------------
# (ADR 0004) A blocking finding with lens:"scope" kind:"gap" is NOT creep —
# it must behave exactly as before: round bump, no one-shot release.
REPO=$(dod__test_make_repo)
open_contract "$REPO" "main"
bash "$DIR0/../scripts/dod-claim.sh" "$REPO" "main" >/dev/null 2>&1
BASELINE=$(git -C "$REPO" rev-parse HEAD)
DH=$(dod_diff_hash "$REPO" "$BASELINE")
result_write "$REPO/.dod/main/result.json" \
  --diff-hash "$DH" --baseline-sha "$BASELINE" --round 1 \
  --requirements '[
    {"id":"review","type":"judgement","verdict":"fail","findings":[
      {"id":"g1","severity":"blocking","lens":"scope","kind":"gap","file":"root.txt","line":1,"summary":"missed part of the task"}
    ]}
  ]'
OUT=$(run_gate "$REPO" "p1")
if is_block "$OUT"; then
  ok "branch8 regression: gap-only blocking failure blocks"
else
  bad "branch8 regression: gap-only blocking failure blocks" "$OUT"
fi
REASON=$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)
case "$REASON" in
  *"/dod:verify"*) ok "branch8 regression: reason tells agent to fix and re-verify (unchanged wording)" ;;
  *) bad "branch8 regression: reason tells agent to fix and re-verify (unchanged wording)" "$REASON" ;;
esac
ROUND_AFTER=$(jq -r '.round' "$REPO/.dod/main/state.json" 2>/dev/null)
eq "branch8 regression: round IS bumped for a gap-only failure" "1" "$ROUND_AFTER"

echo
echo "gate.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
