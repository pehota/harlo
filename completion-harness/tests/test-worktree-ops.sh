#!/bin/bash
#
# Tests for new-worktree.sh (provisioning) and finish-worktree.sh (verified
# teardown).
#
# Every fixture is a throwaway ORIGIN (bare) + a clone, so `git fetch`,
# origin/<trunk> resolution and the "never pushes" assertion are all exercised
# against a real remote rather than mocked. Style follows test-tree-status.sh:
# mktemp -d repos, ok()/bad() counters, real script invocation.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
NEW="$SCRIPTS/new-worktree.sh"
FINISH="$SCRIPTS/finish-worktree.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

CLEANUP=()
trap 'for d in "${CLEANUP[@]}"; do rm -rf "$d" 2>/dev/null; done' EXIT

# make_pair → sets ORIGIN and REPO: a bare origin plus a clone on main with a
# .gitignore, a couple of gitignored local configs and a package.json.
make_pair() {
  ORIGIN=$(mktemp -d); CLEANUP+=("$ORIGIN")
  REPO=$(mktemp -d);   CLEANUP+=("$REPO")
  git init -q --bare -b main "$ORIGIN" 2>/dev/null || {
    git init -q --bare "$ORIGIN" >/dev/null 2>&1
  }
  git clone -q "$ORIGIN" "$REPO" >/dev/null 2>&1
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name  t
  git -C "$REPO" symbolic-ref HEAD refs/heads/main 2>/dev/null

  cat > "$REPO/.gitignore" <<'GI'
.claude/
.worktrees/
node_modules/
.env
.envrc
GI
  printf '{ "name": "fixture", "scripts": { "test": "true" } }\n' > "$REPO/package.json"
  mkdir -p "$REPO/src"
  printf 'x\n' > "$REPO/src/app.js"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm base >/dev/null 2>&1
  git -C "$REPO" push -q origin main >/dev/null 2>&1
  git -C "$REPO" branch --set-upstream-to=origin/main main >/dev/null 2>&1

  # gitignored local config the fresh worktree cannot have
  printf 'SECRET=1\n' > "$REPO/.env"
  printf 'use nix\n'  > "$REPO/.envrc"
  mkdir -p "$REPO/.claude"
  printf '{"trunk":"main"}\n' > "$REPO/.claude/done-config.json"
}

# run_new <repo> <branch> [path] → stdout+stderr, sets RC.
run_new() {
  local r="$1" b="$2" p="${3:-}"
  OUT=$(CLAUDE_PROJECT_DIR="$r" bash "$NEW" "$b" $p 2>&1); RC=$?
}

echo "== test-worktree-ops =="

# ===========================================================================
# new-worktree.sh
# ===========================================================================
echo "-- new-worktree: creates the worktree and links local config --"
make_pair
run_new "$REPO" "task/alpha"
WT="$REPO/.worktrees/task-alpha"
if [ "$RC" -eq 0 ] && [ -d "$WT" ]; then
  ok "worktree created at $WT"
else
  bad "worktree not created (rc=$RC): $OUT"
fi
if [ -L "$WT/.env" ] && [ "$(cat "$WT/.env" 2>/dev/null)" = "SECRET=1" ]; then
  ok ".env symlinked and readable through the link"
else
  bad ".env not linked"
