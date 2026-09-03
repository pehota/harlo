#!/bin/bash
#
# Acceptance tests for the session commit ledger:
#   - completion-harness/scripts/commit-ledger.sh (the PostToolUse(Bash) hook
#     that WRITES baselines/<session_id>.own-commits)
#   - harness-common.sh's hc__resolve_session_base, which now READS that
#     ledger (via hc__commit_in_ledger) as the PRIMARY "is this the session's
#     own commit" signal for session-mode base-advance, falling back to the
#     pre-existing email-only predicate (hc__commit_confidently_foreign) only
#     when no ledger was ever written this session.
#
# THE BUG THIS FIXES: a commit made directly by the human (terminal, `!`
# passthrough) under the SAME git identity Claude Code commits under — the
# common case, there is no separate "Claude" git identity — could never be
# proven foreign by email alone. Base-advance never advanced past it, so the
# Stop gate demanded /done review of commits nobody wants reviewed by this
# session, every turn, forever. Case 4 below is that exact scenario: it FAILS
# under the old email-only-only code and PASSES under the ledger-first code.
#
# Case 7 and Case 8 are regression locks for two issues an independent review
# found in the FIRST cut of this ledger (both confirmed real, both fixed in
# commit-ledger.sh before this suite was extended):
#   Case 7 (cursor-recovery): once the ledger has any content, the cursor is
#     ALWAYS its tail line. A history rewrite (amend/rebase) that orphans that
#     one commit made the cursor permanently stale — every future call kept
#     re-deriving the same forever-failing ancestor check, so the ledger
#     stopped growing FOR THE REST OF THE SESSION. Real commits made after the
#     rewrite then looked absent from the ledger — confidently-foreign — and
#     base-advance would silently sweep past them (a false-PASS the exact
#     opposite direction of what this file's own fail-safe rule requires).
#   Case 8 (command-shape gate): the sweep used to run unconditionally on
#     EVERY Bash call, walking the whole cursor..HEAD range regardless of
#     what triggered it. A foreign commit that landed before some LATER,
#     unrelated Bash call (e.g. `git status`) got swept into the ledger by
#     that unrelated call, misattributing it as session-owned. The hook now
#     only sweeps when the JUST-RUN command looks commit-shaped
#     (looks_like_commit_command in commit-ledger.sh).
#
# Same fixture idiom as test-identity.sh / test-autobranch.sh: throwaway
# mktemp git repos via hc__test_mktemp_d, PASS/FAIL via ok/bad/eq, harness-
# common.sh sourced in-process (for hc_resolve / hc__resolve_session_base)
# alongside driving the real commit-ledger.sh script as a subprocess (for the
# hook's own file-writing behavior). No `set -e` — every case runs and reports.

BUNDLE_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
HOOK="$BUNDLE_DIR/commit-ledger.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

# hc_resolve / hc__resolve_session_base directly, for the base-advance cases
# (4-6) — same pattern as test-identity.sh's resolve_inproc.
HC_COMMON="$BUNDLE_DIR/harness-common.sh"
if [ -f "$HC_COMMON" ]; then
  # shellcheck source=/dev/null
  . "$HC_COMMON" 2>/dev/null
fi

CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# Fresh temp git repo on trunk `main`, no remote, local identity — stays on
# main throughout (session mode; task mode is explicitly out of scope for the
# ledger per the design: hc__resolve_task_base never consults it).
new_repo() {
  REPO=$(hc__test_mktemp_d)
  CLEANUP+=("$REPO")
  git init -b main "$REPO" >/dev/null 2>&1 || {
    git init "$REPO" >/dev/null 2>&1
    ( cd "$REPO" && git branch -M main >/dev/null 2>&1 )
  }
  git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
  git -C "$REPO" config user.name  "Test" >/dev/null 2>&1
}

commit_file() {
  printf 'content-%s\n' "$1" > "$REPO/$1"
  git -C "$REPO" add "$1" >/dev/null 2>&1
  git -C "$REPO" commit -qm "add $1" >/dev/null 2>&1
}

# Seed the SessionStart-pinned baseline .sha, as baseline-snapshot.sh would
# have written it. $1 = session id, $2 = sha.
seed_baseline() {
  mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
  printf '%s\n' "$2" > "$REPO/.claude/.harness/baselines/${1}.sha"
}

ledger_path() { printf '%s/.claude/.harness/baselines/%s.own-commits' "$REPO" "$1"; }

