#!/bin/bash
#
# Acceptance tests for the session commit ledger:
#   - completion-harness/scripts/commit-ledger.sh — the Bash tool-call hook,
#     wired TWICE on the same "Bash" matcher: PreToolUse (`pre`) pins HEAD into
#     baselines/<sid>.cursor, PostToolUse sweeps CURSOR..HEAD into
#     baselines/<sid>.own-commits. The pair is a CALL WINDOW.
#   - harness-common.sh's hc__commit_in_any_ledger / hc__resolve_session_base,
#     for which ledger membership is now the SINGLE SOURCE OF TRUTH for "did an
#     agent produce this commit".
#
# THE CONTRACT UNDER TEST (and what it replaced):
#
#   1. ATTRIBUTION IS OBSERVED, NOT GUESSED. HEAD moved inside a tool-call
#      window ⇒ an agent moved it. The hook no longer inspects
#      tool_input.command: the old `looks_like_commit_command` text heuristic
#      missed every indirect commit (a shell script, a Makefile target, a git
#      alias, `gh pr merge`), so real agent commits never reached the ledger and
#      were then read as foreign and skipped by the review. Case B below is that
#      exact miss.
#
#   2. THERE IS NO COMMITTER-EMAIL TIER. `hc__commit_confidently_foreign` is
#      DELETED. The human and Claude Code commit under the SAME git identity, so
#      no commit was ever provably foreign, the session base never advanced, and
#      the Stop gate demanded a full /done run for sessions that changed
#      nothing — a pure Q&A session got blocked because the human hand-committed
#      in another terminal. Case A below is that exact case.
#
#   3. ABSENT or EMPTY LEDGER MEANS "NO AGENT COMMIT OBSERVED" — so every commit
#      in base..HEAD is foreign, hc__resolve_session_base advances HC_BASE to
#      HEAD, and the gate's empty-changeset step allows the Stop with no DoD.
#      Cases 5, 6 and A pin this. Earlier revisions of this suite (Cases 5-8)
#      asserted the OPPOSITE — an empty ledger degrading to the email predicate,
#      documented then as the "0.1.15 regression" fix. That reasoning is
#      superseded: with one shared git identity the degrade never advanced
#      anything, so it only ever produced over-blocks. Uncommitted work is NOT
#      affected by any of this — hc_tree_status gates it against the pinned tree
#      baseline and never reads the ledger.
#
#   4. MEMBERSHIP IS CHECKED ACROSS ALL SESSIONS' LEDGERS. A concurrent agent
#      session's commit is still agent work; scoped per-session it would look
#      foreign to everyone and get skipped by every reviewer. Case 13 pins it.
#
# Same fixture idiom as test-identity.sh / test-autobranch.sh: throwaway mktemp
# git repos via hc__test_mktemp_d, PASS/FAIL via ok/bad/eq, harness-common.sh
# sourced in-process (for hc_resolve / hc__resolve_session_base) alongside
# driving the real commit-ledger.sh script as a subprocess (for the hook's own
# file-writing behavior) and the real done-gate.sh (for the two end-to-end
# directional cases). No `set -e` — every case runs and reports.

BUNDLE_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
HOOK="$BUNDLE_DIR/commit-ledger.sh"
GATE="$BUNDLE_DIR/done-gate.sh"

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
  # Harness state is gitignored in a real install; mirror that so the gate's
  # porcelain check does not read .harness state as a dirty tree.
  printf '.claude/\n' > "$REPO/.gitignore"
  git -C "$REPO" add .gitignore >/dev/null 2>&1
  git -C "$REPO" commit -qm "gitignore" >/dev/null 2>&1
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
cursor_path() { printf '%s/.claude/.harness/baselines/%s.cursor' "$REPO" "$1"; }

