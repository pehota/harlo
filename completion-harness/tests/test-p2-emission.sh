#!/bin/bash
#
# P2 emission test — SessionStart proactive steering + Stop-gate FSM reasons.
#
# Zero-dependency: bash + git + jq only (the same deps the scripts need). No bats.
# Each case spins up a real git repo in a mktemp dir, drives it into a known FSM
# state (reusing the exact scaffolding shape from test-hc-state.sh), then RUNS the
# REAL hook scripts (baseline-snapshot.sh for SessionStart, done-gate.sh for Stop)
# with crafted hook stdin + CLAUDE_PROJECT_DIR, captures stdout, and parses it
# with jq. The scripts source the REAL harness-common.sh via their own $0 sibling.
#
# It proves the P2 contract:
#   SessionStart — emits hookSpecificOutput.additionalContext (agent-visible) in
#     the ACTIONABLE states S1/S2/S4, carrying the D4 review-ownership directive
#     plus the FSM next-action; SILENT (no additionalContext) in S0/S5. When a
#     systemMessage is also produced, BOTH keys coexist in ONE valid JSON object.
#   Stop gate  — the block() reason is the canonical FSM next-action string;
#     every formerly-blocking case still blocks (no-behavior-change: reasons
#     changed, blocking did not).
#
# Prints PASS/FAIL per case; exits non-zero on any failure.

set -u

# --- locate scripts + fixtures (relative to THIS script) --------------------
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$TESTS_DIR/../scripts"
BASELINE="$SCRIPTS/baseline-snapshot.sh"
DONEGATE="$SCRIPTS/done-gate.sh"
FIX="$TESTS_DIR/fixtures"

for f in "$BASELINE" "$DONEGATE" "$SCRIPTS/harness-common.sh"; do
  if [ ! -f "$f" ]; then
    echo "FATAL: cannot find $f" >&2
    exit 1
  fi
done

FAILS=0
CASES=0

# --- assert helpers ---------------------------------------------------------
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  CASES=$((CASES + 1))
  if [ "$actual" = "$expected" ]; then
    printf 'PASS  %s (= %s)\n' "$label" "$expected"
  else
    printf 'FAIL  %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  CASES=$((CASES + 1))
  case "$haystack" in
    *"$needle"*) printf 'PASS  %s (contains "%s")\n' "$label" "$needle" ;;
    *) printf 'FAIL  %s: [%s] does not contain [%s]\n' "$label" "$haystack" "$needle"
       FAILS=$((FAILS + 1)) ;;
  esac
}

assert_empty() {
  local label="$1" actual="$2"
  CASES=$((CASES + 1))
  if [ -z "$actual" ]; then
    printf 'PASS  %s (empty as expected)\n' "$label"
  else
    printf 'FAIL  %s: expected empty, got [%s]\n' "$label" "$actual"
    FAILS=$((FAILS + 1))
  fi
}

assert_nonempty() {
  local label="$1" actual="$2"
  CASES=$((CASES + 1))
  if [ -n "$actual" ]; then
    printf 'PASS  %s (non-empty)\n' "$label"
  else
    printf 'FAIL  %s: expected non-empty, got empty\n' "$label"
    FAILS=$((FAILS + 1))
  fi
}

