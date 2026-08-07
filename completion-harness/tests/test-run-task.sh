#!/bin/bash
#
# Tests for run-task.sh (headless task execution).
#
# NEVER calls the real `claude` binary or any real API — a fake `claude` shell
# script is stubbed first on PATH, following this suite's own throwaway-
# origin-plus-clone fixture style (test-worktree-ops.sh) rather than mocking
# git itself. The fake `claude` writes a trivial commit and (per sub-case) a
# fabricated done-state, or tries to `git push` to prove the no-push shim
# actually refuses it — never relying on the model declining on its own.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
RUN_TASK="$SCRIPTS/run-task.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

CLEANUP=()
trap 'for d in "${CLEANUP[@]}"; do rm -rf "$d" 2>/dev/null; done' EXIT

# make_pair — a throwaway bare ORIGIN plus a clone (REPO) on main, with a
# .gitignore that excludes the harness state dir and the worktrees root, a
# package.json, and a source file. Same shape as test-worktree-ops.sh's
# make_pair, kept local rather than shared since the fixture needs differ
# slightly (this suite's callers never inspect gitignored local config).
make_pair() {
  ORIGIN=$(hc__test_mktemp_d); CLEANUP+=("$ORIGIN")
  REPO=$(hc__test_mktemp_d);   CLEANUP+=("$REPO")
  git init -q --bare -b main "$ORIGIN" 2>/dev/null || git init -q --bare "$ORIGIN" >/dev/null 2>&1
  git clone -q "$ORIGIN" "$REPO" >/dev/null 2>&1
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name  t
  git -C "$REPO" symbolic-ref HEAD refs/heads/main 2>/dev/null

  cat > "$REPO/.gitignore" <<'GI'
.claude/.harness/
.worktrees/
node_modules/
GI
  printf '{ "name": "fixture", "scripts": { "test": "true" } }\n' > "$REPO/package.json"
  mkdir -p "$REPO/src"
  printf 'x\n' > "$REPO/src/app.js"
  mkdir -p "$REPO/.claude"
  printf '{"trunk":"main"}\n' > "$REPO/.claude/done-config.json"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm base >/dev/null 2>&1
  git -C "$REPO" push -q origin main >/dev/null 2>&1
  git -C "$REPO" branch --set-upstream-to=origin/main main >/dev/null 2>&1
}

# fake_claude_bin — a tempdir on PATH with a fake `claude` that reads its
# behaviour from $HC_TEST_CLAUDE_MODE (set by the caller before invoking
# run_task): green | nostate | pushdistractor. Real git, real jq — only the
# LLM call itself is stubbed.
FAKE_BIN=""
fake_claude_bin() {
  FAKE_BIN=$(hc__test_mktemp_d); CLEANUP+=("$FAKE_BIN")
  cat > "$FAKE_BIN/claude" <<'FAKE'
#!/bin/bash
set -u
MODE="${HC_TEST_CLAUDE_MODE:-green}"
git config user.email t@t >/dev/null 2>&1
git config user.name  t   >/dev/null 2>&1

write_green_state() {
  local head br key hd base files
  head=$(git rev-parse HEAD)
  br=$(git symbolic-ref --short HEAD)
  key="br-$(printf '%s' "$br" | sed 's/[^A-Za-z0-9_.-]/-/g')"
  hd=".claude/.harness"
  mkdir -p "$hd/done-state" "$hd/review-log"
  base=$(git merge-base main HEAD 2>/dev/null)
  files=$(git diff --name-only "$base" "$head" 2>/dev/null | jq -R . | jq -sc .)
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[],"open_findings":0}\n' \
    "$head" "$files" > "$hd/review-log/$head.json"
  printf '{"contract_version":1,"session_id":"fake","verified_sha":"%s","head_tree":"%s","base_sha":"%s","review_anchor_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"true","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' \
    "$head" "$(git rev-parse 'HEAD^{tree}')" "$base" "$head" \
    > "$hd/done-state/$key.json"
}

case "$MODE" in
  green)
    echo work >> src/app.js
    git add -A >/dev/null 2>&1
    git commit -qm "feat: headless work" >/dev/null 2>&1
    write_green_state
    ;;
  nostate)
    echo work >> src/app.js
    git add -A >/dev/null 2>&1
    git commit -qm "feat: headless work, never ran /done" >/dev/null 2>&1
    ;;
  pushdistractor)
    echo work >> src/app.js
    git add -A >/dev/null 2>&1
    git commit -qm "feat: headless work" >/dev/null 2>&1
    # Deliberately NOT redirected to /dev/null — the refusal message must
    # reach run-task.sh's captured transcript, not be swallowed here.
    if git push origin HEAD:main; then
      : > PUSH_SUCCEEDED
    fi
    # A global option ahead of the subcommand — the exact form that used to
    # slip past a bare "$1" check (case "${1:-}" saw "-c", not "push").
    if git -c foo.bar=baz push origin HEAD:main; then
      : > PUSH_SUCCEEDED_WITH_C_FLAG
    fi
    ;;
esac
exit 0
FAKE
  chmod +x "$FAKE_BIN/claude"
}

# run_task <repo> <desc> <branch> — invokes the real run-task.sh with the fake
# claude first on PATH. Sets OUT, RC.
run_task() {
  local repo="$1" desc="$2" branch="$3"
  OUT=$(HC_TEST_CLAUDE_MODE="$MODE" PATH="$FAKE_BIN:$PATH" CLAUDE_PROJECT_DIR="$repo" \
        bash "$RUN_TASK" "$desc" "$branch" 2>&1); RC=$?
}

# last_index_entry <repo> — prints the last line of index.jsonl.
last_index_entry() {
  tail -n1 "$1/.claude/.harness/headless-tasks/index.jsonl" 2>/dev/null
}

