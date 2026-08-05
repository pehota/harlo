#!/bin/bash
#
# State-table fixture test for hc_state() + hc_done_state_blocked().
#
# Zero-dependency: bash + git + jq only (the same deps harness-common.sh needs).
# No bats. Each case spins up a real git repo in a mktemp dir, makes real
# commit(s) to produce real SHAs, writes fixture JSON into
# .claude/.harness/{done-state,review-log}/ + .claude/done-config.json, sources
# the REAL harness-common.sh (so it resolves the REAL contracts/ schemas via its
# own BASH_SOURCE), then calls hc_resolve + hc_state and asserts the outcome.
#
# Prints PASS/FAIL per case; exits non-zero on any failure.

set -u

# --- locate the library (relative to THIS script) ----------------------------
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$TESTS_DIR/../scripts/harness-common.sh"

if [ ! -f "$LIB" ]; then
  echo "FATAL: cannot find harness-common.sh at $LIB" >&2
  exit 1
fi

# shellcheck source=./test-helpers.sh
. "$TESTS_DIR/test-helpers.sh"

# make_repo <mode>  — creates a temp git repo, echoes its path.
#   mode "task"    → creates a feature branch off main (task mode: branch != trunk).
#   mode "session" → stays on main; caller drives session-mode via baselines.
make_repo() { hc__test_make_repo "$@"; }

# Commit a change on the current branch so HEAD moves past base. Echoes new HEAD.
commit_change() {
  local dir="$1" name="$2" content="$3"
  echo "$content" > "$dir/$name"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "add $name"
  git -C "$dir" rev-parse HEAD
}

# Write a done-state from a fixture with verified_sha injected.
write_done_state() {
  local dir="$1" fixture="$2" head="$3" key="$4"
  jq --arg sha "$head" '.verified_sha = $sha' "$fixture" \
    > "$dir/.claude/.harness/done-state/$key.json"
}

# Write a review-log from a fixture with reviewed_sha + files_reviewed injected,
# keyed by the live HEAD sha (as the gate/predicate expects).
write_review_log() {
  local dir="$1" fixture="$2" head="$3"
  shift 3
  # remaining args = files_reviewed entries
  local files_json="[]"
  if [ "$#" -gt 0 ]; then
    files_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  fi
  jq --arg sha "$head" --argjson files "$files_json" \
    '.reviewed_sha = $sha | .files_reviewed = $files' "$fixture" \
    > "$dir/.claude/.harness/review-log/$head.json"
}

# task_key for a repo on branch feature/x is br-feature-x; on main (session) it
# is session-<id>. Helper mirrors hc__sanitize for the branch case.
task_key_for_branch() {
  printf 'br-%s' "$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g')"
}

# Run hc_state in a SUBSHELL so each case gets a clean global namespace and its
# own PROJECT_DIR — no leakage between cases. Echoes "STATE|NEXT".
run_state() {
  local dir="$1" sid="$2"
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    hc_state "$sid"
    printf '%s|%s' "$HC_STATE" "$HC_NEXT"
  )
}

# Run hc_done_state_blocked directly. Echoes HC_DONE_BLOCKED_REASON.
run_blocked() {
  local dir="$1"; shift
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    # resolve so PROJECT_DIR/HARNESS_DIR/HC_CONTRACTS_DIR are set for the coverage
    # subcall inside the predicate.
    hc_resolve "sid" >/dev/null 2>&1
    hc_done_state_blocked "$@"
    printf '%s' "$HC_DONE_BLOCKED_REASON"
  )
}

split_state() { printf '%s' "${1%%|*}"; }
split_next()  { printf '%s' "${1#*|}"; }

echo "=============================================================="
echo " hc_state state-table fixture test"
echo "=============================================================="

# ---------------------------------------------------------------------------
# CASE S0 — task mode, HEAD == base, clean tree → idle, silent.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S0: idle (no committed work past base, clean tree) ---"
DIR=$(make_repo task)
OUT=$(run_state "$DIR" "sess-s0")
assert_eq   "S0 state"     "$(split_state "$OUT")" "S0"
assert_empty "S0 next"     "$(split_next "$OUT")"

