#!/bin/bash
#
# Tests for dod/scripts/dod.sh — the skills' single entry CLI. Each verb is
# run the way a skill runs it: `bash dod.sh <verb> …` from inside a
# throwaway repo (a subdir, for the REPO/TASK_KEY resolution), one fresh
# process per call, nothing carried between calls.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/result.sh"
. "$DIR0/../lib/state.sh"
. "$DIR0/../lib/gitref.sh"

CLI="$DIR0/../scripts/dod.sh"

echo "== scripts/dod.sh =="

NA_BRIEF='{"applicable":false,"reason":"test fixture"}'
REQS='[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol","proves":"test fixture"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"}]'
PASS_REQS='[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0},{"id":"review","type":"judgement","verdict":"pass","findings":[{"id":"a1","severity":"advisory","summary":"nit"}]}]'

REPO=$(dod__test_make_repo task)
mkdir -p "$REPO/sub"
ROOT=$(cd "$REPO" && pwd -P)
SUB="$ROOT/sub"
KEY_DIR="$ROOT/.dod/feature-x"
HEAD_SHA=$(git -C "$ROOT" rev-parse HEAD)
ERR_DIR=$(dod__test_mktemp_d); CLEANUP_DIRS="$CLEANUP_DIRS $ERR_DIR"

# cli <args…> — run dod.sh from the subdir; stdout to OUT, stderr to ERR,
# exit code to RC. Called directly (never in $(...)) so the globals stick.
cli() {
  OUT=$(cd "$SUB" && bash "$CLI" "$@" 2>"$ERR_DIR/err")
  RC=$?
  ERR=$(cat "$ERR_DIR/err" 2>/dev/null)
  rm -f "$ERR_DIR/err"
}

# --- unknown / missing verb ----------------------------------------------------
cli frobnicate
eq "unknown verb: exit" "2" "$RC"
case "$ERR" in *usage:*) ok "unknown verb: usage on stderr" ;; *) bad "unknown verb: usage on stderr" "$ERR" ;; esac
eq "unknown verb: nothing on stdout" "" "$OUT"
cli
eq "no verb: exit" "2" "$RC"

# --- no contract yet -> clear error -------------------------------------------
cli contract-read
[ "$RC" -ne 0 ] && ok "contract-read without a contract: non-zero" || bad "contract-read without a contract: non-zero" "$RC"
case "$ERR" in *"no contract"*"/dod:define"*) ok "contract-read without a contract: clear message" ;; *) bad "contract-read without a contract: clear message" "$ERR" ;; esac
cli diff-hash
[ "$RC" -ne 0 ] && ok "diff-hash without a contract: non-zero" || bad "diff-hash without a contract: non-zero" "$RC"

# --- brief-path ---------------------------------------------------------------
cli brief-path
eq "brief-path: absolute path under <root>/.dod/<key>" "$KEY_DIR/brief.md" "$OUT"

# --- contract-write -> contract-read round-trip -------------------------------
cli contract-write --task "it's a task" --task-source argument --works-when "It works when x" \
  --brief "$NA_BRIEF" --requirements "$REQS" --task-key "spoofed"
eq "contract-write: exit" "0" "$RC"
case "$OUT" in *"$HEAD_SHA"*) ok "contract-write: reports the baseline" ;; *) bad "contract-write: reports the baseline" "$OUT" ;; esac
[ -f "$KEY_DIR/contract.json" ] && ok "contract-write: written at <root>/.dod/<key>" || bad "contract-write: written at <root>/.dod/<key>" "missing"
[ -e "$SUB/.dod" ] && bad "contract-write: nothing under <subdir>/.dod" "exists" || ok "contract-write: nothing under <subdir>/.dod"

