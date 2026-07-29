#!/bin/bash
#
# Tests for the SessionStart cleanup features in baseline-snapshot.sh +
# harness-common.sh:
#   Part 1 — source-aware baseline guard (compact must not clobber a baseline).
#   Part 2 — terminal reap: reap a task's state once its branch is MERGED or GONE;
#            KEEP an in-progress (unmerged) task's state; SKIP entirely when trunk
#            is unconfident.
#   Part 3 — review-log hygiene: keep the current HEAD's log + live branch-tip
#            logs; delete superseded fix-churn logs.
#
# Runs against the source-tree scripts (completion-harness/scripts/, resolved
# relative to this test) — no install needed. Each case builds an isolated
# throwaway git repo with CLAUDE_PROJECT_DIR pointed at it.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"

SNAPSHOT="$SCRIPTS/baseline-snapshot.sh"
COMMON="$SCRIPTS/harness-common.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== test-cleanup =="

# run_snapshot <repo> <session_id> [source] — drive the real SessionStart hook.
run_snapshot() {
  local src_json=""
  [ -n "$3" ] && src_json=",\"source\":\"$3\""
  printf '{"session_id":"%s"%s}' "$2" "$src_json" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SNAPSHOT" >/dev/null 2>&1
}

# seed_task_state <repo> <key> — seed task-base/tree-base/done-state for a key.
seed_task_state() {
  local r="$1" key="$2"
  mkdir -p "$r/.claude/.harness/task-base" "$r/.claude/.harness/tree-base" \
           "$r/.claude/.harness/done-state"
  printf 'deadbeef\n' > "$r/.claude/.harness/task-base/$key.sha"
  : > "$r/.claude/.harness/tree-base/$key.dirty"
  printf '{"tree_clean":true}\n' > "$r/.claude/.harness/done-state/$key.json"
}

# ============================================================================
# PART 2 — TERMINAL REAP: merged branch reaped, unmerged branch kept.
# ============================================================================
R=$(mktemp -d)
git -C "$R" init -q -b main
git -C "$R" config user.email t@t
git -C "$R" config user.name t
printf '.claude/\n' > "$R/.gitignore"
printf 'a\n' > "$R/a.txt"
git -C "$R" add -A
git -C "$R" commit -qm c1
mkdir -p "$R/.claude/.harness/baselines" "$R/.claude/.harness/done-state" "$R/.claude/.harness/review-log"
# Confident trunk (main exists → hc__detect_trunk returns main).
# feat-merged: branch off main, commit, merge into main → integrated.
git -C "$R" checkout -q -b feat-merged
printf 'm\n' > "$R/m.txt"; git -C "$R" add -A; git -C "$R" commit -qm mwork
git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff feat-merged -m "merge feat-merged"
# feat-open: branch off main, commit, do NOT merge → in progress.
git -C "$R" checkout -q -b feat-open
printf 'o\n' > "$R/o.txt"; git -C "$R" add -A; git -C "$R" commit -qm owork
# Seed state for BOTH keys (+ done-state for the merged one, per spec).
seed_task_state "$R" "br-feat-merged"
seed_task_state "$R" "br-feat-open"
# Run SessionStart from the open (in-progress) branch.
run_snapshot "$R" sX startup
# Merged branch state REAPED.
if [ ! -e "$R/.claude/.harness/task-base/br-feat-merged.sha" ] \
   && [ ! -e "$R/.claude/.harness/tree-base/br-feat-merged.dirty" ] \
   && [ ! -e "$R/.claude/.harness/done-state/br-feat-merged.json" ]; then
  ok "TERMINAL REAP: merged branch's task state REAPED (base+tree+done)"
else
  bad "merged branch state not fully reaped"
fi
# Unmerged (in-progress) branch state KEPT.
if [ -e "$R/.claude/.harness/task-base/br-feat-open.sha" ] \
   && [ -e "$R/.claude/.harness/tree-base/br-feat-open.dirty" ] \
   && [ -e "$R/.claude/.harness/done-state/br-feat-open.json" ]; then
  ok "TERMINAL REAP: in-progress (unmerged) branch's task state KEPT"
else
  bad "in-progress branch state was reaped (INVARIANT VIOLATION)"
fi
rm -rf "$R"