fi
if [ -L "$WT/.envrc" ]; then ok ".envrc symlinked"; else bad ".envrc not linked"; fi
LINK_TARGET=$(readlink "$WT/.env")
REPO_REAL=$(cd "$REPO" && pwd -P)   # macOS resolves /tmp -> /private/tmp
case "$LINK_TARGET" in
  /*) if [ "$LINK_TARGET" = "$REPO_REAL/.env" ]; then
        ok "the link is absolute, pointing at the source checkout"
      else
        bad "unexpected link target: $LINK_TARGET (want $REPO_REAL/.env)"
      fi ;;
  *)  bad "link target is not absolute: $LINK_TARGET" ;;
esac
if git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -qx 'task/alpha'; then
  ok "worktree is on the new branch"
else
  bad "worktree branch wrong"
fi
if [ "$(git -C "$WT" rev-parse HEAD)" = "$(git -C "$REPO" rev-parse origin/main)" ]; then
  ok "branched from origin/main"
else
  bad "did not branch from origin/main"
fi
if printf '%s' "$OUT" | grep -q 'linked:'; then
  ok "prints a summary of what was linked"
else
  bad "no link summary in output"
fi

echo "-- new-worktree: branches from origin/<trunk>, NOT local trunk --"
make_pair
printf 'local-only\n' > "$REPO/local.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "unpushed local commit" >/dev/null 2>&1
LOCAL_HEAD=$(git -C "$REPO" rev-parse HEAD)
ORIGIN_HEAD=$(git -C "$REPO" rev-parse origin/main)
run_new "$REPO" "task/beta"
WT="$REPO/.worktrees/task-beta"
if [ "$(git -C "$WT" rev-parse HEAD)" = "$ORIGIN_HEAD" ] && [ "$ORIGIN_HEAD" != "$LOCAL_HEAD" ]; then
  ok "unpushed local trunk commit is NOT inherited by the worktree"
else
  bad "worktree inherited local state (head=$(git -C "$WT" rev-parse HEAD))"
fi

echo "-- new-worktree: refuses an existing worktree path --"
make_pair
ALT=$(mktemp -d); CLEANUP+=("$ALT")
mkdir -p "$ALT/occupied"
if CLAUDE_PROJECT_DIR="$REPO" bash "$NEW" "task/occupied" "$ALT/occupied" >/dev/null 2>&1; then
  bad "did not refuse an existing worktree path"
else
  ok "refuses when the worktree path already exists"
fi

echo "-- new-worktree: never overwrites a file already in the worktree --"
# The collision that actually happens: a file still TRACKED on origin/<trunk>
# but untracked-and-ignored in the source checkout (someone ran
# `git rm --cached` and gitignored it, and has not pushed that yet). The
# provisioner sees it as linkable local config; the fresh worktree, cut from
# origin, already has it as real tracked content. Clobbering that with a symlink
# into another checkout destroys work with no undo — so it must skip and say so.
make_pair
printf 'TRACKED\n' > "$REPO/.env.shared"
git -C "$REPO" add -f .env.shared >/dev/null 2>&1
git -C "$REPO" commit -qm "tracked on origin" >/dev/null 2>&1
git -C "$REPO" push -q origin main >/dev/null 2>&1
git -C "$REPO" rm -q --cached .env.shared >/dev/null 2>&1
printf '.env.shared\n' >> "$REPO/.gitignore"
git -C "$REPO" add .gitignore >/dev/null 2>&1
git -C "$REPO" commit -qm "untrack locally (unpushed)" >/dev/null 2>&1
run_new "$REPO" "task/collide"
WT="$REPO/.worktrees/task-collide"
if [ -f "$WT/.env.shared" ] && [ ! -L "$WT/.env.shared" ] \
   && [ "$(cat "$WT/.env.shared")" = "TRACKED" ]; then
  ok "a path already present in the worktree is left untouched (not replaced by a link)"
else
  bad "existing file was clobbered by a symlink"
fi
if printf '%s' "$OUT" | grep -q 'already existed'; then
  ok "and the skip is reported, not silent"
else
  bad "skip-on-exists not reported: $OUT"
fi

echo "-- new-worktree: refuses an existing branch --"
make_pair
git -C "$REPO" branch task/dup >/dev/null 2>&1
run_new "$REPO" "task/dup"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "already exists"; then
  ok "refuses when the branch already exists"
else
  bad "did not refuse an existing branch (rc=$RC): $OUT"
fi

echo "-- new-worktree: reports non-allowlisted candidates it did NOT link --"
make_pair
printf 'secrets.txt\n' >> "$REPO/.gitignore"
printf 'hunter2\n' > "$REPO/secrets.txt"
run_new "$REPO" "task/report"
if printf '%s' "$OUT" | grep -q 'secrets.txt'; then
  ok "names the unlinked candidate in the summary"
else
  bad "candidate not reported: $OUT"
fi
if [ ! -e "$REPO/.worktrees/task-report/secrets.txt" ]; then
  ok "and did not link it"
else
  bad "linked a non-allowlisted file"
fi

echo "-- new-worktree: does NOT run a heuristic setup script --"
make_pair
CANARY="$REPO/CANARY"
jq '.scripts.setup = "touch ../../CANARY"' "$REPO/package.json" > "$REPO/pj" && mv "$REPO/pj" "$REPO/package.json"
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" commit -qm setup >/dev/null 2>&1
git -C "$REPO" push -q origin main >/dev/null 2>&1
run_new "$REPO" "task/setup"
if [ ! -e "$CANARY" ]; then
  ok "a detected 'setup' script is never executed"
else
  bad "ran a heuristically-detected setup script"
fi
if printf '%s' "$OUT" | grep -q 'setup candidates'; then
  ok "reports it as a candidate instead"
else
  bad "setup candidate not reported: $OUT"
fi

# ===========================================================================
# finish-worktree.sh
# ===========================================================================
echo "-- finish-worktree: fixture helpers --"

# seed_green <worktree> — write a green done-state + review-log at the
# worktree's HEAD, keyed on the task key the resolver produces there.
seed_green() {
  local wt="$1"
  local head base br key hd
  head=$(git -C "$wt" rev-parse HEAD)
  hd="$wt/.claude/.harness"
  br=$(git -C "$wt" symbolic-ref --short HEAD)
  key="br-$(printf '%s' "$br" | sed 's/[^A-Za-z0-9_.-]/-/g')"
  base=$(git -C "$wt" merge-base main HEAD 2>/dev/null)
  [ -n "$base" ] || base=$(git -C "$wt" rev-parse HEAD~1 2>/dev/null)
  mkdir -p "$hd/done-state" "$hd/review-log" "$hd/task-base" "$hd/tree-base"
  printf '%s\n' "$base" > "$hd/task-base/$key.sha"
  : > "$hd/tree-base/$key.dirty"
  local files
  files=$(git -C "$wt" diff --name-only "$base" "$head" 2>/dev/null | jq -R . | jq -sc .)
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[],"open_findings":0}\n' \
    "$head" "$files" > "$hd/review-log/$head.json"
  printf '{"contract_version":1,"session_id":"s","verified_sha":"%s","head_tree":"%s","base_sha":"%s","review_anchor_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' \
    "$head" "$(git -C "$wt" rev-parse 'HEAD^{tree}')" "$base" "$head" \
    > "$hd/done-state/$key.json"
  printf '{"trunk":"main"}\n' > "$wt/.claude/done-config.json"
}

# fresh_task <branch> — make_pair + a worktree with one real commit on it.
# Sets REPO, ORIGIN, WT.
fresh_task() {
  local br="$1"
  make_pair
  CLAUDE_PROJECT_DIR="$REPO" bash "$NEW" "$br" >/dev/null 2>&1
  WT="$REPO/.worktrees/$(printf '%s' "$br" | sed 's/[^A-Za-z0-9_.-]/-/g')"
  git -C "$WT" config user.email t@t
  git -C "$WT" config user.name  t
  printf 'work\n' > "$WT/src/feature.js"
  git -C "$WT" add -A >/dev/null 2>&1
  git -C "$WT" commit -qm "feat: the work" >/dev/null 2>&1
}

run_finish() {
  OUT=$(CLAUDE_PROJECT_DIR="$1" bash "$FINISH" ${2:-} 2>&1); RC=$?
}

echo "-- finish-worktree: refuses a dirty worktree --"
fresh_task "task/dirty"
seed_green "$WT"
printf 'uncommitted\n' >> "$WT/src/feature.js"
run_finish "$WT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'gate 1'; then
  ok "refuses at gate 1 on a dirty worktree"
else
  bad "did not refuse a dirty worktree (rc=$RC): $OUT"
fi
if [ -d "$WT" ]; then ok "worktree left intact"; else bad "worktree removed on refusal"; fi

echo "-- finish-worktree: refuses with NO done-state --"
fresh_task "task/nostate"
run_finish "$WT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'no done-state'; then
  ok "refuses at gate 2 when no done-state exists"
else
  bad "did not refuse a missing done-state (rc=$RC): $OUT"
fi

echo "-- finish-worktree: refuses a STALE done-state --"
fresh_task "task/stale"
seed_green "$WT"
printf 'more\n' > "$WT/src/other.js"
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" commit -qm "commit past the verified sha" >/dev/null 2>&1
run_finish "$WT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'stale'; then
  ok "refuses when HEAD moved past verified_sha with a different tree"
else
  bad "did not refuse a stale done-state (rc=$RC): $OUT"
fi

echo "-- finish-worktree: refuses a RED done-state --"
fresh_task "task/red"
seed_green "$WT"
KEY="br-task-red"
DS="$WT/.claude/.harness/done-state/$KEY.json"
jq '.tests.exit_code = 1' "$DS" > "$DS.tmp" && mv "$DS.tmp" "$DS"
run_finish "$WT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'not green'; then
  ok "refuses when the recorded outcome is red"
else
  bad "did not refuse a red done-state (rc=$RC): $OUT"
fi

echo "-- finish-worktree: --skip-verify bypasses gate 2 loudly --"
fresh_task "task/skip"
run_finish "$WT" "--skip-verify"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'skip-verify'; then
  ok "--skip-verify integrates without a done-state and warns loudly"
else
  bad "--skip-verify path wrong (rc=$RC): $OUT"
fi
if printf '%s' "$OUT" | grep -q 'BYPASSED'; then
  ok "the warning says the gate was bypassed"
else
  bad "no loud bypass warning"
fi

echo "-- finish-worktree: happy path --"
fresh_task "task/happy"
printf 'second\n' > "$WT/src/second.js"
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" commit -qm "feat: second commit" >/dev/null 2>&1
seed_green "$WT"
BEFORE_REMOTE=$(git -C "$ORIGIN" rev-parse main)
BRANCH_HEAD=$(git -C "$WT" rev-parse HEAD)
run_finish "$WT"
if [ "$RC" -eq 0 ]; then ok "succeeds on a clean, green worktree"; else bad "failed: $OUT"; fi
if [ "$(git -C "$REPO" rev-parse main)" = "$BRANCH_HEAD" ]; then
  ok "trunk fast-forwarded to the branch head"
else
  bad "trunk is at $(git -C "$REPO" rev-parse main), want $BRANCH_HEAD"
fi
N=$(git -C "$REPO" log --oneline origin/main..main 2>/dev/null | wc -l | tr -d ' ')
if [ "$N" = "2" ]; then
  ok "both individual commits survive (no squash, no merge commit)"
else
  bad "expected 2 commits ahead of origin, got $N"
fi
if [ -z "$(git -C "$REPO" log --merges origin/main..main 2>/dev/null)" ]; then
  ok "no merge commit was created"
else
  bad "a merge commit appeared"
fi
if [ ! -d "$WT" ]; then ok "worktree removed"; else bad "worktree still present"; fi
if ! git -C "$REPO" show-ref --verify -q refs/heads/task/happy; then
  ok "branch deleted"
else
  bad "branch still exists"
fi
if [ "$(git -C "$ORIGIN" rev-parse main)" = "$BEFORE_REMOTE" ]; then
  ok "NEVER PUSHED — the remote ref is byte-identical"
else
  bad "the remote moved: $(git -C "$ORIGIN" rev-parse main)"
fi
if printf '%s' "$OUT" | grep -q 'NOT pushed'; then
  ok "prints what would be pushed"
else
  bad "no push preview: $OUT"
fi

echo "-- finish-worktree: aborts cleanly on a rebase conflict --"
fresh_task "task/conflict"
printf 'branch side\n' > "$WT/src/app.js"
git -C "$WT" add -A >/dev/null 2>&1
git -C "$WT" commit -qm "branch edits app.js" >/dev/null 2>&1
seed_green "$WT"
# Move origin/main so the same line conflicts.
OTHER=$(mktemp -d); CLEANUP+=("$OTHER")
git clone -q "$ORIGIN" "$OTHER" >/dev/null 2>&1
git -C "$OTHER" config user.email o@o; git -C "$OTHER" config user.name o
printf 'trunk side\n' > "$OTHER/src/app.js"
git -C "$OTHER" add -A >/dev/null 2>&1
git -C "$OTHER" commit -qm "trunk edits app.js" >/dev/null 2>&1
git -C "$OTHER" push -q origin main >/dev/null 2>&1
BEFORE_REMOTE=$(git -C "$ORIGIN" rev-parse main)
run_finish "$WT"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'gate 3'; then
  ok "refuses at gate 3 on a rebase conflict"
else
  bad "conflict not reported at gate 3 (rc=$RC): $OUT"
fi
if [ -d "$WT" ] && [ -z "$(git -C "$WT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  ok "the worktree is still there and still clean"
else
  bad "worktree left damaged"
fi
if [ ! -d "$WT/.git/rebase-merge" ] && [ ! -d "$WT/.git/rebase-apply" ] \
   && ! git -C "$WT" status 2>/dev/null | grep -q 'rebase in progress'; then
  ok "the rebase was aborted, not left half-applied"
else
  bad "a rebase is still in progress"
fi
if git -C "$WT" symbolic-ref --short -q HEAD 2>/dev/null | grep -qx 'task/conflict'; then
  ok "still on the task branch (usable)"
else
  bad "HEAD is not on the task branch"
fi
if [ "$(git -C "$ORIGIN" rev-parse main)" = "$BEFORE_REMOTE" ]; then
  ok "still never pushed"
else
  bad "the remote moved during a failed run"
fi

echo "-- finish-worktree: refuses to run in the MAIN checkout --"
make_pair
OUT=$(CLAUDE_PROJECT_DIR="$REPO" bash "$FINISH" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'MAIN checkout'; then
  ok "refuses when run outside a linked worktree"
else
  bad "did not refuse the main checkout (rc=$RC): $OUT"
fi

# ===========================================================================
# The gate's teardown SUGGESTION (deliverable 6).
# ===========================================================================
echo "-- done-gate: suggests finish-worktree.sh on a green worktree stop --"
GATE="$SCRIPTS/done-gate.sh"
fresh_task "task/suggest"
seed_green "$WT"
# stderr is captured OUTSIDE the worktree — a scratch file inside it would be
# untracked dirt and the gate would block on it instead of allowing.
ERRF=$(mktemp); CLEANUP+=("$ERRF")
GOUT=$(printf '{"session_id":"sug","stop_hook_active":false}' \
       | CLAUDE_PROJECT_DIR="$WT" bash "$GATE" 2>"$ERRF"); GRC=$?
GERR=$(cat "$ERRF" 2>/dev/null)
if [ "$GRC" -eq 0 ] && [ -z "$GOUT" ]; then
  ok "the allow is still exit 0 with EMPTY stdout (decision shape untouched)"
else
  bad "allow shape changed: rc=$GRC stdout='$GOUT'"
fi
if printf '%s' "$GERR" | grep -q 'finish-worktree.sh'; then
  ok "suggests finish-worktree.sh on stderr"
else
  bad "no suggestion on stderr: '$GERR'"
fi
if printf '%s' "$GERR" | grep -q 'never pushes'; then
  ok "and says it never pushes"
else
  bad "suggestion does not mention that it never pushes"
fi
# The suggestion must not fire in a plain checkout on trunk.
GOUT=$(printf '{"session_id":"sug2","stop_hook_active":false}' \
       | CLAUDE_PROJECT_DIR="$REPO" bash "$GATE" 2>"$ERRF")
if ! grep -q 'finish-worktree.sh' "$ERRF" 2>/dev/null; then
  ok "no suggestion in the main checkout on trunk"
else
  bad "suggested teardown outside a worktree"
fi
# ...and never on a BLOCK.
fresh_task "task/nosuggest"
GOUT=$(printf '{"session_id":"sug3","stop_hook_active":false}' \
       | CLAUDE_PROJECT_DIR="$WT" bash "$GATE" 2>"$ERRF")
if printf '%s' "$GOUT" | jq -e '.decision == "block"' >/dev/null 2>&1 \
   && ! grep -q 'finish-worktree.sh' "$ERRF" 2>/dev/null; then
  ok "a blocked stop gets no teardown suggestion"
else
  bad "suggestion leaked onto a block path: stdout=$GOUT err=$(cat "$ERRF")"
fi

echo
echo "test-worktree-ops: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