# --- repo scaffolding (mirrors test-hc-state.sh) ----------------------------
CLEANUP_DIRS=""
cleanup() {
  local d
  for d in $CLEANUP_DIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

make_repo() {
  local dir
  dir=$(mktemp -d)
  CLEANUP_DIRS="$CLEANUP_DIRS $dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name "t"

  mkdir -p "$dir/.claude/.harness/done-state" \
           "$dir/.claude/.harness/review-log" \
           "$dir/.claude/.harness/baselines" \
           "$dir/.claude/.harness/tree-base"
  # baseline_snapshot OFF: keep the SessionStart hook hermetic/fast (no detached
  # test run). Everything else mirrors the shared fixture (trunk main, etc).
  jq '.baseline_snapshot = false' "$FIX/done-config.json" \
    > "$dir/.claude/done-config.json"

  echo ".claude/.harness/" > "$dir/.gitignore"

  echo "root" > "$dir/root.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "root"

  # Every P2 case runs on a task branch (task mode: branch != trunk) so the tree
  # baseline is pinned ONCE and never re-seeded across the two SessionStart runs
  # the S1 case needs.
  git -C "$dir" checkout -q -b feature/x

  printf '%s' "$dir"
}

commit_change() {
  local dir="$1" name="$2" content="$3"
  echo "$content" > "$dir/$name"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "add $name"
  git -C "$dir" rev-parse HEAD
}

task_key_for_branch() {
  printf 'br-%s' "$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g')"
}

write_done_state() {
  local dir="$1" fixture="$2" head="$3" key="$4"
  jq --arg sha "$head" '.verified_sha = $sha' "$fixture" \
    > "$dir/.claude/.harness/done-state/$key.json"
}

write_review_log() {
  local dir="$1" fixture="$2" head="$3"
  shift 3
  local files_json="[]"
  if [ "$#" -gt 0 ]; then
    files_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  fi
  jq --arg sha "$head" --argjson files "$files_json" \
    '.reviewed_sha = $sha | .files_reviewed = $files' "$fixture" \
    > "$dir/.claude/.harness/review-log/$head.json"
}

# Run the REAL SessionStart hook (baseline-snapshot.sh). Echoes its stdout (the
# single JSON object, or empty for a fully-silent session).
run_session_start() {
  local dir="$1" sid="$2" source="${3:-startup}"
  local input
  input=$(jq -n --arg s "$sid" --arg src "$source" \
    '{session_id:$s, source:$src}')
  printf '%s' "$input" | CLAUDE_PROJECT_DIR="$dir" bash "$BASELINE" 2>/dev/null
}

# Run the REAL Stop hook (done-gate.sh). Echoes its stdout (the block JSON, or
# empty on allow).
run_stop_gate() {
  local dir="$1" sid="$2"
  local input
  input=$(jq -n --arg s "$sid" '{session_id:$s, stop_hook_active:false}')
  printf '%s' "$input" | CLAUDE_PROJECT_DIR="$dir" bash "$DONEGATE" 2>/dev/null
}

# Extract hookSpecificOutput.additionalContext from a SessionStart stdout blob.
# Empty when the key is absent OR the blob is empty (silent).
addl_ctx() {
  local blob="$1"
  [ -z "$blob" ] && { printf ''; return 0; }
  printf '%s' "$blob" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null
}

D4_PHRASE="/done owns the Step-5 independent code review"

echo "=============================================================="
echo " P2 emission test — SessionStart steering + Stop-gate reasons"
echo "=============================================================="

# ===========================================================================
# SessionStart emission
# ===========================================================================

# --- S0: HEAD==base, clean tree → NO additionalContext (silent). -----------
echo
echo "--- SessionStart S0: idle → silent (no additionalContext) ---"
DIR=$(make_repo)
OUT=$(run_session_start "$DIR" "sess-s0")
CTX=$(addl_ctx "$OUT")
assert_empty "S0 additionalContext absent" "$CTX"

# --- S1: introduced uncommitted file → additionalContext w/ remedy + D4. ----
# Realistic flow: SessionStart pins a CLEAN baseline first, THEN the agent
# introduces a file; a subsequent SessionStart (task mode never re-seeds the
# baseline) classifies the file as introduced → S1.
echo
echo "--- SessionStart S1: working → additionalContext (finish the slice + D4) ---"
DIR=$(make_repo)
run_session_start "$DIR" "sess-s1" "startup" >/dev/null   # pin clean baseline
echo "wip" > "$DIR/wip.txt"                                # introduced after pin
OUT=$(run_session_start "$DIR" "sess-s1" "resume")
CTX=$(addl_ctx "$OUT")
assert_contains "S1 additionalContext has remedy"    "$CTX" "finish the slice"
assert_contains "S1 additionalContext has D4 directive" "$CTX" "$D4_PHRASE"

# --- S2: committed, no done-state → additionalContext w/ /done remedy. ------
echo
echo "--- SessionStart S2: committed-unverified → additionalContext (/done) ---"
DIR=$(make_repo)
commit_change "$DIR" "feat.txt" "feature" >/dev/null
OUT=$(run_session_start "$DIR" "sess-s2")
CTX=$(addl_ctx "$OUT")
assert_contains "S2 additionalContext has /done remedy" "$CTX" \
  "run /done to verify the changeset"
assert_contains "S2 additionalContext has D4 directive" "$CTX" "$D4_PHRASE"

# --- S4: valid done-state at HEAD, red tests, no escalation → fix failing. --
echo
echo "--- SessionStart S4: blocked-on-tests → additionalContext (fix failing tests) ---"
DIR=$(make_repo)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
jq --arg sha "$H1" '.verified_sha = $sha | .tests.exit_code = 1' \
  "$FIX/done-state-green.json" > "$DIR/.claude/.harness/done-state/$KEY.json"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
OUT=$(run_session_start "$DIR" "sess-s4")
CTX=$(addl_ctx "$OUT")
assert_contains "S4 additionalContext has tests remedy" "$CTX" "fix failing tests"
assert_contains "S4 additionalContext has D4 directive" "$CTX" "$D4_PHRASE"

# --- S5: green done-state + covering review-log → NO additionalContext. -----
echo
echo "--- SessionStart S5: verified → silent (no additionalContext) ---"
DIR=$(make_repo)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
OUT=$(run_session_start "$DIR" "sess-s5")
CTX=$(addl_ctx "$OUT")
assert_empty "S5 additionalContext absent" "$CTX"

# --- coexistence: systemMessage AND additionalContext in ONE valid object. --
echo
echo "--- SessionStart coexistence: systemMessage + additionalContext in ONE object ---"
# Task-branch repo → committing a change with no done-state gives S2
# (committed work past the pinned fork base), an ACTIONABLE state →
# additionalContext is emitted. INDEPENDENTLY force a systemMessage by enabling
# baseline_snapshot with no detectable test command: SessionStart's FAIL-LOUD
# inert branch appends the "snapshot could not run" guidance to SYS_MSG
# (synchronous — the detached background path only runs when a test command
# exists). Both keys must then coexist in ONE JSON object jq parses as one doc.
DIR=$(make_repo)
jq '.baseline_snapshot = true' "$DIR/.claude/done-config.json" \
  > "$DIR/.claude/done-config.json.tmp" \
  && mv "$DIR/.claude/done-config.json.tmp" "$DIR/.claude/done-config.json"
commit_change "$DIR" "feat.txt" "feature" >/dev/null   # committed work past base → S2
OUT=$(run_session_start "$DIR" "sess-coexist")
# The whole blob must be exactly ONE valid JSON object.
assert_eq "coexist stdout is one valid JSON object" \
  "$(printf '%s' "$OUT" | jq -s 'length' 2>/dev/null)" "1"
SYSMSG=$(printf '%s' "$OUT" | jq -r '.systemMessage // ""' 2>/dev/null)
CTX=$(addl_ctx "$OUT")
assert_nonempty "coexist systemMessage present" "$SYSMSG"
assert_nonempty "coexist additionalContext present" "$CTX"
assert_contains "coexist additionalContext has D4 directive" "$CTX" "$D4_PHRASE"

# ===========================================================================
# Stop gate reason — the FSM next-action string; blocking preserved.
# ===========================================================================

# --- S2 (no done-state) → block, reason == the canonical /done string. ------
echo
echo "--- Stop gate S2: no done-state → block w/ /done reason ---"
DIR=$(make_repo)
commit_change "$DIR" "feat.txt" "feature" >/dev/null
run_session_start "$DIR" "sess-g2" >/dev/null   # pin baseline so gate resolves
OUT=$(run_stop_gate "$DIR" "sess-g2")
assert_eq "S2 decision==block" \
  "$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)" "block"
assert_eq "S2 reason == canonical" \
  "$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)" \
  "run /done to verify the changeset (owns the Step-5 review)"

# --- S1 (introduced uncommitted) → block, reason starts "finish the slice". -
echo
echo "--- Stop gate S1: introduced uncommitted → block w/ 'finish the slice' ---"
# The gate's tree-blocker reason (Step 6) fires only AFTER Steps 4/4b/5 pass —
# a valid done-state stamped at HEAD (else Step 4/5 would block first with the
# S2 string). So: commit feat, pin the clean baseline, write a green done-state +
# covering review-log at HEAD, THEN introduce an uncommitted file → Step 6 blocks
# with the 'finish the slice' reason.
DIR=$(make_repo)
H1=$(commit_change "$DIR" "feat.txt" "feature")
run_session_start "$DIR" "sess-g1" "startup" >/dev/null   # pin clean baseline at HEAD
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
echo "wip" > "$DIR/wip.txt"                                # introduced after pin
OUT=$(run_stop_gate "$DIR" "sess-g1")
assert_eq "S1 decision==block" \
  "$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)" "block"
REASON=$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)
case "$REASON" in
  "finish the slice"*) printf 'PASS  S1 reason starts with "finish the slice"\n'; CASES=$((CASES+1)) ;;
  *) printf 'FAIL  S1 reason: [%s] does not start with "finish the slice"\n' "$REASON"
     CASES=$((CASES+1)); FAILS=$((FAILS+1)) ;;