cli contract-read
eq "contract-read: exit" "0" "$RC"
eq "contract-read: status" "open" "$(printf '%s' "$OUT" | jq -r '.status')"
eq "contract-read: task" "it's a task" "$(printf '%s' "$OUT" | jq -r '.task')"
eq "contract-read: task_key computed, never caller-supplied" "feature-x" "$(printf '%s' "$OUT" | jq -r '.task_key')"
eq "contract-read: baseline defaults to HEAD" "$HEAD_SHA" "$(printf '%s' "$OUT" | jq -r '.baseline_sha')"
eq "contract-read: works_when" "It works when x" "$(printf '%s' "$OUT" | jq -r '.works_when')"
eq "contract-read: brief" "false" "$(printf '%s' "$OUT" | jq -r '.brief.applicable')"
eq "contract-read: requirements" "4" "$(printf '%s' "$OUT" | jq -r '.requirements | length')"
eq "contract-read: repo is the top-level" "$ROOT" "$(printf '%s' "$OUT" | jq -r '.repo')"
eq "contract-read: state" "idle" "$(printf '%s' "$OUT" | jq -r '.state.state')"
eq "contract-read: no result yet" "null" "$(printf '%s' "$OUT" | jq -r '.result')"

# explicit --baseline-sha (the amend path) is kept, not replaced by HEAD
echo more >> "$ROOT/root.txt"; git -C "$ROOT" commit -qam second
cli contract-write --task t --task-source argument --works-when w --brief "$NA_BRIEF" \
  --requirements "$REQS" --baseline-sha "$HEAD_SHA"
cli contract-read
eq "contract-write --baseline-sha: kept on amend" "$HEAD_SHA" "$(printf '%s' "$OUT" | jq -r '.baseline_sha')"

# --session-id defaults to $CLAUDE_CODE_SESSION_ID
OUT=$(cd "$SUB" && CLAUDE_CODE_SESSION_ID=sid-7 bash "$CLI" contract-write --task t --task-source argument \
  --works-when w --brief "$NA_BRIEF" --requirements "$REQS" --baseline-sha "$HEAD_SHA" 2>&1)
cli contract-read
eq "contract-write: session_id defaults to \$CLAUDE_CODE_SESSION_ID" "sid-7" "$(printf '%s' "$OUT" | jq -r '.session_id')"

# an invalid contract is rejected, with a message, and writes nothing new
cli contract-write --task t --task-source argument --works-when w --brief "$NA_BRIEF" --requirements '[]'
[ "$RC" -ne 0 ] && ok "contract-write: invalid contract -> non-zero" || bad "contract-write: invalid contract -> non-zero" "$RC"
case "$ERR" in *rejected*) ok "contract-write: invalid contract -> clear message" ;; *) bad "contract-write: invalid contract -> clear message" "$ERR" ;; esac

# --- state-set ----------------------------------------------------------------
cli state-set verifying
eq "state-set verifying: exit" "0" "$RC"
state_read "$KEY_DIR/state.json"
eq "state-set verifying: written" "verifying" "$STATE_STATE"
cli state-set bogus
[ "$RC" -ne 0 ] && ok "state-set bogus: non-zero" || bad "state-set bogus: non-zero" "$RC"

# --- diff-hash ----------------------------------------------------------------
echo change >> "$SUB/f.txt"
cli diff-hash
eq "diff-hash: same as dod_diff_hash against the contract baseline" \
  "$(dod_diff_hash "$ROOT" "$HEAD_SHA")" "$OUT"
DH="$OUT"

# --- cache-get / cache-set ----------------------------------------------------
cli cache-get "npm test"
eq "cache-get: miss" "miss" "$OUT"
eq "cache-get: miss exits 0" "0" "$RC"
cli cache-set "npm test" pass
eq "cache-set: exit" "0" "$RC"
cli cache-get "npm test"
eq "cache-get: hit" "pass" "$OUT"
eq "cache-set: keyed on the current diff hash" "pass" "$(state_cache_get "$KEY_DIR/state.json" "$DH" "npm test")"
cli cache-set "npm test" maybe
[ "$RC" -ne 0 ] && ok "cache-set: verdict other than pass|fail rejected" || bad "cache-set: verdict other than pass|fail rejected" "$RC"
echo again >> "$SUB/f.txt"
cli cache-get "npm test"
eq "cache-get: a new diff misses" "miss" "$OUT"

# --- changed-standards --------------------------------------------------------
echo rule > "$ROOT/CLAUDE.md"
cli changed-standards
eq "changed-standards: JSON array" '["CLAUDE.md"]' "$OUT"
rm -f "$ROOT/CLAUDE.md"

# --- baseline-worktree --------------------------------------------------------
cli baseline-worktree
eq "baseline-worktree: path" "$KEY_DIR/baseline-worktree" "$OUT"
eq "baseline-worktree: checked out at baseline" "$HEAD_SHA" "$(git -C "$OUT" rev-parse HEAD 2>/dev/null)"