# ============================================================================
# PART 2 — GONE branch: a br-* key with no matching branch is reaped; a key that
# matches a live unmerged branch is kept.
# ============================================================================
R=$(mktemp -d)
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '.claude/\n' > "$R/.gitignore"; printf 'a\n' > "$R/a.txt"
git -C "$R" add -A; git -C "$R" commit -qm c1
mkdir -p "$R/.claude/.harness/baselines"
git -C "$R" checkout -q -b feat-live
printf 'l\n' > "$R/l.txt"; git -C "$R" add -A; git -C "$R" commit -qm lwork
# br-gone has NO branch; br-feat-live matches a live unmerged branch.
seed_task_state "$R" "br-gone"
seed_task_state "$R" "br-feat-live"
run_snapshot "$R" sG startup
if [ ! -e "$R/.claude/.harness/task-base/br-gone.sha" ]; then
  ok "TERMINAL REAP: br-* key with a GONE branch REAPED"
else
  bad "gone-branch key was not reaped"
fi
if [ -e "$R/.claude/.harness/task-base/br-feat-live.sha" ]; then
  ok "TERMINAL REAP: key matching a live unmerged branch KEPT"
else
  bad "live-branch key was reaped (INVARIANT VIOLATION)"
fi
rm -rf "$R"

# ============================================================================
# PART 2 — TRUNK UNCONFIDENT: no main/master, no config trunk → SKIP reap.
# ============================================================================
R=$(mktemp -d)
git -C "$R" init -q -b develop
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '.claude/\n' > "$R/.gitignore"; printf 'a\n' > "$R/a.txt"
git -C "$R" add -A; git -C "$R" commit -qm c1
mkdir -p "$R/.claude/.harness/baselines"
# No done-config trunk, no main/master → unconfident. Seed a bogus br-* key.
seed_task_state "$R" "br-anything"
run_snapshot "$R" sU startup
if [ -e "$R/.claude/.harness/task-base/br-anything.sha" ] \
   && [ -e "$R/.claude/.harness/done-state/br-anything.json" ]; then
  ok "TERMINAL REAP SKIPPED: unconfident trunk → nothing reaped (safety)"
else
  bad "terminal reap ran with unconfident trunk (SAFETY VIOLATION)"
fi
rm -rf "$R"

# ============================================================================
# PART 3 — REVIEW-LOG HYGIENE: current HEAD + live branch tip kept; random
# superseded sha deleted.
# ============================================================================
R=$(mktemp -d)
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '.claude/\n' > "$R/.gitignore"; printf 'a\n' > "$R/a.txt"
git -C "$R" add -A; git -C "$R" commit -qm c1
mkdir -p "$R/.claude/.harness/review-log" "$R/.claude/.harness/baselines"
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
# A live branch with a DIFFERENT tip commit.
git -C "$R" checkout -q -b other
printf 'b\n' > "$R/b.txt"; git -C "$R" add -A; git -C "$R" commit -qm c2
TIP_SHA=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main
RANDOM_SHA="0000000000000000000000000000000000000000"
printf '{}\n' > "$R/.claude/.harness/review-log/$HEAD_SHA.json"
printf '{}\n' > "$R/.claude/.harness/review-log/$TIP_SHA.json"
printf '{}\n' > "$R/.claude/.harness/review-log/$RANDOM_SHA.json"
run_snapshot "$R" sR startup
if [ -e "$R/.claude/.harness/review-log/$HEAD_SHA.json" ]; then
  ok "REVIEW-LOG HYGIENE: current HEAD's log KEPT"
else
  bad "current HEAD's review-log was deleted (SAFETY VIOLATION)"
fi
if [ -e "$R/.claude/.harness/review-log/$TIP_SHA.json" ]; then
  ok "REVIEW-LOG HYGIENE: live branch tip's log KEPT"
else
  bad "live branch tip's review-log was deleted"
fi
if [ ! -e "$R/.claude/.harness/review-log/$RANDOM_SHA.json" ]; then
  ok "REVIEW-LOG HYGIENE: superseded (non-tip, non-HEAD) log DELETED"
else
  bad "superseded review-log was not deleted"
fi
rm -rf "$R"