# Drive the real hook script as a PostToolUse(Bash) subprocess would fire it.
# $1 = session id, $2 = tool_input.command (default a commit-shaped command —
# most existing cases want the sweep to actually run; cases that specifically
# test the command-shape GATE pass a non-commit command explicitly, e.g.
# "git status").
run_hook() {
  local cmd="${2:-git commit -m x}"
  HOOK_RC_OUT=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$cmd" \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>/dev/null)
  HOOK_RC=$?
}

# In-process hc_resolve for a session id, against $REPO. Sets HC_MODE HC_BASE
# HC_BASE_ORIG etc. Same pattern as test-identity.sh's resolve_inproc.
resolve_inproc() { CLAUDE_PROJECT_DIR="$REPO" hc_resolve "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
printf '== Case 1: a new commit lands, hook runs → its SHA appears in the ledger ==\n'
new_repo; SID="L1"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"          # simulate SessionStart pinning the baseline
commit_file work.txt                # simulate a tool call landing a commit
C1=$(git -C "$REPO" rev-parse HEAD)
run_hook "$SID"
eq "case1 hook exit 0" "0" "$HOOK_RC"
LEDGER=$(ledger_path "$SID")
if [ -f "$LEDGER" ]; then ok "case1 ledger file created"; else bad "case1 ledger file created" "missing"; fi
if grep -Fxq -- "$C1" "$LEDGER" 2>/dev/null; then
  ok "case1 new commit SHA present in ledger"
else
  bad "case1 new commit SHA present in ledger" "$(cat "$LEDGER" 2>/dev/null)"
fi
eq "case1 ledger has exactly one line (C0 not included)" "1" "$(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
printf '== Case 2: first-ever invocation does NOT backfill pre-existing history ==\n'
new_repo; SID="L2"
commit_file base.txt                # pre-existing history the hook has never seen
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file old.txt                 # more pre-existing history
COLD=$(git -C "$REPO" rev-parse HEAD)
# No .sha baseline seeded, no ledger yet → per the design, cursor falls all
# the way back to CURRENT HEAD (not genesis), so this call is a pure no-op.
run_hook "$SID"
eq "case2 hook exit 0" "0" "$HOOK_RC"
LEDGER=$(ledger_path "$SID")
if [ -f "$LEDGER" ]; then ok "case2 ledger file created (present, even though empty)"; else bad "case2 ledger created" "missing"; fi
eq "case2 ledger is empty (no backfill)" "0" "$(wc -c < "$LEDGER" 2>/dev/null | tr -d ' ')"
if grep -Fxq -- "$C0" "$LEDGER" 2>/dev/null || grep -Fxq -- "$COLD" "$LEDGER" 2>/dev/null; then
  bad "case2 pre-existing commits NOT in ledger" "$(cat "$LEDGER" 2>/dev/null)"
else
  ok "case2 pre-existing commits NOT in ledger"
fi

# ---------------------------------------------------------------------------
printf '== Case 3: second invocation with HEAD unchanged is a no-op ==\n'
new_repo; SID="L3"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file work.txt
run_hook "$SID"                     # first call: appends the new commit
LEDGER=$(ledger_path "$SID")
BEFORE=$(cat "$LEDGER" 2>/dev/null)
run_hook "$SID"                     # second call: HEAD has not moved
eq "case3 second hook exit 0" "0" "$HOOK_RC"
AFTER=$(cat "$LEDGER" 2>/dev/null)
eq "case3 ledger byte-identical after no-op re-run" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
printf '== Case 4 (CORE REGRESSION): base advances past a same-identity commit NOT in the ledger ==\n'
# The exact bug: a human commit sharing the session's git identity (repo
# identity == session identity, no separate "Claude" identity), that the
# ledger hook never observed. We seed the ledger DIRECTLY here (same idiom as
# seed_baseline / test-identity.sh's seed_baseline — this suite tests
# hc__resolve_session_base's CONSUMPTION of the ledger, not commit-ledger.sh's
# production of it; that is cases 1-3) with C2 present but C1 ABSENT, so the
# ledger is genuinely POPULATED (non-empty) — proving this is membership-
# driven, not merely "empty ledger, nothing owned" (that is case 5).
#
# Under the OLD email-only predicate this same-email C1 could never be proven
# foreign, so the base would NOT advance past it (stays at C0) — this
# assertion FAILS on that code. Under the NEW ledger-first code, C1 is simply
# absent from the ledger → confidently-foreign → advance past it; C2 IS in the
# ledger → stop there. This PASSES only on the new code.
#
# NOTE on realism: the real hook cannot produce exactly this ledger state for
# a contiguous C1-then-C2 sequence (its sweep walks the WHOLE cursor..HEAD
# range, so a commit-shaped call after both C1 and C2 exist would catch BOTH,
# not just C2 — the documented residual in commit-ledger.sh's
# looks_like_commit_command comment). This case is therefore a deliberate
# RESOLVER-layer unit test of hc__resolve_session_base's membership logic in
# isolation, using a hand-seeded ledger (same idiom as seed_baseline). Case 8
# below is the end-to-end complement: it drives the REAL hook through the
# case it CAN correctly handle (a foreign commit followed by a later,
# non-commit-shaped Bash call) and confirms hook + resolver agree.
new_repo; SID="L4"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file direct.txt              # C1: same identity — will be ABSENT from the ledger
C1=$(git -C "$REPO" rev-parse HEAD)
commit_file toolmade.txt            # C2: same identity — will be PRESENT in the ledger
C2=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
LEDGER=$(ledger_path "$SID")
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
printf '%s\n' "$C2" > "$LEDGER"     # populated, but deliberately missing C1
resolve_inproc "$SID"
eq "case4 mode session" "session" "$HC_MODE"
eq "case4 base advances past the un-ledgered same-identity commit (C1)" "$C1" "$HC_BASE"
eq "case4 base_orig unchanged" "$C0" "$HC_BASE_ORIG"

# ---------------------------------------------------------------------------
printf '== Case 5: empty-but-present ledger → DEGRADE to email-only (0.1.15 regression fix) ==\n'
# An empty ledger means the PostToolUse hook ran (its first-Bash-call touch
# created the file) but never swept a commit in — or its writer resolved a
# DIFFERENT session id than this reader. "Recorded nothing" is NOT "owns
# nothing": the pre-fix code advanced HC_BASE past the WHOLE range, so the Stop
# gate saw an empty changeset and SILENTLY PASSED unverified committed work.
# The fix: an empty ledger does not engage; hc__resolve_session_base falls back
# to the email-only predicate, identical to ledger-absent (Case 6). Here every
# commit shares the session identity → NOT confidently-foreign → base STOPS at
# C0, the full changeset stays, the gate engages.
new_repo; SID="L5"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file mine1.txt               # same identity, nothing recorded this session
commit_file mine2.txt
C2=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
LEDGER=$(ledger_path "$SID")
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
: > "$LEDGER"                       # present, but EMPTY — hook ran, swept nothing
resolve_inproc "$SID"
eq "case5 mode session" "session" "$HC_MODE"
eq "case5 empty ledger degrades to email: base STAYS at C0 (changeset preserved)" "$C0" "$HC_BASE"
eq "case5 base_orig unchanged" "$C0" "$HC_BASE_ORIG"

# 5b — empty ledger + a genuinely FOREIGN leading commit → email predicate still
# advances past THAT one (the degrade is to email-only, not to "never advance").
new_repo; SID="L5b"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > f.txt && git add f.txt && git commit -qm foreign"
CF=$(git -C "$REPO" rev-parse HEAD)
commit_file mine.txt               # session identity
seed_baseline "$SID" "$C0"
LEDGER=$(ledger_path "$SID")
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
: > "$LEDGER"
resolve_inproc "$SID"
eq "case5b empty ledger + foreign lead: base advances to the foreign commit only" "$CF" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 6: no ledger file at all → falls back to the pre-existing email behavior ==\n'
# Regression guard for the graceful-degrade path: when commit-ledger.sh has
# never fired this session (no Bash calls yet, or an older/unwired install),
# baselines/<sid>.own-commits does not exist, and hc__resolve_session_base
# must behave EXACTLY as before (hc__commit_confidently_foreign, email-only).
# This is what keeps test-gate.sh and test-anchor-recovery.sh — whose fixtures
# never create a ledger — green with zero changes to their expectations (also
# re-verified by running the full suite; see run-tests.sh).
printf -- '-- 6a: same-email commit, no ledger → base STOPS (kept in changeset) --\n'
new_repo; SID="L6a"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file mine.txt                # same identity as the session
resolve_inproc "$SID"
if [ ! -f "$(ledger_path "$SID")" ]; then ok "case6a no ledger file exists"; else bad "case6a no ledger file exists" "present"; fi
eq "case6a base unchanged (email fallback keeps same-identity commit)" "$C0" "$HC_BASE"

printf -- '-- 6b: different-email commit, no ledger → base ADVANCES (unchanged fallback behavior) --\n'
new_repo; SID="L6b"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > foreign.txt && git add foreign.txt && git commit -qm foreign"
CF=$(git -C "$REPO" rev-parse HEAD)
resolve_inproc "$SID"
eq "case6b base advances past confidently-foreign commit (email fallback intact)" "$CF" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 7 (regression: cursor recovers after history rewrite) ==\n'
# Drives the REAL hook through commit -> amend -> commit, each via a
# commit-shaped call, so the cursor genuinely tracks the rewrite instead of
# being hand-seeded. Under the OLD code (no baseline-retry on ancestor
# failure), the amend orphans the ledger's cursor forever: the post-amend
# commit and the later real commit both end up NOT in the ledger, so
# hc__resolve_session_base wrongly advances HC_BASE all the way to HEAD
# (nothing left to review). Under the FIXED code, the ancestor-check failure
# recovers against the .sha baseline, both post-amend commits get properly
# appended, and HC_BASE stays at C0 (everything is genuinely session-owned,
# so nothing should be trimmed from the changeset at all).
new_repo; SID="L7"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file work.txt                            # C1: first tool-made commit
run_hook "$SID" "git commit -m work"
git -C "$REPO" commit --amend -q -m "work (amended)" >/dev/null 2>&1   # rewrites C1 -> C1'
run_hook "$SID" "git commit --amend -m work-amended"                   # cursor recovery happens here
C1P=$(git -C "$REPO" rev-parse HEAD)
commit_file more.txt                            # C2: a real commit made AFTER the rewrite
run_hook "$SID" "git commit -m more"
C2=$(git -C "$REPO" rev-parse HEAD)

LEDGER=$(ledger_path "$SID")
if grep -Fxq -- "$C1P" "$LEDGER" 2>/dev/null; then
  ok "case7 post-amend commit (C1') recorded in ledger (cursor recovered)"
else
  bad "case7 post-amend commit (C1') recorded in ledger" "$(cat "$LEDGER" 2>/dev/null)"
fi
if grep -Fxq -- "$C2" "$LEDGER" 2>/dev/null; then
  ok "case7 post-rewrite real commit (C2) recorded in ledger"
else
  bad "case7 post-rewrite real commit (C2) recorded in ledger" "$(cat "$LEDGER" 2>/dev/null)"
fi
resolve_inproc "$SID"
eq "case7 mode session" "session" "$HC_MODE"
eq "case7 base_orig unchanged" "$C0" "$HC_BASE_ORIG"
eq "case7 base NOT advanced past post-amend/real commits (still all owned)" "$C0" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 8 (regression: non-commit Bash call does not sweep a foreign commit) ==\n'
# End-to-end: drives the REAL hook. A foreign commit lands (simulating a
# direct terminal commit the hook never observed), THEN an ordinary non-commit
# Bash call fires (e.g. `git status`) before Stop. Under the OLD code (no
# command-shape gate) that innocuous call would sweep the foreign commit into
# the ledger, misattributing it as session-owned; hc__resolve_session_base
# would then STOP at it instead of advancing past it — the exact "gate nags
# forever about a commit nobody wants reviewed" symptom this feature exists to
# fix, reproduced via a different path. Under the FIXED code the non-commit
# call skips the sweep entirely, the foreign commit never enters the ledger,
# and the resolver correctly advances past it.
new_repo; SID="L8"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > foreign.txt && git add foreign.txt && git commit -qm foreign"
CF=$(git -C "$REPO" rev-parse HEAD)
run_hook "$SID" "git status"        # non-commit call, fires AFTER the foreign commit landed
eq "case8 hook exit 0" "0" "$HOOK_RC"
LEDGER=$(ledger_path "$SID")
if grep -Fxq -- "$CF" "$LEDGER" 2>/dev/null; then
  bad "case8 foreign commit NOT swept into ledger by non-commit call" "$(cat "$LEDGER" 2>/dev/null)"
else
  ok "case8 foreign commit NOT swept into ledger by non-commit call"
fi
resolve_inproc "$SID"
eq "case8 base advances past the foreign commit (never ledgered)" "$CF" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