# report_path_for <repo> <task_id> — the report.json path for a task id.
report_path_for() {
  printf '%s/.claude/.harness/headless-tasks/%s/report.json' "$1" "$2"
}

echo "== test-run-task =="

# ===========================================================================
# PASSED — fake claude commits work and writes a real green done-state.
# ===========================================================================
echo "-- run-task: PASSED when the fake claude commits work and runs /done --"
make_pair
fake_claude_bin
MODE="green"
run_task "$REPO" "add a trivial feature" "task/headless-green"

WT="$REPO/.worktrees/task-headless-green"
if [ -d "$WT" ]; then
  ok "worktree created at the expected path ($WT)"
else
  bad "worktree not created at $WT: $OUT"
fi

if [ "$RC" -eq 0 ]; then
  ok "exits 0 on a PASSED verdict"
else
  bad "expected exit 0 for PASSED (rc=$RC): $OUT"
fi

ENTRY=$(last_index_entry "$REPO")
if printf '%s' "$ENTRY" | jq -e '.verdict == "PASSED" and .branch == "task/headless-green"' >/dev/null 2>&1; then
  ok "index.jsonl records a PASSED entry for the right branch"
else
  bad "index.jsonl entry wrong: $ENTRY"
fi

TASK_ID=$(printf '%s' "$ENTRY" | jq -r '.task_id' 2>/dev/null)
REPORT=$(report_path_for "$REPO" "$TASK_ID")
if [ -f "$REPORT" ] && jq -e '.verdict == "PASSED"' "$REPORT" >/dev/null 2>&1; then
  ok "report.json written with verdict PASSED"
else
  bad "report.json missing or wrong verdict: $(cat "$REPORT" 2>/dev/null)"
fi
if jq -e '.commits | length > 0' "$REPORT" >/dev/null 2>&1; then
  ok "report.json lists the task's commits"
else
  bad "report.json has no commits: $(cat "$REPORT" 2>/dev/null)"
fi
if [ -f "$(dirname "$REPORT")/transcript.log" ]; then
  ok "transcript.log written"
else
  bad "transcript.log missing"
fi
if [ -d "$WT" ] && git -C "$REPO" show-ref --verify -q refs/heads/task/headless-green; then
  ok "worktree and branch left in place (never merged/torn down)"
else
  bad "worktree or branch missing after a passed run"
fi

# ===========================================================================
# NO_STATE — fake claude commits work but never runs /done.
# ===========================================================================
echo "-- run-task: NO_STATE when the fake claude never runs /done --"
make_pair
fake_claude_bin
MODE="nostate"
run_task "$REPO" "add another feature" "task/headless-nostate"

if [ "$RC" -ne 0 ]; then
  ok "exits non-zero on a non-PASSED verdict"
else
  bad "expected non-zero exit for NO_STATE (rc=$RC): $OUT"
fi

ENTRY=$(last_index_entry "$REPO")
if printf '%s' "$ENTRY" | jq -e '.verdict == "NO_STATE"' >/dev/null 2>&1; then
  ok "index.jsonl records NO_STATE"
else
  bad "index.jsonl entry wrong: $ENTRY"
fi

TASK_ID=$(printf '%s' "$ENTRY" | jq -r '.task_id' 2>/dev/null)
REPORT=$(report_path_for "$REPO" "$TASK_ID")
if jq -e '.verdict == "NO_STATE" and (.block_reason | type == "string")' "$REPORT" >/dev/null 2>&1; then
  ok "report.json records NO_STATE with a block_reason"
else
  bad "report.json wrong: $(cat "$REPORT" 2>/dev/null)"
fi

# ===========================================================================
# NO-PUSH SHIM — the fake claude tries `git push`; it must be refused.
# ===========================================================================
echo "-- run-task: the no-push shim refuses git push from the child claude --"
make_pair
fake_claude_bin
MODE="pushdistractor"
BEFORE_REMOTE=$(git -C "$ORIGIN" rev-parse main)
run_task "$REPO" "add a feature, also push this branch" "task/headless-push"

WT="$REPO/.worktrees/task-headless-push"
if [ ! -f "$WT/PUSH_SUCCEEDED" ]; then
  ok "the child's git push did NOT succeed"
else
  bad "the no-push shim failed to stop a push"
fi
if [ ! -f "$WT/PUSH_SUCCEEDED_WITH_C_FLAG" ]; then
  ok "git -c foo=bar push (global option ahead of the subcommand) also refused"
else
  bad "the shim only checked \$1 — a global-option-prefixed push slipped through"
fi
if [ "$(git -C "$ORIGIN" rev-parse main)" = "$BEFORE_REMOTE" ]; then
  ok "the real remote is byte-identical — nothing was pushed"
else
  bad "the remote moved: $(git -C "$ORIGIN" rev-parse main)"
fi
TASK_ID=$(last_index_entry "$REPO" | jq -r '.task_id' 2>/dev/null)
REPORT=$(report_path_for "$REPO" "$TASK_ID")
if [ -f "$(dirname "$REPORT")/transcript.log" ] \
   && grep -q 'git push is disabled' "$(dirname "$REPORT")/transcript.log" 2>/dev/null; then
  ok "the refusal message is captured in the transcript"
else
  bad "no refusal message in the transcript: $(cat "$(dirname "$REPORT")/transcript.log" 2>/dev/null)"
fi

# ===========================================================================
# usage / argument guards.
# ===========================================================================
echo "-- run-task: refuses with no task description --"
make_pair
OUT=$(CLAUDE_PROJECT_DIR="$REPO" bash "$RUN_TASK" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'usage:'; then
  ok "refuses when no task description is given"
else
  bad "did not refuse a missing task description (rc=$RC): $OUT"
fi

echo
echo "test-run-task: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
