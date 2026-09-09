#!/bin/bash
#
# Acceptance test for the shared identity resolver.
#
# Exercises the BUNDLE scripts (completion-harness/scripts) via throwaway
# mktemp git repos with NO remote. Prints PASS/FAIL per assertion and a
# summary; exits non-zero on any failure.
# No `set -e` — we want every case to run and report.

BUNDLE_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
RESOLVE="$BUNDLE_DIR/harness-resolve.sh"
GATE="$BUNDLE_DIR/done-gate.sh"
WRITE="$BUNDLE_DIR/done-write-state.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

# hc_validate + HC_CONTRACTS_DIR from the source harness-common.sh (resolves its
# sibling contracts/ via BASH_SOURCE), so we can assert the resolver output
# validates against the shipped resolver-output contract.
HC_COMMON="$(cd "$(dirname "$0")/../scripts" && pwd)/harness-common.sh"
if [ -f "$HC_COMMON" ]; then
  # shellcheck source=/dev/null
  . "$HC_COMMON" 2>/dev/null
fi

# Run the bundle resolver in $REPO with session id $1, capture the JSON object it
# prints on stdout, parse it with jq into the R_* globals, and assert it VALIDATES
# against the shipped resolver-output contract. $1 = session id.
resolve() {
  local sid="$1"
  local out
  out=$(CLAUDE_PROJECT_DIR="$REPO" bash "$RESOLVE" "$sid" 2>/dev/null)
  R_rc=$?
  R_mode=$(printf '%s' "$out"     | jq -r '.mode // empty' 2>/dev/null)
  R_task_key=$(printf '%s' "$out" | jq -r '.task_key // empty' 2>/dev/null)
  R_base=$(printf '%s' "$out"     | jq -r '.base // empty' 2>/dev/null)
  R_trunk=$(printf '%s' "$out"    | jq -r '.trunk // empty' 2>/dev/null)
  R_branch=$(printf '%s' "$out"   | jq -r '.branch // empty' 2>/dev/null)
  R_warn=$(printf '%s' "$out"     | jq -r '.warn // empty' 2>/dev/null)

  # The resolver output must validate against the shipped resolver-output contract.
  local tmp
  tmp=$(mktemp 2>/dev/null)
  printf '%s\n' "$out" > "$tmp"
  if type hc_validate >/dev/null 2>&1 && hc_validate "$HC_CONTRACTS_DIR/resolver-output.schema.json" "$tmp" >/dev/null 2>&1; then
    ok "resolver output validates against resolver-output contract ($sid)"
  else
    bad "resolver output failed contract validation ($sid)" "$(hc_validate "$HC_CONTRACTS_DIR/resolver-output.schema.json" "$tmp" 2>&1)"
  fi
  rm -f "$tmp" 2>/dev/null
}

# Create a fresh temp git repo with trunk `main`, no remote, local identity.
new_repo() {
  REPO=$(hc__test_mktemp_d)
  git init -b main "$REPO" >/dev/null 2>&1 || {
    git init "$REPO" >/dev/null 2>&1
    ( cd "$REPO" && git branch -M main >/dev/null 2>&1 )
  }
  git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
  git -C "$REPO" config user.name  "Test" >/dev/null 2>&1
}

# Commit a distinct file. $1 = filename.
commit_file() {
  printf 'content-%s\n' "$1" > "$REPO/$1"
  git -C "$REPO" add "$1" >/dev/null 2>&1
  git -C "$REPO" commit -m "add $1" >/dev/null 2>&1
}

CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
printf '== Case 1: Resume seam (task mode, shared pin across sessions) ==\n'
new_repo; CLEANUP+=("$REPO")
commit_file base.txt                              # c0 on main (trunk has history)
git -C "$REPO" checkout -q -b feat/x 2>/dev/null
commit_file c1.txt
commit_file c2.txt

resolve "A"
eq "case1 mode" "task" "$R_mode"
eq "case1 task_key" "br-feat-x" "$R_task_key"
EXPECT_MB=$(git -C "$REPO" merge-base main feat/x 2>/dev/null)
eq "case1 base = merge-base(main,feat/x)" "$EXPECT_MB" "$R_base"