# Drive the real hook as the two halves of one Bash tool call would fire it.
# The command TEXT is deliberately irrelevant now (contract point 1), so these
# send a fixed placeholder — a case that wants to prove text-independence sends
# something the deleted heuristic would never have matched.
# $1 = session id, $2 = tool_input.command (default a placeholder).
_fire() {
  local mode="$1" sid="$2" cmd="${3:-echo hi}"
  HOOK_RC_OUT=$(printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$sid" "$cmd" \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" ${mode:+$mode} 2>/dev/null)
  HOOK_RC=$?
}
run_pre()  { _fire pre "$1" "${2:-}"; }
run_post() { _fire ""  "$1" "${2:-}"; }
# window <sid> <command-text> <shell code...> — the honest shape of a Bash tool
# call: PreToolUse fires, the command runs, PostToolUse fires.
window() {
  local sid="$1" cmd="$2"; shift 2
  run_pre "$sid" "$cmd"
  eval "$@"
  run_post "$sid" "$cmd"
}

# Drive the real Stop gate. Echoes "block" or "allow". Needed by the two
# end-to-end directional cases (A/B), which assert the gate VERDICT, not just
# the resolver's HC_BASE.
gate_verdict() {
  local out
  out=$(printf '{"session_id":"%s","stop_hook_active":false}' "$1" \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$GATE" 2>/dev/null)
  if printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    printf 'block'
  else
    printf 'allow'
  fi
}

resolve_inproc() { CLAUDE_PROJECT_DIR="$REPO" hc_resolve "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
printf '== Case 1: a commit inside the call window lands in the ledger ==\n'
new_repo; SID="L1"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"          # simulate SessionStart pinning the baseline
window "$SID" "git commit -m work" 'commit_file work.txt'
C1=$(git -C "$REPO" rev-parse HEAD)
eq "case1 post hook exit 0" "0" "$HOOK_RC"
LEDGER=$(ledger_path "$SID")
if [ -f "$LEDGER" ]; then ok "case1 ledger file created"; else bad "case1 ledger file created" "missing"; fi
eq "case1 cursor pinned at the window's lower bound (C0)" "$C0" "$(cat "$(cursor_path "$SID")" 2>/dev/null)"
if grep -Fxq -- "$C1" "$LEDGER" 2>/dev/null; then
  ok "case1 new commit SHA present in ledger"
else
  bad "case1 new commit SHA present in ledger" "$(cat "$LEDGER" 2>/dev/null)"
fi
eq "case1 ledger has exactly one line (C0 not included)" "1" "$(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
printf '== Case 2: a window in which HEAD never moves does NOT backfill history ==\n'
new_repo; SID="L2"
commit_file base.txt                # pre-existing history the hook has never seen
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file old.txt                 # more pre-existing history
COLD=$(git -C "$REPO" rev-parse HEAD)
# No .sha baseline, no cursor yet. `pre` pins HEAD; the call commits nothing;
# `post` sees HEAD == CURSOR and no-ops. Structural, not heuristic: the window
# is empty, so nothing can be attributed to it.
window "$SID" "git status" ':'
eq "case2 post hook exit 0" "0" "$HOOK_RC"
LEDGER=$(ledger_path "$SID")
if [ -f "$LEDGER" ]; then ok "case2 ledger file created (present, even though empty)"; else bad "case2 ledger created" "missing"; fi
eq "case2 ledger is empty (no backfill)" "0" "$(wc -c < "$LEDGER" 2>/dev/null | tr -d ' ')"
if grep -Fxq -- "$C0" "$LEDGER" 2>/dev/null || grep -Fxq -- "$COLD" "$LEDGER" 2>/dev/null; then
  bad "case2 pre-existing commits NOT in ledger" "$(cat "$LEDGER" 2>/dev/null)"
else
  ok "case2 pre-existing commits NOT in ledger"
fi

# ---------------------------------------------------------------------------
printf '== Case 3: a second window with HEAD unchanged is a no-op ==\n'
new_repo; SID="L3"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
window "$SID" "git commit -m work" 'commit_file work.txt'   # appends the commit
LEDGER=$(ledger_path "$SID")
BEFORE=$(cat "$LEDGER" 2>/dev/null)
window "$SID" "git status" ':'                              # HEAD has not moved
eq "case3 second window post exit 0" "0" "$HOOK_RC"
AFTER=$(cat "$LEDGER" 2>/dev/null)
eq "case3 ledger byte-identical after no-op window" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
printf '== Case 4 (CORE): base advances past a same-identity commit NOT in the ledger ==\n'
# A human commit sharing the session's git identity (repo identity == session
# identity, no separate "Claude" identity) that no call window ever observed.
# The ledger is hand-seeded here with C2 present but C1 ABSENT — this suite
# tests hc__resolve_session_base's CONSUMPTION of the ledger (cases 1-3 and
# 7-12 cover production) — so the ledger is genuinely POPULATED, proving the
# advance is membership-driven rather than merely "nothing recorded" (case 5).
new_repo; SID="L4"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file direct.txt              # C1: same identity — ABSENT from the ledger
C1=$(git -C "$REPO" rev-parse HEAD)
commit_file toolmade.txt            # C2: same identity — PRESENT in the ledger
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
printf '== Case 5: empty-but-present ledger → nothing observed → base advances to HEAD ==\n'
# REWRITTEN CONTRACT (this case previously locked the opposite: an empty ledger
# degrading to the committer-email predicate, so the base STAYED at C0 and the
# gate demanded /done). That degrade was inert — the human and the agent share
# one git identity, so nothing was ever confidently foreign and the base never
# advanced. All it produced was a permanent /done demand for commits the
# session did not make. An empty ledger now means exactly what it says: no
# agent commit was observed, so every commit in range is foreign and the base
# advances to HEAD. Uncommitted work is untouched by this (hc_tree_status).
new_repo; SID="L5"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file other1.txt              # same identity, but no window ever saw them
commit_file other2.txt
C2=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
LEDGER=$(ledger_path "$SID")
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
: > "$LEDGER"                       # present, but EMPTY — hook ran, saw nothing
resolve_inproc "$SID"
eq "case5 mode session" "session" "$HC_MODE"
eq "case5 empty ledger: base advances to HEAD (empty changeset, no DoD)" "$C2" "$HC_BASE"
eq "case5 base_orig unchanged" "$C0" "$HC_BASE_ORIG"

# 5b — mixed identities, empty ledger: BOTH advance. Email is not a signal any
# more, so a same-email commit is treated exactly like a different-email one.
new_repo; SID="L5b"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > f.txt && git add f.txt && git commit -qm foreign"
commit_file same-identity.txt      # session identity
CH=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
LEDGER=$(ledger_path "$SID")
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
: > "$LEDGER"
resolve_inproc "$SID"
eq "case5b empty ledger + mixed identities: base advances past BOTH to HEAD" "$CH" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 6: no ledger file at all → identical to empty (nothing observed) ==\n'
# REWRITTEN CONTRACT. This case used to be the "graceful degrade to email"
# regression guard. There is no degrade tier now: absent and empty are the same
# statement ("no agent commit observed") and both advance to HEAD. Absence is
# reachable in production — a session with zero Bash calls, or an install that
# never wired the hooks — and in both cases the session provably committed
# nothing through a tool call, so there is nothing for it to review.
printf -- '-- 6a: same-email commit, no ledger → base ADVANCES to HEAD --\n'
new_repo; SID="L6a"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file other.txt               # same identity as the session
CH=$(git -C "$REPO" rev-parse HEAD)
resolve_inproc "$SID"
if [ ! -f "$(ledger_path "$SID")" ]; then ok "case6a no ledger file exists"; else bad "case6a no ledger file exists" "present"; fi
eq "case6a base advances to HEAD (no ledger ⇒ nothing owned)" "$CH" "$HC_BASE"

printf -- '-- 6b: different-email commit, no ledger → base ADVANCES to HEAD --\n'
new_repo; SID="L6b"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > foreign.txt && git add foreign.txt && git commit -qm foreign"
CF=$(git -C "$REPO" rev-parse HEAD)
resolve_inproc "$SID"
eq "case6b base advances past the foreign commit" "$CF" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 7: a history rewrite INSIDE the window is claimed, and never stalls ==\n'
# REWRITTEN. This case used to lock a recovery mechanism that no longer exists:
# the cursor was derived from the ledger's own TAIL, so an amend that orphaned
# that one sha made every later call re-derive the same forever-failing
# ancestor check and the ledger stopped growing for the rest of the session.
# The retry-against-baseline block existed only to escape that feedback loop.
# An externally pinned PER-CALL cursor has no such loop, so both the
# merge-base --is-ancestor check and its recovery are DELETED. What is asserted
# now is the property that mattered: an amend performed inside the agent's own
# window yields the rewritten commit in the ledger (the agent's rewrite
# authored it), and a later window still sweeps normally.
new_repo; SID="L7"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
window "$SID" "git commit -m work" 'commit_file work.txt'                 # C1
window "$SID" "git commit --amend" 'git -C "$REPO" commit --amend -q -m "work (amended)" >/dev/null 2>&1'
C1P=$(git -C "$REPO" rev-parse HEAD)
window "$SID" "git commit -m more" 'commit_file more.txt'                 # C2
C2=$(git -C "$REPO" rev-parse HEAD)

LEDGER=$(ledger_path "$SID")
if grep -Fxq -- "$C1P" "$LEDGER" 2>/dev/null; then
  ok "case7 post-amend commit (C1') recorded in ledger"
else
  bad "case7 post-amend commit (C1') recorded in ledger" "$(cat "$LEDGER" 2>/dev/null)"
fi
if grep -Fxq -- "$C2" "$LEDGER" 2>/dev/null; then
  ok "case7 post-rewrite real commit (C2) recorded (ledger did not stall)"
else
  bad "case7 post-rewrite real commit (C2) recorded" "$(cat "$LEDGER" 2>/dev/null)"
fi
resolve_inproc "$SID"
eq "case7 mode session" "session" "$HC_MODE"
eq "case7 base_orig unchanged" "$C0" "$HC_BASE_ORIG"
# Two independent reasons the base must stay at C0 here: C1' and C2 are both
# ledgered (membership), AND the amend orphaned the original C1 sha, which the
# reachability tripwire (case C) reads as "history rewritten → refuse to
# advance". Either alone gives C0; the assertion holds under both.
eq "case7 base NOT advanced past post-amend/real commits (all owned)" "$C0" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 8: a commit landing BETWEEN windows is never swept ==\n'
# REWRITTEN. This case used to lock the `looks_like_commit_command` text gate:
# with the old ledger-tail cursor, ANY later Bash call swept the whole
# cursor..HEAD range, so an innocuous `git status` picked up a foreign commit
# that had landed earlier. That gate is DELETED (it also lost every indirect
# agent commit — case B). The per-call cursor makes the property structural
# instead of heuristic: a commit that lands OUTSIDE every window is outside
# every CURSOR..HEAD range, so no amount of later Bash activity can claim it —
# regardless of what those commands look like or whose email is on the commit.
new_repo; SID="L8"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
window "$SID" "git status" ':'      # window 1 closes at C0
# Foreign commit lands with the SAME identity as the session, between windows.
commit_file foreign.txt
CF=$(git -C "$REPO" rev-parse HEAD)
window "$SID" "git log --oneline"  ':'   # window 2: pins CF, HEAD does not move
eq "case8 post hook exit 0" "0" "$HOOK_RC"
LEDGER=$(ledger_path "$SID")
if grep -Fxq -- "$CF" "$LEDGER" 2>/dev/null; then
  bad "case8 between-windows commit NOT swept into ledger" "$(cat "$LEDGER" 2>/dev/null)"
else
  ok "case8 between-windows commit NOT swept into ledger"
fi
resolve_inproc "$SID"
eq "case8 base advances past the never-observed commit" "$CF" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case 9: pre mode never denies and writes no stdout ==\n'
# PreToolUse can BLOCK a tool call. This hook is pure bookkeeping and must
# never do that — same invariant test-gate.sh pins for auto-branch.sh.
new_repo; SID="L9"
commit_file base.txt
run_pre "$SID" "echo hi"
eq "case9 pre exit 0" "0" "$HOOK_RC"
eq "case9 pre stdout empty (no deny/decision)" "" "$HOOK_RC_OUT"

# ---------------------------------------------------------------------------
printf '== Case 10: post mode with NO cursor falls back to the .sha baseline ==\n'
# Reachable in production: an older install that wired only PostToolUse, or a
# tool call denied before `pre` ran. Over-including costs a spurious review
# demand; under-including silently skips one — so it over-includes.
new_repo; SID="L10"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file work.txt
C1=$(git -C "$REPO" rev-parse HEAD)
run_post "$SID" "bash deploy.sh"    # post ONLY — no cursor file was ever written
eq "case10 post exit 0" "0" "$HOOK_RC"
if [ ! -f "$(cursor_path "$SID")" ]; then ok "case10 no cursor file existed"; else bad "case10 no cursor file existed" "present"; fi
LEDGER=$(ledger_path "$SID")
if grep -Fxq -- "$C1" "$LEDGER" 2>/dev/null; then
  ok "case10 commit swept via the .sha baseline fallback"
else
  bad "case10 commit swept via the .sha baseline fallback" "$(cat "$LEDGER" 2>/dev/null)"
fi

# 10b — no cursor AND no .sha baseline → no anchor at all → append nothing.
new_repo; SID="L10b"
commit_file base.txt
commit_file work.txt
run_post "$SID" "bash deploy.sh"
eq "case10b post exit 0" "0" "$HOOK_RC"
# post never TOUCHES the ledger without an anchor — it exits before the sweep,
# so the file is not even created (only `pre` creates it).
if [ ! -s "$(ledger_path "$SID")" ]; then ok "case10b no anchor ⇒ nothing appended"; else bad "case10b no anchor ⇒ nothing appended" "$(cat "$(ledger_path "$SID")" 2>/dev/null)"; fi

# ---------------------------------------------------------------------------
printf '== Case 11: post mode dedupes (parallel Bash calls can both sweep) ==\n'
# Two Bash calls in flight at once share one ledger and can cover the same
# range; the same sha must not be recorded twice. Reproduced by re-running
# `post` against a cursor that is still below HEAD.
new_repo; SID="L11"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
run_pre "$SID"                      # pins C0
commit_file work.txt
C1=$(git -C "$REPO" rev-parse HEAD)
run_post "$SID"                     # sweep 1: appends C1
printf '%s\n' "$C0" > "$(cursor_path "$SID")"   # a peer call's pin, still at C0
run_post "$SID"                     # sweep 2: same range again
LEDGER=$(ledger_path "$SID")
eq "case11 C1 recorded exactly once" "1" "$(grep -cxF -- "$C1" "$LEDGER" 2>/dev/null | tr -d ' ')"
eq "case11 ledger has exactly one line total" "1" "$(grep -c . "$LEDGER" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
printf '== Case 12: membership spans ALL sessions ledgers ==\n'
# A concurrent agent session's commit is still agent work. Scoped per-session,
# the peer's commit would be absent from OUR ledger and ours absent from
# THEIRS, and both sessions would advance their base past work nobody reviews.
new_repo; SID="L12"; PEER="L12peer"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file peer.txt
CP=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
: > "$(ledger_path "$SID")"                     # our ledger: empty
printf '%s\n' "$CP" > "$(ledger_path "$PEER")"  # the PEER session owns CP
resolve_inproc "$SID"
eq "case12 base does NOT advance past a PEER session's ledgered commit" "$C0" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case C (DIRECTIONAL): our own commit rewritten under us → refuse to advance ==\n'
# The unsafe hole the tripwire closes. The ledger keys on SHA identity, but a
# rebase/amend preserves CONTENT and changes the SHA:
#   agent commits A            → ledger = [A]
#   the human runs `git pull --rebase`, rewriting A → A'
#   A' is in no ledger → reads as FOREIGN → base advances PAST it
#   → the agent's own committed work drops out of the changeset, review SKIPPED.
# That is the one direction this harness must never fail in. The tripwire
# (hc__ledger_history_rewritten) notices that a sha THIS session recorded is no
# longer reachable from HEAD, concludes attribution is unknowable, and refuses
# to advance at all. It does not recover the attribution — it converts a silent
# skip into an over-block.
# WITHOUT the tripwire this asserts HC_BASE == HEAD and the gate allows; WITH it
# HC_BASE stays at HC_BASE_ORIG and the gate blocks.
new_repo; SID="LC"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
window "$SID" "git commit -m work" 'commit_file work.txt'     # A, observed → ledgered
A=$(git -C "$REPO" rev-parse HEAD)
if grep -Fxq -- "$A" "$(ledger_path "$SID")" 2>/dev/null; then ok "caseC A is ledgered before the rewrite"; else bad "caseC A ledgered" "$(cat "$(ledger_path "$SID")")"; fi
# The human rewrites it OUTSIDE any window (same content, new sha).
git -C "$REPO" commit --amend -q -m "work (rewritten by the human)" >/dev/null 2>&1
AP=$(git -C "$REPO" rev-parse HEAD)
eq "caseC the rewrite produced a NEW sha" "false" "$([ "$A" = "$AP" ] && echo true || echo false)"
if grep -Fxq -- "$AP" "$(ledger_path "$SID")" 2>/dev/null; then
  bad "caseC A' is NOT in the ledger (would read as foreign)" "$(cat "$(ledger_path "$SID")")"
else
  ok "caseC A' is NOT in the ledger (would read as foreign)"
fi
resolve_inproc "$SID"
eq "caseC base did NOT advance to HEAD" "false" "$([ "$HC_BASE" = "$AP" ] && echo true || echo false)"
eq "caseC base stays at HC_BASE_ORIG (attribution unknowable → full changeset)" "$HC_BASE_ORIG" "$HC_BASE"
eq "caseC base_orig is still C0" "$C0" "$HC_BASE_ORIG"
eq "caseC gate BLOCKS (A' kept in the changeset)" "block" "$(gate_verdict "$SID")"

# ---------------------------------------------------------------------------
printf '== Case D: the tripwire is a NO-OP on an absent or empty ledger ==\n'
# Scope check. If the tripwire fired here it would resurrect the very
# block-forever bug this change removes (case A), so pin both states directly
# against the predicate as well as through the resolver.
new_repo; SID="LD"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file human.txt
CH=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
CLAUDE_PROJECT_DIR="$REPO" HARNESS_DIR="$REPO/.claude/.harness" \
  hc__ledger_history_rewritten "$SID" "$REPO" && TRIP=fired || TRIP=quiet
eq "caseD absent ledger: tripwire quiet" "quiet" "$TRIP"
: > "$(ledger_path "$SID")"                                 # present and EMPTY
CLAUDE_PROJECT_DIR="$REPO" HARNESS_DIR="$REPO/.claude/.harness" \
  hc__ledger_history_rewritten "$SID" "$REPO" && TRIP=fired || TRIP=quiet
eq "caseD empty ledger: tripwire quiet" "quiet" "$TRIP"
resolve_inproc "$SID"
eq "caseD empty ledger still advances to HEAD (case A unaffected)" "$CH" "$HC_BASE"

# D2 — a PEER session's ledger holding an unreachable sha must NOT trip us.
# Normal in production (the peer worked on a branch that is now deleted);
# tripping on it would block every session permanently.
new_repo; SID="LD2"; PEER="LD2peer"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
commit_file human.txt
CH=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
: > "$(ledger_path "$SID")"
printf '%s\n' "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$(ledger_path "$PEER")"
CLAUDE_PROJECT_DIR="$REPO" HARNESS_DIR="$REPO/.claude/.harness" \
  hc__ledger_history_rewritten "$SID" "$REPO" && TRIP=fired || TRIP=quiet
eq "caseD2 peer ledger's unreachable sha does NOT trip this session" "quiet" "$TRIP"
resolve_inproc "$SID"
eq "caseD2 base still advances to HEAD" "$CH" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '== Case E: rebase/merge in progress → both modes are inert ==\n'
# During a rebase HEAD is detached and moves repeatedly over transient commits.
# Pinning or sweeping those only dirties the ledger. Same GIT_DIR probe shape
# auto-branch.sh uses, in the SHARED preamble so pre and post cannot diverge.
new_repo; SID="LE"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
# Manufacture a real conflicting rebase and leave it mid-flight.
git -C "$REPO" checkout -q -b side "$C0" >/dev/null 2>&1
printf 'side\n' > "$REPO/conflict.txt"; git -C "$REPO" add conflict.txt >/dev/null 2>&1
git -C "$REPO" commit -qm side >/dev/null 2>&1
git -C "$REPO" checkout -q main >/dev/null 2>&1
printf 'main\n' > "$REPO/conflict.txt"; git -C "$REPO" add conflict.txt >/dev/null 2>&1
git -C "$REPO" commit -qm mainside >/dev/null 2>&1
git -C "$REPO" rebase side >/dev/null 2>&1     # conflicts → stops mid-rebase
GD=$(git -C "$REPO" rev-parse --git-dir 2>/dev/null); case "$GD" in /*) : ;; *) GD="$REPO/$GD" ;; esac
if [ -d "$GD/rebase-merge" ] || [ -d "$GD/rebase-apply" ]; then
  ok "caseE fixture: rebase genuinely in progress"
else
  bad "caseE fixture: rebase genuinely in progress" "no rebase-merge/rebase-apply"
fi
# Mid-rebase, hc_resolve still reports session mode (detached HEAD → empty
# HC_BRANCH → the session fallback), so the GIT_DIR probe is the ONLY thing
# stopping either half from writing. Verified by temporarily disabling it: pre
# then pins the transient rebase HEAD.
run_pre "$SID"
eq "caseE pre exit 0" "0" "$HOOK_RC"
if [ ! -f "$(cursor_path "$SID")" ]; then ok "caseE pre wrote no cursor"; else bad "caseE pre wrote no cursor" "$(cat "$(cursor_path "$SID")")"; fi
# Give post a live anchor BELOW the transient HEAD, so "appended nothing" can
# only be the guard's doing — without it the sweep has a real range to walk and
# would record the transient rebase commit.
mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
printf '%s\n' "$C0" > "$(cursor_path "$SID")"
E_HEAD=$(git -C "$REPO" rev-parse HEAD)
eq "caseE fixture: transient HEAD really is above the anchor" "false" "$([ "$E_HEAD" = "$C0" ] && echo true || echo false)"
run_post "$SID"
eq "caseE post exit 0" "0" "$HOOK_RC"
if [ ! -s "$(ledger_path "$SID")" ]; then ok "caseE post appended nothing"; else bad "caseE post appended nothing" "$(cat "$(ledger_path "$SID")")"; fi
git -C "$REPO" rebase --abort >/dev/null 2>&1
rm -f "$(cursor_path "$SID")"

# E2 — POSITIVE CONTROL. Same repo, same session, guard no longer active: the
# very same window shape DOES record. Without this, "inert" could just mean
# "nothing was going to happen anyway" and deleting the guard would still pass.
window "$SID" "git commit -m after-abort" 'commit_file after-abort.txt'
EA=$(git -C "$REPO" rev-parse HEAD)
if grep -Fxq -- "$EA" "$(ledger_path "$SID")" 2>/dev/null; then
  ok "caseE2 control: with no rebase in flight the same window DOES record"
else
  bad "caseE2 control: with no rebase in flight the same window DOES record" "$(cat "$(ledger_path "$SID")" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
printf '== Case A (DIRECTIONAL): pure Q&A session + foreign same-identity commit → Stop allowed ==\n'
# The AIM-2756 case, end to end. A session that edited nothing and committed
# nothing; meanwhile the human hand-commits in another terminal under the SAME
# git identity. Ledger present-and-empty (a Bash call fired `pre`, HEAD never
# moved in any window), tree clean.
#   OLD behaviour: empty ledger degraded to the email predicate → same email →
#     nothing confidently foreign → HC_BASE stuck at C0 → non-empty changeset →
#     gate BLOCKS demanding a full /done for a commit the session never made.
#   NEW behaviour: nothing observed → the foreign commit is foreign → HC_BASE
#     advances to HEAD → empty changeset → Stop allowed, no done-state needed.
new_repo; SID="LA"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
run_pre "$SID" "cat notes.md"       # a read-only Bash call: creates the ledger
# The human commits in another terminal, same git identity, OUTSIDE any window.
commit_file human-work.txt
CH=$(git -C "$REPO" rev-parse HEAD)
LEDGER=$(ledger_path "$SID")
if [ -f "$LEDGER" ] && [ ! -s "$LEDGER" ]; then ok "caseA ledger present and empty"; else bad "caseA ledger present and empty" "$(ls -l "$LEDGER" 2>/dev/null)"; fi
resolve_inproc "$SID"
eq "caseA base advances to HEAD (nothing this session authored)" "$CH" "$HC_BASE"
eq "caseA base_orig unchanged" "$C0" "$HC_BASE_ORIG"
eq "caseA no done-state exists" "" "$(ls "$REPO/.claude/.harness/done-state" 2>/dev/null)"
eq "caseA gate ALLOWS the Stop (empty changeset, clean tree)" "allow" "$(gate_verdict "$SID")"

# ---------------------------------------------------------------------------
printf '== Case B (DIRECTIONAL): a SCRIPT that commits is still agent work → Stop blocked ==\n'
# The text-heuristic miss, end to end. The agent's Bash call is `bash
# release.sh`, which commits internally — a command the deleted
# looks_like_commit_command would never have matched (no "git commit", no
# "merge"/"rebase"/"pull" anywhere in it).
#   OLD behaviour: the command-shape gate skipped the sweep, so the commit
#     never reached the ledger; it then looked foreign to hc__resolve_session_base,
#     the base advanced past it, and the gate ALLOWED the Stop with real
#     committed work never reviewed. The discriminating assertion is therefore
#     ledger MEMBERSHIP (empty on the old code, present on the new).
#   NEW behaviour: HEAD moved inside the window, so the commit is agent work →
#     base stays at C0 → the gate BLOCKS demanding /done.
new_repo; SID="LB"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$SID" "$C0"
cat > "$REPO/release.sh" <<'EOS'
#!/bin/bash
cd "$1" || exit 1
echo shipped > shipped.txt
git add shipped.txt
git -c commit.gpgsign=false commit -qm "ship it"
EOS
window "$SID" "bash release.sh ." "bash '$REPO/release.sh' '$REPO' >/dev/null 2>&1"
CS=$(git -C "$REPO" rev-parse HEAD)
LEDGER=$(ledger_path "$SID")
if grep -Fxq -- "$CS" "$LEDGER" 2>/dev/null; then
  ok "caseB script-made commit swept into the ledger (text-independent)"
else
  bad "caseB script-made commit swept into the ledger" "$(cat "$LEDGER" 2>/dev/null)"
fi
resolve_inproc "$SID"
eq "caseB base does NOT advance (the commit is agent-authored)" "$C0" "$HC_BASE"
eq "caseB gate BLOCKS the Stop (real work, no /done run)" "block" "$(gate_verdict "$SID")"

# ---------------------------------------------------------------------------
printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
