#!/bin/bash
#
# Tests for dod-verify-preflight.sh's narrow safe tree-baseline auto-seed.
#
# Regression coverage for: branching mid-session (after SessionStart already
# pinned a baseline for a DIFFERENT branch) leaves the new branch's task key
# with no tree-base file — a guaranteed deadlock, previously requiring a full
# session restart even when nothing was actually at risk. Preflight now seeds
# the baseline on the spot when, and only when, the task key is new AND the
# working tree is genuinely clean (nothing to launder as "pre-existing").
#
# Covers:
#   1  new branch mid-session, CLEAN tree    → auto-seeded, non-blocking warning, exit 0
#   2  new branch mid-session, DIRTY tree    → still hard-blocks, no file written
#   3  session mode, no baseline at all      → still hard-blocks (no task-key equivalent)
#   4  auto-seeded baseline is genuinely empty (matches a clean `git status --porcelain`)
#   5  auto-seed only fires ONCE — a second preflight run does not touch an
#      already-pinned baseline (idempotent; existing pinned file untouched by
#      later drift)
#
# Runs against the source-tree scripts, resolved relative to this test — no
# install needed. PASS/FAIL family (ok/bad/eq), matching sibling suites.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"

SESSION_START="$SCRIPTS/dod-session-start.sh"
PREFLIGHT="$SCRIPTS/dod-verify-preflight.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "== test-dod-preflight =="

run_session_start() {
  printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SESSION_START" >/dev/null 2>&1
}

# make_repo — like hc__test_make_repo, but disables baseline_snapshot in the
# fixture config. This suite exercises tree-baseline pinning only, not the
# (unrelated) test-snapshot feature; the shared fixture's baseline_snapshot:
# true would otherwise surface a separate, expected "no test command
# detected" PROBLEM that has nothing to do with what this suite is testing.
make_repo() {
  local r; r=$(hc__test_make_repo "$1")
  local tmp; tmp=$(mktemp)
  jq '.baseline_snapshot = false' "$r/.claude/done-config.json" > "$tmp" && mv "$tmp" "$r/.claude/done-config.json"
  # done-config.json is TRACKED (hc__test_make_repo gitignores only
  # .claude/.harness/), so this edit must be committed here — otherwise every
  # repo this suite builds starts with an uncommitted tracked-file diff,
  # which is indistinguishable from real dirty work and would (correctly)
  # make the clean-tree auto-seed cases refuse to fire.
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -q -m "test: disable baseline_snapshot" >/dev/null 2>&1
  printf '%s' "$r"
}

run_preflight() {
  # $1=repo $2=session_id → stdout captured, rc via $?
  CLAUDE_PROJECT_DIR="$1" bash "$PREFLIGHT" "$2"
}

# ---------------------------------------------------------------------------
# Case 1 — new branch mid-session, CLEAN tree: auto-seeded, exit 0.
# ---------------------------------------------------------------------------
R=$(make_repo)
run_session_start "$R" p1
git -C "$R" checkout -q -b feature/mid-session-clean
OUT=$(run_preflight "$R" p1)
RC=$?
[ "$RC" -eq 0 ] && ok "case 1: new branch, clean tree → preflight exits 0" \
  || bad "case 1: exits 0" "rc=$RC out=$OUT"
[ -f "$R/.claude/.harness/tree-base/br-feature-mid-session-clean.dirty" ] \
  && ok "case 1: tree baseline auto-seeded for the new task key" \
  || bad "case 1: tree baseline file written" "$(ls "$R/.claude/.harness/tree-base/" 2>/dev/null)"
printf '%s' "$OUT" | grep -q "safely seeded on the spot" \
  && ok "case 1: output explains the auto-seed" \
  || bad "case 1: output explains auto-seed" "$OUT"
printf '%s' "$OUT" | grep -q "^PROBLEM" \
  && bad "case 1: no PROBLEM lines expected" "$OUT" \
  || ok "case 1: no PROBLEM lines (warning only, non-blocking)"

# ---------------------------------------------------------------------------
# Case 2 — new branch mid-session, DIRTY tree: still hard-blocks.
# ---------------------------------------------------------------------------
R=$(make_repo)
run_session_start "$R" p2
git -C "$R" checkout -q -b feature/mid-session-dirty
echo "in-progress work" > "$R/wip.txt"
OUT=$(run_preflight "$R" p2)
RC=$?
[ "$RC" -ne 0 ] && ok "case 2: new branch, dirty tree → preflight still blocks" \
  || bad "case 2: still blocks" "rc=$RC out=$OUT"
[ ! -f "$R/.claude/.harness/tree-base/br-feature-mid-session-dirty.dirty" ] \
  && ok "case 2: no tree baseline written (nothing auto-seeded over dirty work)" \
  || bad "case 2: no file should be written" "$(ls "$R/.claude/.harness/tree-base/" 2>/dev/null)"