PIN_FILE="$REPO/.claude/.harness/task-base/br-feat-x.sha"
if [ -f "$PIN_FILE" ]; then ok "case1 pin file created"; else bad "case1 pin file created" "missing"; fi
PIN_A=$(cat "$PIN_FILE" 2>/dev/null)

# Add c3, resolve as a DIFFERENT session id.
commit_file c3.txt
resolve "B"
eq "case1 resume task_key unchanged" "br-feat-x" "$R_task_key"
eq "case1 resume base unchanged" "$R_base" "$PIN_A"
PIN_B=$(cat "$PIN_FILE" 2>/dev/null)
eq "case1 pin file byte-identical after resume" "$PIN_A" "$PIN_B"

# git diff base..HEAD --name-only must list the WHOLE feature (c1,c2,c3).
DIFF_FILES=$(git -C "$REPO" diff --name-only "$R_base" HEAD 2>/dev/null | sort | tr '\n' ' ')
EXPECT_FILES="c1.txt c2.txt c3.txt "
eq "case1 diff spans whole feature (c1..c3)" "$EXPECT_FILES" "$DIFF_FILES"

# ---------------------------------------------------------------------------
printf '== Case 2: Trunk fallback, no branch off trunk, no remote ==\n'
new_repo; CLEANUP+=("$REPO")
commit_file base.txt          # on main
resolve "S2"
eq "case2 mode" "session" "$R_mode"
eq "case2 task_key" "session-S2" "$R_task_key"
if [ -n "$R_warn" ]; then ok "case2 warn non-empty ('$R_warn')"; else bad "case2 warn non-empty" "empty"; fi
if [ -d "$REPO/.claude/.harness/task-base" ] && [ -n "$(ls -A "$REPO/.claude/.harness/task-base" 2>/dev/null)" ]; then
  bad "case2 no task-base file" "$(ls "$REPO/.claude/.harness/task-base" 2>/dev/null)"
else
  ok "case2 no task-base file written"
fi

# ---------------------------------------------------------------------------
printf '== Case 3: Pin once (base unchanged after new trunk commit) ==\n'
# Reuse case-1 repo state: still on feat/x with a pin. Add a commit to main.
new_repo; CLEANUP+=("$REPO")
commit_file base.txt
git -C "$REPO" checkout -q -b feat/x 2>/dev/null
commit_file c1.txt
resolve "P1"
BASE_FIRST="$R_base"
PIN_FIRST=$(cat "$REPO/.claude/.harness/task-base/br-feat-x.sha" 2>/dev/null)
# Add a new commit to main.
git -C "$REPO" checkout -q main 2>/dev/null
commit_file main-extra.txt
git -C "$REPO" checkout -q feat/x 2>/dev/null
resolve "P2"
eq "case3 base unchanged after main advances" "$BASE_FIRST" "$R_base"
PIN_SECOND=$(cat "$REPO/.claude/.harness/task-base/br-feat-x.sha" 2>/dev/null)
eq "case3 pin file byte-identical" "$PIN_FIRST" "$PIN_SECOND"

# ---------------------------------------------------------------------------
printf '== Case 4: Detached HEAD ==\n'
new_repo; CLEANUP+=("$REPO")
commit_file base.txt
commit_file second.txt
SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
git -C "$REPO" checkout -q "$SHA" 2>/dev/null   # detached
resolve "D1"
eq "case4 mode" "session" "$R_mode"
if [ "$R_rc" = "0" ]; then ok "case4 resolver exit ok (no crash)"; else bad "case4 exit ok" "rc=$R_rc"; fi
eq "case4 branch empty (detached)" "" "$R_branch"

# ---------------------------------------------------------------------------
printf '== Case 5: Sanitize slashed branch ==\n'
new_repo; CLEANUP+=("$REPO")
commit_file base.txt
git -C "$REPO" checkout -q -b feat/deep/slash 2>/dev/null
commit_file c1.txt
resolve "S5"
eq "case5 mode" "task" "$R_mode"
eq "case5 task_key sanitized" "br-feat-deep-slash" "$R_task_key"