esac

# --- S4 red tests → block, reason == fix failing tests string. --------------
echo
echo "--- Stop gate S4: red tests → block w/ 'fix failing tests' ---"
DIR=$(make_repo)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
jq --arg sha "$H1" '.verified_sha = $sha | .tests.exit_code = 1' \
  "$FIX/done-state-green.json" > "$DIR/.claude/.harness/done-state/$KEY.json"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
run_session_start "$DIR" "sess-g4" >/dev/null
OUT=$(run_stop_gate "$DIR" "sess-g4")
assert_eq "S4-tests decision==block" \
  "$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)" "block"
assert_eq "S4-tests reason == canonical" \
  "$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)" \
  "fix failing tests, re-commit, re-run /done"

# --- S4 coverage gap → block, reason contains 'review the uncovered files'. -
echo
echo "--- Stop gate S4: coverage gap → block w/ 'review the uncovered files' ---"
DIR=$(make_repo)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1"   # empty files_reviewed → gap
run_session_start "$DIR" "sess-g4c" >/dev/null
OUT=$(run_stop_gate "$DIR" "sess-g4c")
assert_eq "S4-coverage decision==block" \
  "$(printf '%s' "$OUT" | jq -r '.decision // ""' 2>/dev/null)" "block"
assert_contains "S4-coverage reason has uncovered-files phrase" \
  "$(printf '%s' "$OUT" | jq -r '.reason // ""' 2>/dev/null)" \
  "review the uncovered files"

