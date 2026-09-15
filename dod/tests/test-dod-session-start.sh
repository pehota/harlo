#!/bin/bash
#
# Tests for dod-session-start.sh (SessionStart hook) and its downstream effect
# on dod-write.sh's session-id resolution.
#
# Regression coverage for the bug where dod-write.sh, invoked with no
# __session_id in its payload (the real shape the dod-collect skill produces),
# always fell back to the literal "unknown-session" — because nothing ever
# recorded the REAL session id anywhere dod-write.sh could find it. The
# contract then got written under a key (session-unknown-session, or a
# session-scoped key on trunk) that dod-gate.sh's own hook-stdin session_id
# never matches, silently forever-blocking (or worse, silently never
# blocking, since a nonexistent contract file looks identical to "nothing
# collected yet").
#
# Covers:
#   1  SessionStart writes the current-session marker + baseline .sha/.dirty
#   2  dod-write.sh with NO __session_id resolves via the marker, not "unknown-session"
#   3  task mode (feature branch): key is br-<branch>, matches what dod-gate.sh
#      AND dod-complete-task.sh resolve from the SAME real session id — full
#      round trip (write contract, arm the claim latch, gate) blocks correctly
#   4  compact source preserves an existing session baseline (does not re-seed)
#   5  non-git dir: SessionStart no-ops without crashing
#
# Runs against the source-tree scripts, resolved relative to this test — no
# install needed. PASS/FAIL family (ok/bad/eq), matching sibling suites.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"

SESSION_START="$SCRIPTS/dod-session-start.sh"
WRITE="$SCRIPTS/dod-write.sh"
GATE="$SCRIPTS/dod-gate.sh"
CLAIM="$SCRIPTS/dod-complete-task.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "== test-dod-session-start =="

is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

run_session_start() {
  # $1=repo $2=session_id $3=source (optional)
  printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s"}' "$2" "${3:-startup}" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SESSION_START"
}

run_write_no_session_id() {
  # $1=repo $2=payload-json (no __session_id key)
  printf '%s' "$2" | CLAUDE_PROJECT_DIR="$1" bash "$WRITE"
}

run_gate() {
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null
}

# arm_claim <repo> <session_id> — the gate is claim-driven and stays silent
# until dod-complete-task.sh arms task-dod/claim-<task_key>. Calling the REAL
# script is the point of this suite: it derives the task key from the same
# session id the gate does, so a keying mismatch between the two fails here.
arm_claim() { CLAUDE_PROJECT_DIR="$1" bash "$CLAIM" "$2" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Case 1 — SessionStart writes current-session marker + baseline .sha/.dirty.
# ---------------------------------------------------------------------------
R=$(hc__test_make_repo)
run_session_start "$R" s1 >/dev/null 2>&1
eq "case 1: current-session marker recorded" "s1" "$(cat "$R/.claude/.harness/current-session" 2>/dev/null)"
[ -f "$R/.claude/.harness/baselines/s1.sha" ] \
  && ok "case 1: baseline .sha recorded" \
  || bad "case 1: baseline .sha recorded"
[ -f "$R/.claude/.harness/baselines/s1.dirty" ] \
  && ok "case 1: tree baseline .dirty recorded" \
  || bad "case 1: tree baseline .dirty recorded"
eq "case 1: baseline .sha matches HEAD" "$(git -C "$R" rev-parse HEAD)" \
  "$(cat "$R/.claude/.harness/baselines/s1.sha" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Case 2 — dod-write.sh with NO __session_id resolves via the marker, not the
# "unknown-session" fallback.
# ---------------------------------------------------------------------------
R=$(hc__test_make_repo)
run_session_start "$R" s2 >/dev/null 2>&1
mkdir -p "$R/.claude/.harness/task-dod"
OUT=$(run_write_no_session_id "$R" '{"created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}')
RC=$?
[ "$RC" -eq 0 ] && ok "case 2: dod-write.sh with no __session_id succeeds after SessionStart ran" \
  || bad "case 2: write succeeds" "rc=$RC out=$OUT"
[ ! -f "$R/.claude/.harness/task-dod/session-unknown-session.json" ] \
  && ok "case 2: contract NOT written under session-unknown-session" \
  || bad "case 2: contract wrongly keyed under session-unknown-session"
# session mode here (default branch == trunk), so the key is session-<real-id>.
[ -f "$R/.claude/.harness/task-dod/session-s2.json" ] \
  && ok "case 2: contract written under the REAL session id (session-s2)" \
  || bad "case 2: contract keyed by real session id" "$(ls "$R/.claude/.harness/task-dod/" 2>/dev/null)"

# ---------------------------------------------------------------------------
# Case 3 — task mode (feature branch): full round trip. SessionStart with a
# real id, dod-write.sh with no __session_id, dod-gate.sh with the SAME real
# id — the gate must find and block on the contract (proves the keys match).
# ---------------------------------------------------------------------------
R=$(hc__test_make_repo task)
run_session_start "$R" s3 >/dev/null 2>&1
mkdir -p "$R/.claude/.harness/task-dod/verified"
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
OUT=$(run_write_no_session_id "$R" '{"created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}')
RC=$?
[ "$RC" -eq 0 ] && ok "case 3: task-mode write with no __session_id succeeds" \
  || bad "case 3: task-mode write succeeds" "rc=$RC out=$OUT"
[ -f "$R/.claude/.harness/task-dod/br-feature-x.json" ] \
  && ok "case 3: contract written under the branch-derived key" \
  || bad "case 3: contract keyed by branch" "$(ls "$R/.claude/.harness/task-dod/" 2>/dev/null)"
arm_claim "$R" s3
[ -f "$R/.claude/.harness/task-dod/claim-br-feature-x" ] \
  && ok "case 3: the claim latch is keyed the same way the contract is (br-feature-x)" \
  || bad "case 3: claim latch keyed by branch" "$(ls "$R/.claude/.harness/task-dod/" 2>/dev/null)"
GATE_OUT=$(run_gate "$R" s3)
is_block "$GATE_OUT" && ok "case 3: gate with the SAME real session id finds + blocks on the contract (keys match)" \
  || bad "case 3: gate finds the contract written by dod-write.sh" "$GATE_OUT"

# ---------------------------------------------------------------------------
# Case 4 — compact source preserves an existing session baseline.
# ---------------------------------------------------------------------------
R=$(hc__test_make_repo)
run_session_start "$R" s4 startup >/dev/null 2>&1
ORIG_SHA=$(cat "$R/.claude/.harness/baselines/s4.sha")
echo "uncommitted mid-task work" > "$R/mid-task.txt"
run_session_start "$R" s4 compact >/dev/null 2>&1
eq "case 4: compact preserves the existing baseline .sha (does not re-snapshot dirty HEAD)" \
  "$ORIG_SHA" "$(cat "$R/.claude/.harness/baselines/s4.sha")"

# ---------------------------------------------------------------------------
# Case 5 — non-git dir: SessionStart no-ops without crashing.
# ---------------------------------------------------------------------------
ND=$(hc__test_mktemp_d); CLEANUP_DIRS="$CLEANUP_DIRS $ND"
mkdir -p "$ND"
run_session_start "$ND" s5 >/dev/null 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "case 5: non-git dir → SessionStart exits 0 (no crash)" \
  || bad "case 5: non-git dir exits 0" "rc=$RC"
eq "case 5: non-git dir records a no-git sentinel" "no-git" \
  "$(cat "$ND/.claude/.harness/baselines/s5.sha" 2>/dev/null)"

echo
echo "test-dod-session-start: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