# ---------------------------------------------------------------------------
printf '== Case 6: Gate and write-state resolve the SAME done-state path ==\n'
# On feat/x (task mode), done-write-state.sh must WRITE the branch-keyed
# done-state (br-feat-x) that done-gate.sh READS — proving both scripts resolve
# identity identically. write-state writes it, then the gate reads exactly that
# file and ALLOWs. Same isolated repo pattern as the other cases (no remote).
new_repo; CLEANUP+=("$REPO")
printf '.claude/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "gitignore" >/dev/null 2>&1
commit_file base.txt                       # c0 on main (trunk has history)
git -C "$REPO" checkout -q -b feat/x 2>/dev/null
commit_file work.txt                       # feature commit → HEAD past fork base
IDENT_HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)

# independent review-log for the live HEAD (write-state + gate both require it).
# files_reviewed covers the feature changeset (merge-base(main,feat/x)..HEAD ==
# work.txt) so the STRUCTURAL coverage check passes for both write-state and gate.
mkdir -p "$REPO/.claude/.harness/review-log"
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["work.txt"],"findings":[],"open_findings":0}\n' "$IDENT_HEAD" \
  > "$REPO/.claude/.harness/review-log/$IDENT_HEAD.json"

# write-state writes the done-state; capture the path it chose
GREEN='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
WROTE_PATH=$(printf '%s' "$GREEN" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITE" "sess-ident" 2>/dev/null)
EXPECT_PATH="$REPO/.claude/.harness/done-state/br-feat-x.json"
eq "case6 write-state targets br-feat-x path" "$EXPECT_PATH" "$WROTE_PATH"

# the gate must read exactly that file and ALLOW (different session id proves it
# is not session-keyed) — exit 0 with empty stdout = allow
GATE_OUT=$(printf '{"session_id":"other-sess","stop_hook_active":false}' | CLAUDE_PROJECT_DIR="$REPO" bash "$GATE" 2>/dev/null)
GATE_RC=$?
if [ "$GATE_RC" -eq 0 ] && [ -z "$GATE_OUT" ]; then
  ok "case6 gate reads the same br-feat-x state and ALLOWs (identity agrees)"
else
  bad "case6 gate did not allow off the write-state file" "rc=$GATE_RC out=${GATE_OUT:-<empty>}"
fi

# ---------------------------------------------------------------------------
# Chunk A (P0-a): session-mode base advances past commits NO agent tool call
# produced. The predicate is LEDGER MEMBERSHIP and nothing else: a commit is
# the agent's iff some baselines/*.own-commits lists it (written by
# commit-ledger.sh, which observes HEAD movement inside a Bash call window).
# The base advances past every leading NON-ledgered commit and STOPS at the
# first ledgered one, which is KEPT in the changeset.
#
# Two signals these cases deliberately prove are NOT consulted:
#   - committer EMAIL. Deleted (hc__commit_confidently_foreign is gone): the
#     human and Claude Code share one git identity, so email never separated
#     them, the base never advanced, and the gate demanded /done for commits the
#     session never made. Cases A8/A10 pin that a same-email — and even an
#     identity-less — repo behaves purely on the ledger.
#   - the baseline .sha MTIME, a mutable false-PASS risk (M1). Cases A8/A11 pin
#     that neither a touched mtime nor a backdated committer-date changes the
#     verdict.
# These drive hc__resolve_session_base directly (session mode = on trunk).
seed_baseline() {
  local sha="$1"
  mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
  printf '%s\n' "$sha" > "$REPO/.claude/.harness/baselines/${SID}.sha"
}

# Record <sha>... in this session's commit ledger, as commit-ledger.sh's
# PostToolUse sweep would have after observing HEAD move inside a call window.
seed_ledger() {
  mkdir -p "$REPO/.claude/.harness/baselines" 2>/dev/null
  local sha
  for sha in "$@"; do
    printf '%s\n' "$sha" >> "$REPO/.claude/.harness/baselines/${SID}.own-commits"
  done
}

# Run hc_resolve in-process against $REPO for session $SID; sets HC_BASE etc.
resolve_inproc() { CLAUDE_PROJECT_DIR="$REPO" hc_resolve "$SID" 2>/dev/null; }

printf '== Case 7 (P0-a): un-ledgered commit → base advances past it ==\n'
new_repo; CLEANUP+=("$REPO"); SID="A7"
commit_file base.txt                                   # c0 (orig base)
C0=$(git -C "$REPO" rev-parse HEAD)
# Foreign commit: different committer identity.
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > foreign.txt && git add foreign.txt && git commit -qm foreign"
CF=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$C0"
resolve_inproc
eq "case7 mode session" "session" "$HC_MODE"
eq "case7 base advanced past foreign commit" "$CF" "$HC_BASE"
eq "case7 base_orig unchanged" "$C0" "$HC_BASE_ORIG"

printf '== Case 8 (P0-a): LEDGERED commit → base STOPS (not dropped), any mtime ==\n'
new_repo; CLEANUP+=("$REPO"); SID="A8"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file mine.txt                                   # observed in a call window
C1=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$C0"
seed_ledger "$C1"
# Advance the baseline .sha mtime to NOW (well AFTER the commit): under the old
# AND-mtime logic this could misclassify the commit; the mtime is not read.
touch "$REPO/.claude/.harness/baselines/${SID}.sha" 2>/dev/null
resolve_inproc
eq "case8 base unchanged (ledgered commit stays in changeset)" "$C0" "$HC_BASE"

printf '== Case 9 (P0-a): leading-foreign-then-authored → base at first authored ==\n'
# Ordering property: the advance is a LEADING run only, and stops dead at the
# first ledgered commit. Both commits here carry the SAME git identity — proving
# the split is membership, not email.
new_repo; CLEANUP+=("$REPO"); SID="A9"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
commit_file foreign.txt                                # never observed → foreign
CF=$(git -C "$REPO" rev-parse HEAD)
commit_file mine.txt                                   # observed → ledgered
C2=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$C0"
seed_ledger "$C2"
resolve_inproc
eq "case9 base lands just below first authored (= foreign sha)" "$CF" "$HC_BASE"
eq "case9 base_orig unchanged" "$C0" "$HC_BASE_ORIG"

printf '== Case 10 (P0-a): committer email is not consulted at all ==\n'
# A DIFFERENT-email commit that IS ledgered must be KEPT (an agent can commit
# with --author, or under a repo-local identity that differs from the global
# one), and the verdict must not change when git has no user.email to compare
# against — there is nothing left in this path that reads email.
new_repo; CLEANUP+=("$REPO"); SID="A10"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
seed_baseline "$C0"
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign" \
  bash -c "cd '$REPO' && echo x > foreign.txt && git add foreign.txt && git commit -qm foreign"
CF=$(git -C "$REPO" rev-parse HEAD)
seed_ledger "$CF"
git -C "$REPO" config --unset user.email 2>/dev/null                 # no identity to compare with
resolve_inproc
eq "case10 base UNCHANGED: ledgered commit kept despite a different email" "$C0" "$HC_BASE"
git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1   # restore

printf '== Case 11 (M1 regression lock): ledgered commit older than baseline mtime → KEPT ==\n'
# The M1 bug: the old AND-mtime logic would misclassify a genuinely session-
# authored commit as FOREIGN when the baseline .sha mtime is advanced past the
# commit's committer-date (touch/clock-skew), advancing the base past it and
# letting the gate PASS with real work unverified. This case backdates the
# commit's committer-date to WELL BEFORE the baseline .sha mtime. Under the old
# logic the base would wrongly advance to the commit (base == C1); ledger
# membership carries no timestamp at all → base STAYS at C0 → the commit remains
# in the changeset. Fails under the old logic, passes now.
new_repo; CLEANUP+=("$REPO"); SID="A11"
commit_file base.txt
C0=$(git -C "$REPO" rev-parse HEAD)
# Ledgered commit, but committer-date backdated far into the past.
GIT_COMMITTER_DATE="2001-01-01T00:00:00" GIT_AUTHOR_DATE="2001-01-01T00:00:00" \
  bash -c "cd '$REPO' && echo m > mine.txt && git add mine.txt && git commit -qm mine"
seed_baseline "$C0"
seed_ledger "$(git -C "$REPO" rev-parse HEAD)"
# Force the baseline .sha mtime to NOW — far AFTER the commit's 2001 date.
touch "$REPO/.claude/.harness/baselines/${SID}.sha" 2>/dev/null
resolve_inproc
eq "case11 base UNCHANGED (ledgered commit kept despite older date)" "$C0" "$HC_BASE"

# ---------------------------------------------------------------------------
printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