# ============================================================================
# PART 3 — REVIEW-LOG HYGIENE (blob chain): an ANCESTOR (intermediate, non-tip)
# commit's log on a LIVE task branch is KEPT — blob-keyed coverage walks the
# whole chain, so it is still load-bearing. hc_live_review_shas widens the
# keep-set to every commit in base..tip of a live branch (given its pinned base).
# ============================================================================
R=$(mktemp -d)
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '.claude/\n' > "$R/.gitignore"; printf 'a\n' > "$R/a.txt"
git -C "$R" add -A; git -C "$R" commit -qm c1
mkdir -p "$R/.claude/.harness/review-log" "$R/.claude/.harness/baselines" "$R/.claude/.harness/task-base"
BASE_SHA=$(git -C "$R" rev-parse HEAD)          # trunk tip = task base
git -C "$R" checkout -q -b feat-chain
printf 'b\n' > "$R/b.txt"; git -C "$R" add -A; git -C "$R" commit -qm c2
MID_SHA=$(git -C "$R" rev-parse HEAD)           # intermediate commit (NOT the tip)
printf 'c\n' > "$R/c.txt"; git -C "$R" add -A; git -C "$R" commit -qm c3
TIP2_SHA=$(git -C "$R" rev-parse HEAD)          # branch tip
# Pin the task-base so the widening can compute base..tip.
printf '%s\n' "$BASE_SHA" > "$R/.claude/.harness/task-base/br-feat-chain.sha"
BOGUS_SHA="1111111111111111111111111111111111111111"
printf '{}\n' > "$R/.claude/.harness/review-log/$MID_SHA.json"    # ancestor log
printf '{}\n' > "$R/.claude/.harness/review-log/$TIP2_SHA.json"   # tip log
printf '{}\n' > "$R/.claude/.harness/review-log/$BOGUS_SHA.json"  # off-chain
run_snapshot "$R" sC startup
if [ -e "$R/.claude/.harness/review-log/$MID_SHA.json" ]; then
  ok "REVIEW-LOG HYGIENE: ancestor intermediate log on a LIVE branch KEPT (chain-aware)"
else
  bad "ancestor intermediate log on a live branch was DELETED (chain broken)"
fi
if [ ! -e "$R/.claude/.harness/review-log/$BOGUS_SHA.json" ]; then
  ok "REVIEW-LOG HYGIENE: off-chain bogus log still DELETED alongside the kept chain"
else
  bad "off-chain bogus log survived"
fi
rm -rf "$R"

# ============================================================================
# PART 1 — SOURCE GUARD: compact must NOT overwrite an existing session baseline
# (.sha AND .dirty), even though the tree changed. clear/startup DOES refresh.
# current-session marker is still written on compact.
# ============================================================================
# Fresh session-mode repo (on trunk main → session mode).
mk_session_repo() {
  local r; r=$(mktemp -d)
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf '.claude/\n' > "$r/.gitignore"; printf 'a\n' > "$r/a.txt"
  git -C "$r" add -A; git -C "$r" commit -qm c1
  mkdir -p "$r/.claude/.harness/baselines" "$r/.claude/.harness/done-state"
  printf '%s' "$r"
}

R=$(mk_session_repo)
SID=cg
# Seed an EXISTING baseline for this session with a distinctive marker line.
OLD_HEAD=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$OLD_HEAD" > "$R/.claude/.harness/baselines/$SID.sha"
printf '?? sentinel-preexisting.txt\n' > "$R/.claude/.harness/baselines/$SID.dirty"
# Change the tree (agent's mid-task work) AND move HEAD.
printf 'mid\n' > "$R/mid.txt"; git -C "$R" add -A; git -C "$R" commit -qm midwork
printf 'wip\n' > "$R/wip.txt"   # uncommitted mid-task work
NEW_HEAD=$(git -C "$R" rev-parse HEAD)
# Compact SessionStart — must preserve BOTH existing baselines.
run_snapshot "$R" "$SID" compact
if [ "$(cat "$R/.claude/.harness/baselines/$SID.sha")" = "$OLD_HEAD" ]; then
  ok "SOURCE GUARD: compact did NOT overwrite existing baseline .sha"
else
  bad "compact clobbered baseline .sha (now $(cat "$R/.claude/.harness/baselines/$SID.sha"), expected $OLD_HEAD)"
fi
if grep -Fxq '?? sentinel-preexisting.txt' "$R/.claude/.harness/baselines/$SID.dirty" 2>/dev/null; then
  ok "SOURCE GUARD: compact did NOT overwrite existing baseline .dirty (sentinel intact)"
else
  bad "compact clobbered baseline .dirty: $(cat "$R/.claude/.harness/baselines/$SID.dirty")"
fi
# current-session marker still written on compact.
if [ "$(cat "$R/.claude/.harness/current-session" 2>/dev/null)" = "$SID" ]; then
  ok "SOURCE GUARD: current-session marker still written on compact"
else
  bad "compact did not write current-session marker"