# enable_noncode_globs <dir> — turn ON the scope allowlist for THIS repo (the
# shared fixture config ships noncode_globs=[] so every OTHER case keeps the
# pre-#5 "everything is code" behavior). Committed onto the BASE (main) so the
# config edit is part of the anchor, not the changeset under test (a
# .claude/done-config.json edit is not matched by the globs and would otherwise
# show up as a code file in base..HEAD). Covers the extensions used below.
enable_noncode_globs() {
  local dir="$1"
  git -C "$dir" checkout -q main
  jq '.noncode_globs = ["*.md","*.txt"]' "$dir/.claude/done-config.json" \
    > "$dir/.claude/done-config.json.tmp" && mv "$dir/.claude/done-config.json.tmp" "$dir/.claude/done-config.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "config: noncode_globs"
  git -C "$dir" checkout -q feature/x
  git -C "$dir" rebase -q main >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# CASE S_OOS-commit — committed changeset of ONLY non-code files → out-of-scope.
#   Exercises the committed-range branch of the predicate and the S_OOS
#   placement (after S0, before S1/S2). noncode_globs enabled for this repo.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S_OOS-commit: out-of-scope (committed .md/.txt only) ---"
DIR=$(make_repo task)
enable_noncode_globs "$DIR"
commit_change "$DIR" "notes.md"   "# notes"   >/dev/null
commit_change "$DIR" "readme.txt" "hello"     >/dev/null
OUT=$(run_state "$DIR" "sess-oos-commit")
assert_eq    "S_OOS-commit state" "$(split_state "$OUT")" "S_OOS"
assert_empty "S_OOS-commit next"  "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S_OOS-dirt — introduced-tree .md dirt only (uncommitted) → out-of-scope.
#   Proves the introduced-set (HC_TREE_BLOCKERS) branch of the predicate and
#   that non-code dirt stands down instead of landing in S1.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S_OOS-dirt: out-of-scope (introduced .md dirt only) ---"
DIR=$(make_repo task)
enable_noncode_globs "$DIR"
echo "# wip notes" > "$DIR/wip.md"   # untracked non-code → introduced blocker, but non-code
OUT=$(run_state "$DIR" "sess-oos-dirt")
assert_eq    "S_OOS-dirt state" "$(split_state "$OUT")" "S_OOS"
assert_empty "S_OOS-dirt next"  "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S1-mixed — introduced dirt with a .sh among .md → CODE → S1 (still gates).
#   Any code file keeps the changeset in scope; scope check must NOT swallow it
#   even though noncode_globs would classify the .md alone as non-code.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S1-mixed: code file among non-code dirt → S1 ---"
DIR=$(make_repo task)
enable_noncode_globs "$DIR"
echo "# doc"       > "$DIR/doc.md"
echo "echo hi"     > "$DIR/script.sh"
OUT=$(run_state "$DIR" "sess-s1-mixed")
assert_eq       "S1-mixed state" "$(split_state "$OUT")" "S1"
assert_nonempty "S1-mixed next"  "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S1 — introduced tree blocker (uncommitted new file) → working.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S1: working (introduced uncommitted change) ---"
DIR=$(make_repo task)
echo "wip" > "$DIR/wip.txt"   # untracked, not in any baseline → introduced blocker
OUT=$(run_state "$DIR" "sess-s1")
assert_eq      "S1 state" "$(split_state "$OUT")" "S1"
assert_nonempty "S1 next" "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S2a — committed work, NO done-state → committed-unverified.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S2a: committed-unverified (no done-state) ---"
DIR=$(make_repo task)
commit_change "$DIR" "feat.txt" "feature" >/dev/null
OUT=$(run_state "$DIR" "sess-s2a")
assert_eq      "S2a state" "$(split_state "$OUT")" "S2"
assert_nonempty "S2a next" "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S2b — committed work, STALE done-state (verified_sha != HEAD) → S2.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S2b: committed-unverified (stale done-state) ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
# advance HEAD so the done-state's verified_sha is now stale.
H2=$(commit_change "$DIR" "more.txt" "more")
OUT=$(run_state "$DIR" "sess-s2b")
assert_eq "S2b state" "$(split_state "$OUT")" "S2"

# ---------------------------------------------------------------------------
# CASE S4a — valid done-state at HEAD, no escalation, tests.exit_code=1 → S4.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S4a: blocked-on-tests (done-state at HEAD, red tests) ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
# green fixture but flip tests.exit_code to 1, stamp verified_sha=HEAD.
jq --arg sha "$H1" '.verified_sha = $sha | .tests.exit_code = 1' \
  "$FIX/done-state-green.json" > "$DIR/.claude/.harness/done-state/$KEY.json"
# provide a valid green review-log at HEAD so the FIRST failing check is tests.
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
OUT=$(run_state "$DIR" "sess-s4a")
assert_eq      "S4a state" "$(split_state "$OUT")" "S4"
assert_nonempty "S4a next" "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S4b — valid done-state at HEAD, green tests, but review coverage gap → S4.
#   The review-log attests NO files, yet the changeset touched feat.txt.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S4b: blocked-on-coverage-gap (done-state at HEAD) ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
# review-log with EMPTY files_reviewed → coverage gap vs the changed feat.txt.
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1"
OUT=$(run_state "$DIR" "sess-s4b")
assert_eq      "S4b state" "$(split_state "$OUT")" "S4"
NEXT_S4B=$(split_next "$OUT")
assert_eq      "S4b next-is-coverage-remedy" "$NEXT_S4B" "review the uncovered files, then re-run /done"

# ---------------------------------------------------------------------------
# CASE S5 — valid green done-state at HEAD + valid review-log covering the
#   changeset → verified, silent.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S5: verified (green done-state + covering review-log) ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
OUT=$(run_state "$DIR" "sess-s5")
assert_eq    "S5 state" "$(split_state "$OUT")" "S5"
assert_empty "S5 next"  "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# CASE S5-esc — RED tests but escalation present → escalation dominates → S5.
#   Proves escalation sits ABOVE the blocked predicate.
# ---------------------------------------------------------------------------
echo
echo "--- CASE S5-esc: verified-via-escalation (red tests, escalation set) ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
jq --arg sha "$H1" \
  '.verified_sha = $sha | .tests.exit_code = 1 | .escalation = {"reason":"blocked upstream"}' \
  "$FIX/done-state-green.json" > "$DIR/.claude/.harness/done-state/$KEY.json"
# deliberately NO review-log at HEAD — escalation must short-circuit before any
# of that is consulted.
OUT=$(run_state "$DIR" "sess-s5esc")
assert_eq    "S5-esc state" "$(split_state "$OUT")" "S5"
assert_empty "S5-esc next"  "$(split_next "$OUT")"

# ---------------------------------------------------------------------------
# Focused hc_done_state_blocked tests.
# ---------------------------------------------------------------------------
echo
echo "--- CASE DSB-SKIP: SKIP coverage is NOT a block ---"
# base empty → hc_review_coverage_gap returns SKIP → must NOT block on coverage.
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1"   # empty files_reviewed
HARNESS="$DIR/.claude/.harness"
CONTRACTS="$TESTS_DIR/../contracts"
DS="$DIR/.claude/.harness/done-state/tmp.json"
jq --arg sha "$H1" '.verified_sha = $sha' "$FIX/done-state-green.json" > "$DS"
# base="" → coverage SKIP; tests green, review green, task_checks green → NOT blocked.
REASON=$(run_blocked "$DIR" "$DS" "$H1" "" "$HARNESS" "$CONTRACTS" "high")
assert_empty "DSB-SKIP not blocked (SKIP is graceful degrade)" "$REASON"

echo
echo "--- CASE DSB-ERR: a high review finding IS a block ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
write_review_log "$DIR" "$FIX/review-log-highfinding.json" "$H1" "feat.txt"
HARNESS="$DIR/.claude/.harness"
CONTRACTS="$TESTS_DIR/../contracts"
DS="$DIR/.claude/.harness/done-state/tmp.json"
jq --arg sha "$H1" '.verified_sha = $sha' "$FIX/done-state-green.json" > "$DS"
REASON=$(run_blocked "$DIR" "$DS" "$H1" "$H1~1" "$HARNESS" "$CONTRACTS" "high")
assert_nonempty "DSB-ERR blocked (high finding blocks)" "$REASON"

echo
echo "--- CASE DSB-NOLOG: absent review-log at HEAD IS a block ---"
DIR=$(make_repo task)
H1=$(commit_change "$DIR" "feat.txt" "feature")
HARNESS="$DIR/.claude/.harness"
CONTRACTS="$TESTS_DIR/../contracts"
DS="$DIR/.claude/.harness/done-state/tmp.json"
jq --arg sha "$H1" '.verified_sha = $sha' "$FIX/done-state-green.json" > "$DS"
REASON=$(run_blocked "$DIR" "$DS" "$H1" "$H1~1" "$HARNESS" "$CONTRACTS" "high")
assert_eq "DSB-NOLOG blocked (no review-log)" "$REASON" "no review-log at HEAD"

# ---------------------------------------------------------------------------
echo
echo "=============================================================="
if [ "$FAILS" -eq 0 ]; then
  printf ' ALL %d ASSERTIONS PASSED\n' "$CASES"
  echo "=============================================================="
  exit 0
else
  printf ' %d/%d ASSERTIONS FAILED\n' "$FAILS" "$CASES"
  echo "=============================================================="
  exit 1
fi