# --- result-write computes diff hash + round ----------------------------------
cli result-write --requirements "$PASS_REQS"
eq "result-write: exit" "0" "$RC"
result_read "$KEY_DIR/result.json"
eq "result-write: round 1" "1" "$RESULT_ROUND"
eq "result-write: diff hash computed" "$(dod_diff_hash "$ROOT" "$HEAD_SHA")" "$RESULT_DIFF_HASH"
eq "result-write: baseline from the contract" "$HEAD_SHA" "$RESULT_BASELINE_SHA"
cli result-write --requirements "$PASS_REQS"
result_read "$KEY_DIR/result.json"
eq "result-write: next round" "2" "$RESULT_ROUND"
cli result-write --requirements '[{"id":"x","type":"bogus"}]'
[ "$RC" -ne 0 ] && ok "result-write: invalid requirements -> non-zero" || bad "result-write: invalid requirements -> non-zero" "$RC"
cli result-write '[]'
[ "$RC" -ne 0 ] && ok "result-write: missing --requirements -> non-zero" || bad "result-write: missing --requirements -> non-zero" "$RC"
cli contract-read
eq "contract-read: carries the latest result's round" "2" "$(printf '%s' "$OUT" | jq -r '.result.round')"
eq "contract-read: carries the advisory ids" '["a1"]' "$(printf '%s' "$OUT" | jq -c '.result.advisory_ids')"

# --- record-decisions ---------------------------------------------------------
state_disarm_latch "$KEY_DIR/state.json"
cli record-decisions '[{"id":"zz","decision":"skip"}]'
[ "$RC" -ne 0 ] && ok "record-decisions: wrong ids -> non-zero" || bad "record-decisions: wrong ids -> non-zero" "$RC"
state_read "$KEY_DIR/state.json"
eq "record-decisions: rejected set records nothing" "[]" "$STATE_DECISIONS"
eq "record-decisions: rejected set arms nothing" "false" "$STATE_LATCHED"
cli record-decisions '[{"id":"a1","decision":"skip"}]'
eq "record-decisions: exit" "0" "$RC"
state_read "$KEY_DIR/state.json"
eq "record-decisions: recorded" '[{"id":"a1","decision":"skip"}]' "$STATE_DECISIONS"
eq "record-decisions: keyed to the result's diff hash" "$RESULT_DIFF_HASH" "$STATE_DECIDED_DIFF_HASH"
eq "record-decisions: arms the latch" "true" "$STATE_LATCHED"

# --- claim --------------------------------------------------------------------
state_disarm_latch "$KEY_DIR/state.json"
OUT=$(cd "$SUB" && CLAUDE_CODE_SESSION_ID=sid-9 bash "$CLI" claim 2>&1); RC=$?
eq "claim: exit" "0" "$RC"
state_read "$KEY_DIR/state.json"
eq "claim: arms the latch" "true" "$STATE_LATCHED"
eq "claim: records the claiming session" "sid-9" "$STATE_LATCHED_SESSION_ID"

# --- dod-claim.sh still works on its own --------------------------------------
state_disarm_latch "$KEY_DIR/state.json"
bash "$DIR0/../scripts/dod-claim.sh" "$SUB" "feature-x" >/dev/null 2>&1
state_read "$KEY_DIR/state.json"
eq "dod-claim.sh: still arms the latch" "true" "$STATE_LATCHED"

# --- detached HEAD -> clear error, nothing written ----------------------------
git -C "$ROOT" checkout -q --detach
cli contract-read
[ "$RC" -ne 0 ] && ok "detached HEAD: non-zero" || bad "detached HEAD: non-zero" "$RC"
case "$ERR" in *detached*) ok "detached HEAD: clear message" ;; *) bad "detached HEAD: clear message" "$ERR" ;; esac
git -C "$ROOT" checkout -q feature/x

# --- arguments are data, never executed ---------------------------------------
cli cache-set '$(touch '"$ROOT"'/pwned)' pass
[ -e "$ROOT/pwned" ] && bad "arguments are never executed" "pwned exists" || ok "arguments are never executed"

echo
echo "cli: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