fi
rm -rf "$R"

# clear (or startup) DOES refresh the session baseline.
R=$(mk_session_repo)
SID=cl
OLD_HEAD=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$OLD_HEAD" > "$R/.claude/.harness/baselines/$SID.sha"
printf '?? sentinel-preexisting.txt\n' > "$R/.claude/.harness/baselines/$SID.dirty"
printf 'mid\n' > "$R/mid.txt"; git -C "$R" add -A; git -C "$R" commit -qm midwork
NEW_HEAD=$(git -C "$R" rev-parse HEAD)
run_snapshot "$R" "$SID" clear
if [ "$(cat "$R/.claude/.harness/baselines/$SID.sha")" = "$NEW_HEAD" ]; then
  ok "SOURCE GUARD: clear REFRESHED baseline .sha to new HEAD"
else
  bad "clear did not refresh baseline .sha"
fi
if ! grep -Fxq '?? sentinel-preexisting.txt' "$R/.claude/.harness/baselines/$SID.dirty" 2>/dev/null; then
  ok "SOURCE GUARD: clear REFRESHED baseline .dirty (sentinel gone)"
else
  bad "clear did not refresh baseline .dirty"
fi
rm -rf "$R"

# compact FIRST SIGHT (no existing baseline) → writes it (absent → write).
R=$(mk_session_repo)
SID=cf
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
run_snapshot "$R" "$SID" compact
if [ -f "$R/.claude/.harness/baselines/$SID.sha" ] \
   && [ "$(cat "$R/.claude/.harness/baselines/$SID.sha")" = "$HEAD_SHA" ]; then
  ok "SOURCE GUARD: compact WRITES baseline when ABSENT (first sight)"
else
  bad "compact did not write an absent baseline on first sight"
fi
rm -rf "$R"

# ============================================================================
# HELPER UNIT — hc_live_task_keys: pure keep-set decision, testable w/o deletion.
# ============================================================================
R=$(mktemp -d)
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf 'a\n' > "$R/a.txt"; git -C "$R" add -A; git -C "$R" commit -qm c1
git -C "$R" checkout -q -b feat-merged
printf 'm\n' > "$R/m.txt"; git -C "$R" add -A; git -C "$R" commit -qm mw
git -C "$R" checkout -q main; git -C "$R" merge -q --no-ff feat-merged -m merge
git -C "$R" checkout -q -b feat-open
printf 'o\n' > "$R/o.txt"; git -C "$R" add -A; git -C "$R" commit -qm ow
KEYS=$( . "$COMMON"; hc_live_task_keys "$R" "main" )
if printf '%s\n' "$KEYS" | grep -Fxq "br-feat-open" \
   && ! printf '%s\n' "$KEYS" | grep -Fxq "br-feat-merged" \
   && ! printf '%s\n' "$KEYS" | grep -Fxq "br-main"; then
  ok "HELPER hc_live_task_keys: unmerged branch in keep-set; merged + trunk excluded"
else
  bad "hc_live_task_keys keep-set wrong: [$KEYS]"
fi
# A freshly-forked branch (ancestor of trunk, would look "merged") passed as the
# current-branch arg must ALWAYS be kept — protects the active task from the
# detached-HEAD race (current branch derived independently from the pin).
git -C "$R" checkout -q -b fresh-fork   # no divergent commits → ancestor of main
FF=$( . "$COMMON"; hc_live_task_keys "$R" "main" "fresh-fork" )
if printf '%s\n' "$FF" | grep -Fxq "br-fresh-fork"; then
  ok "HELPER hc_live_task_keys: current-branch arg kept even when ancestor of trunk"
else
  bad "current-branch (ancestor of trunk) dropped from keep-set: [$FF]"
fi
git -C "$R" checkout -q feat-open
# Unconfident trunk (empty) → emit nothing.
EMPTY=$( . "$COMMON"; hc_live_task_keys "$R" "" )
# (empty trunk means detect runs against R; main exists so it's confident — pass
#  an explicit non-existent to force unconfident is not possible, so verify the
#  documented contract: passing empty falls back to detect, which finds main.)
if printf '%s\n' "$EMPTY" | grep -Fxq "br-feat-open"; then
  ok "HELPER hc_live_task_keys: empty trunk arg → falls back to hc__detect_trunk"
else
  bad "hc_live_task_keys fallback-detect wrong: [$EMPTY]"
fi
rm -rf "$R"

echo
echo "test-cleanup: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