printf '%s' "$OUT" | grep -q "NOT safe to auto-seed" \
  && ok "case 2: output explains why it refused to auto-seed" \
  || bad "case 2: output explains refusal" "$OUT"

# ---------------------------------------------------------------------------
# Case 3 — session mode (on trunk), no baseline: still hard-blocks (no
# equivalent safe-seed path — session-mode baseline is per-session, not
# per-branch, so there is no "never seen before" case to exploit).
# ---------------------------------------------------------------------------
R=$(make_repo)
mkdir -p "$R/.claude/.harness/baselines"
OUT=$(run_preflight "$R" p3-nobaseline)
RC=$?
[ "$RC" -ne 0 ] && ok "case 3: session mode, no baseline → still blocks" \
  || bad "case 3: still blocks" "rc=$RC out=$OUT"
printf '%s' "$OUT" | grep -q "restart the session" \
  && ok "case 3: still tells the user to restart (no auto-seed in session mode)" \
  || bad "case 3: restart guidance present" "$OUT"

# ---------------------------------------------------------------------------
# Case 4 — the auto-seeded baseline is genuinely empty (matches a clean tree).
# ---------------------------------------------------------------------------
R=$(make_repo)
run_session_start "$R" p4
git -C "$R" checkout -q -b feature/mid-session-empty-check
run_preflight "$R" p4 >/dev/null
F="$R/.claude/.harness/tree-base/br-feature-mid-session-empty-check.dirty"
eq "case 4: auto-seeded file is empty (0 lines, matching a clean tree)" "0" \
  "$(wc -l < "$F" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
# Case 5 — auto-seed only fires once: a second preflight run does not
# re-touch (or corrupt) an already-pinned baseline.
# ---------------------------------------------------------------------------
R=$(make_repo)
run_session_start "$R" p5
git -C "$R" checkout -q -b feature/mid-session-idempotent
run_preflight "$R" p5 >/dev/null
F="$R/.claude/.harness/tree-base/br-feature-mid-session-idempotent.dirty"
FIRST_MTIME=$(stat -c '%Y' "$F" 2>/dev/null || stat -f '%m' "$F" 2>/dev/null)
sleep 1
# introduce uncommitted work AFTER the first pin — if preflight re-seeds, this
# would get wrongly whitelisted as "pre-existing"; the pin-once rule must hold.
echo "should NOT be whitelisted" > "$R/should-not-be-baseline.txt"
run_preflight "$R" p5 >/dev/null
SECOND_MTIME=$(stat -c '%Y' "$F" 2>/dev/null || stat -f '%m' "$F" 2>/dev/null)
eq "case 5: second preflight run does not rewrite the already-pinned baseline" \
  "$FIRST_MTIME" "$SECOND_MTIME"
grep -q "should-not-be-baseline.txt" "$F" 2>/dev/null \
  && bad "case 5: later uncommitted work must NOT appear in the pinned baseline" \
  || ok "case 5: later uncommitted work correctly absent from the pinned baseline"

# ---------------------------------------------------------------------------
# Case 6 — two branches auto-seeded independently, then switch back: each
# task key's file is isolated by its own path (keyed off HC_TASK_KEY, which
# is branch-derived) — switching to branch B and auto-seeding it must not
# touch or corrupt branch A's already-pinned file.
# ---------------------------------------------------------------------------
R=$(make_repo)
run_session_start "$R" p6
git -C "$R" checkout -q -b feature/branch-a
run_preflight "$R" p6 >/dev/null
FA="$R/.claude/.harness/tree-base/br-feature-branch-a.dirty"
[ -f "$FA" ] && ok "case 6: branch A auto-seeded" || bad "case 6: branch A auto-seeded"
A_MTIME=$(stat -c '%Y' "$FA" 2>/dev/null || stat -f '%m' "$FA" 2>/dev/null)

sleep 1
git -C "$R" checkout -q main
git -C "$R" checkout -q -b feature/branch-b
echo "branch b in-progress work" > "$R/branch-b-wip.txt"
run_preflight "$R" p6 >/dev/null
FB="$R/.claude/.harness/tree-base/br-feature-branch-b.dirty"
[ ! -f "$FB" ] && ok "case 6: branch B (dirty tree) correctly NOT auto-seeded" \
  || bad "case 6: branch B should not have been auto-seeded (dirty tree)"

# switch back to branch A: its file must be untouched by branch B's activity.
git -C "$R" checkout -q feature/branch-a 2>/dev/null
A_MTIME_AFTER=$(stat -c '%Y' "$FA" 2>/dev/null || stat -f '%m' "$FA" 2>/dev/null)
eq "case 6: branch A's baseline untouched after branch B's (blocked) auto-seed attempt" \
  "$A_MTIME" "$A_MTIME_AFTER"

echo
echo "test-dod-preflight: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