# --- S5 green → NO block (exit 0, empty stdout). ----------------------------
echo
echo "--- Stop gate S5: green → allow (no block on stdout) ---"
DIR=$(make_repo)
H1=$(commit_change "$DIR" "feat.txt" "feature")
KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "feat.txt"
run_session_start "$DIR" "sess-g5" >/dev/null
OUT=$(run_stop_gate "$DIR" "sess-g5")
assert_empty "S5 no block emitted" \
  "$(printf '%s' "$OUT" | jq -r 'select(.decision == "block") | .decision' 2>/dev/null)"

# ===========================================================================
# Regression guard — every formerly-blocking case STILL blocks (reasons
# changed, blocking did not). Asserted structurally: decision=="block" present.
# ===========================================================================
echo
echo "--- Regression guard: all formerly-blocking cases still emit decision==block ---"
regression_still_blocks() {
  local label="$1" dir="$2" sid="$3"
  local out dec
  out=$(run_stop_gate "$dir" "$sid")
  dec=$(printf '%s' "$out" | jq -r '.decision // ""' 2>/dev/null)
  assert_eq "$label still blocks" "$dec" "block"
}

# S2 (no done-state)
DIR=$(make_repo); commit_change "$DIR" "f.txt" "x" >/dev/null
run_session_start "$DIR" "rg-s2" >/dev/null
regression_still_blocks "reg S2 (no done-state)" "$DIR" "rg-s2"

# S1 (introduced uncommitted)
DIR=$(make_repo); run_session_start "$DIR" "rg-s1" "startup" >/dev/null
echo "wip" > "$DIR/wip.txt"
regression_still_blocks "reg S1 (introduced)" "$DIR" "rg-s1"

# S4 red tests
DIR=$(make_repo); H1=$(commit_change "$DIR" "f.txt" "x"); KEY=$(task_key_for_branch "feature/x")
jq --arg sha "$H1" '.verified_sha = $sha | .tests.exit_code = 1' \
  "$FIX/done-state-green.json" > "$DIR/.claude/.harness/done-state/$KEY.json"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1" "f.txt"
run_session_start "$DIR" "rg-s4" >/dev/null
regression_still_blocks "reg S4 (red tests)" "$DIR" "rg-s4"

# S4 coverage gap
DIR=$(make_repo); H1=$(commit_change "$DIR" "f.txt" "x"); KEY=$(task_key_for_branch "feature/x")
write_done_state "$DIR" "$FIX/done-state-green.json" "$H1" "$KEY"
write_review_log "$DIR" "$FIX/review-log-green.json" "$H1"
run_session_start "$DIR" "rg-s4c" >/dev/null
regression_still_blocks "reg S4 (coverage gap)" "$DIR" "rg-s4c"

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
