#!/bin/bash
#
# Acceptance test for the auto-branch PreToolUse(Write|Edit) hook.
#
# Exercises the BUNDLE script (completion-harness/scripts/auto-branch.sh) — so
# the sourced harness-common.sh sits adjacent — via throwaway mktemp git repos
# with NO remote. Prints PASS/FAIL per assertion and a summary; exits non-zero
# on any failure. No `set -e` — every case runs and reports.

BUNDLE_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
HOOK="$BUNDLE_DIR/auto-branch.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s (got: %s)\n' "$1" "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1 expected '$2'" "$3"; fi; }

CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# Fresh temp git repo on trunk `main`, no remote, local identity.
new_repo() {
  REPO=$(mktemp -d 2>/dev/null)
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

# Write a done-config.json in the repo's .claude dir. $1 = JSON (empty = skip).
seed_config() {
  mkdir -p "$REPO/.claude" 2>/dev/null
  [ -n "$1" ] && printf '%s\n' "$1" > "$REPO/.claude/done-config.json"
}

# Drive the hook. Sets HOOK_OUT / HOOK_RC.
run_hook() {
  HOOK_OUT=$(printf '{"session_id":"S","tool_name":"Write"}' \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>/dev/null)
  HOOK_RC=$?
}

cur_branch() { git -C "$REPO" symbolic-ref --short -q HEAD 2>/dev/null; }

# ---------------------------------------------------------------------------
printf '== Case 1: on trunk + auto_branch:true → new task/* branch ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main","auto_branch":true,"max_fix_attempts":3}'
# uncommitted WIP that must survive the checkout -b: an untracked file AND a
# dirty tracked file (the tracked change is the one that actually exercises
# git carrying WIP onto the new branch).
printf 'wip\n' > "$REPO/wip.txt"
printf 'dirty-line\n' >> "$REPO/base.txt"
run_hook
eq   "case1 exit 0" "0" "$HOOK_RC"
BR=$(cur_branch)
if [ "$BR" != "main" ] && [ -n "$BR" ]; then ok "case1 moved off main (now '$BR')"; else bad "case1 moved off main" "$BR"; fi
case "$BR" in
  task/*) ok "case1 branch matches task/* ('$BR')" ;;
  *)      bad "case1 branch matches task/*" "$BR" ;;
esac
if [ -f "$REPO/wip.txt" ]; then ok "case1 untracked WIP still present"; else bad "case1 untracked WIP present" "gone"; fi
if grep -q 'dirty-line' "$REPO/base.txt" 2>/dev/null; then ok "case1 dirty tracked WIP carried onto branch"; else bad "case1 tracked WIP carried" "lost"; fi
case "$HOOK_OUT" in
  *'"decision":"block"'*|*'"decision":"deny"'*|*'"deny"'*) bad "case1 no block/deny decision" "$HOOK_OUT" ;;
  *) ok "case1 output carries no block/deny decision" ;;
esac

# ---------------------------------------------------------------------------
printf '== Case 2: auto_branch:false → stay on main ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main","auto_branch":false}'
run_hook
eq "case2 exit 0" "0" "$HOOK_RC"
eq "case2 still on main (no branch)" "main" "$(cur_branch)"

# ---------------------------------------------------------------------------
printf '== Case 2b: no auto_branch key → DEFAULT is off → stay on main ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main"}'   # no auto_branch key at all
run_hook
eq "case2b exit 0" "0" "$HOOK_RC"
eq "case2b default is OFF (opt-in, not opt-out)" "main" "$(cur_branch)"

# ---------------------------------------------------------------------------
printf '== Case 3: already on a feature branch → no-op ==\n'
new_repo
commit_file base.txt
git -C "$REPO" checkout -q -b feat/x 2>/dev/null
seed_config '{"trunk":"main","auto_branch":true}'
run_hook
eq "case3 exit 0" "0" "$HOOK_RC"
eq "case3 still on feat/x (no-op)" "feat/x" "$(cur_branch)"

# ---------------------------------------------------------------------------
printf '== Case 4: detached HEAD → no-op, no crash ==\n'
new_repo
commit_file base.txt
commit_file second.txt
SHA=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)
git -C "$REPO" checkout -q "$SHA" 2>/dev/null   # detached
# auto_branch:true DELIBERATELY — with the default (off) this case would pass
# because nothing ever branches, testing nothing. The guard under test is the
# detached-HEAD one, so branching must otherwise be armed.
seed_config '{"trunk":"main","auto_branch":true}'
run_hook
eq "case4 exit 0" "0" "$HOOK_RC"
if [ -z "$(cur_branch)" ] && git -C "$REPO" rev-parse HEAD >/dev/null 2>&1; then
  ok "case4 still detached (no branch created)"
else
  bad "case4 still detached" "branch=$(cur_branch)"
fi

# ---------------------------------------------------------------------------
printf '== Case 5: mid-merge sentinel (.git/MERGE_HEAD) → no-op ==\n'
new_repo
commit_file base.txt
# auto_branch:true DELIBERATELY — see case 4: the sentinel is the guard under
# test, so branching must be armed or the assertion is vacuous.
seed_config '{"trunk":"main","auto_branch":true}'
# fabricate a merge-in-progress sentinel
printf '%s\n' "$(git -C "$REPO" rev-parse HEAD)" > "$REPO/.git/MERGE_HEAD"
run_hook
eq "case5 exit 0" "0" "$HOOK_RC"
eq "case5 still on main (sentinel blocked auto-branch)" "main" "$(cur_branch)"
rm -f "$REPO/.git/MERGE_HEAD" 2>/dev/null

# ---------------------------------------------------------------------------
# Scope rule: the hook governs CODING edits only, matching the Stop gate's
# non-code stand-down (done-gate.sh Step 3a). Drives the hook WITH a
# tool_input.file_path, which the no-path run_hook above deliberately omits.
run_hook_for() {
  HOOK_OUT=$(printf '{"session_id":"S","tool_name":"Write","tool_input":{"file_path":"%s"}}' "$1" \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$HOOK" 2>/dev/null)
  HOOK_RC=$?
}

printf '== Case 6: prose edit (.md) on trunk → NO branch ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main","auto_branch":true}'
run_hook_for "$REPO/docs/design.md"
eq "case6 exit 0" "0" "$HOOK_RC"
eq "case6 still on main (non-code edit out of scope)" "main" "$(cur_branch)"

printf '== Case 7: code edit after a prose edit → branch ==\n'
run_hook_for "$REPO/src/index.ts"
eq "case7 exit 0" "0" "$HOOK_RC"
case "$(cur_branch)" in
  task/*) ok "case7 branched on the first CODE edit ('$(cur_branch)')" ;;
  *)      bad "case7 branched on the first code edit" "$(cur_branch)" ;;
esac

printf '== Case 8: noncode_globs override makes .ts non-code → NO branch ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main","auto_branch":true,"noncode_globs":["*.ts"]}'
run_hook_for "$REPO/src/index.ts"
eq "case8 exit 0" "0" "$HOOK_RC"
eq "case8 still on main (config-declared non-code)" "main" "$(cur_branch)"

printf '== Case 9: session-config auto_branch:false beats done-config true ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main","auto_branch":true}'
mkdir -p "$REPO/.claude/.harness" 2>/dev/null
printf '{"auto_branch":false}\n' > "$REPO/.claude/.harness/session-config.json"
run_hook_for "$REPO/src/index.ts"
eq "case9 exit 0" "0" "$HOOK_RC"
eq "case9 still on main (session override wins)" "main" "$(cur_branch)"

printf '== Case 10: session-config auto_branch:true beats done-config false ==\n'
new_repo
commit_file base.txt
seed_config '{"trunk":"main","auto_branch":false}'
mkdir -p "$REPO/.claude/.harness" 2>/dev/null
printf '{"auto_branch":true}\n' > "$REPO/.claude/.harness/session-config.json"
run_hook_for "$REPO/src/index.ts"
eq "case10 exit 0" "0" "$HOOK_RC"
case "$(cur_branch)" in
  task/*) ok "case10 session override re-enabled branching ('$(cur_branch)')" ;;
  *)      bad "case10 session override re-enabled branching" "$(cur_branch)" ;;
esac

# NOTE: the former Case 6 (fallback-pin-is-empty, WIP-blocks-gate) was dropped in
# the migration into tracked tests/. It drove the INSTALLED .claude/scripts copies
# purely to prove install-equivalence (its whole framing was "install.sh re-install
# flips FAIL→PASS"). Install shipping is now verified by test-install.sh, and the
# fallback-pin gate behavior against source scripts is covered by test-tree-status.sh
# / test-gate.sh. Keeping it here would have required a hardcoded installed-copy path.

# ---------------------------------------------------------------------------
printf '\n== Summary: %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
