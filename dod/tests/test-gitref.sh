#!/bin/bash
#
# Tests for dod/lib/gitref.sh: dod_task_key, dod_diff_hash, dod_is_ancestor.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/gitref.sh"

echo "== gitref.sh =="

# --- dod_task_key -----------------------------------------------------------
REPO=$(dod__test_make_repo task)
KEY=$(dod_task_key "$REPO")
eq "task_key sanitises feature/x" "feature-x" "$KEY"

REPO2=$(dod__test_make_repo)
KEY2=$(dod_task_key "$REPO2")
eq "task_key on trunk" "main" "$KEY2"

# sanitisation is idempotent / happens once, at the resolver
REPO3=$(dod__test_make_repo)
git -C "$REPO3" checkout -q -b 'weird@branch#name'
KEY3=$(dod_task_key "$REPO3")
case "$KEY3" in
  *[!A-Za-z0-9_.-]*) bad "task_key sanitises unsafe chars" "$KEY3" ;;
  *) ok "task_key sanitises unsafe chars" ;;
esac

# --- dod_diff_hash -----------------------------------------------------------
REPO4=$(dod__test_make_repo)
BASE4=$(git -C "$REPO4" rev-parse HEAD)
H1=$(dod_diff_hash "$REPO4" "$BASE4")
H2=$(dod_diff_hash "$REPO4" "$BASE4")
eq "diff_hash stable for identical tree" "$H1" "$H2"

echo "changed" >> "$REPO4/root.txt"
H3=$(dod_diff_hash "$REPO4" "$BASE4")
if [ "$H1" != "$H3" ]; then
  ok "diff_hash changes when a tracked file is touched"
else
  bad "diff_hash changes when a tracked file is touched" "$H3"
fi

echo "new" > "$REPO4/untracked.txt"
H4=$(dod_diff_hash "$REPO4" "$BASE4")
if [ "$H3" != "$H4" ]; then
  ok "diff_hash changes when an untracked file is added"
else
  bad "diff_hash changes when an untracked file is added" "$H4"
fi

# --- dod_diff_hash: stable across a commit that doesn't change tree content -
# Regression (reported by a peer session exercising the live skeleton):
# `git diff HEAD` measures distance-from-HEAD, not tree content. Committing
# the exact content just verified moves HEAD to match the working tree, so a
# HEAD-relative diff collapses to empty -- the gate then saw a "changed" hash
# for content that hadn't changed at all, and blocked a task that had just
# passed /dod:verify. Diffing against the fixed baseline SHA (not HEAD) means
# a commit with no net tree change must not move the hash.
H_BEFORE_COMMIT=$(dod_diff_hash "$REPO4" "$BASE4")
git -C "$REPO4" add -A
git -C "$REPO4" commit -q -am "commit the exact content just hashed"
H_AFTER_COMMIT=$(dod_diff_hash "$REPO4" "$BASE4")
eq "diff_hash stable across a commit (same content, HEAD moved)" "$H_BEFORE_COMMIT" "$H_AFTER_COMMIT"

# deleting a tracked file (relative to baseline) must move the hash, not be
# silently skipped when git hash-object can no longer read it
REPO7=$(dod__test_make_repo)
BASE7=$(git -C "$REPO7" rev-parse HEAD)
H_BEFORE_DELETE=$(dod_diff_hash "$REPO7" "$BASE7")
rm "$REPO7/root.txt"
H_AFTER_DELETE=$(dod_diff_hash "$REPO7" "$BASE7")
if [ "$H_BEFORE_DELETE" != "$H_AFTER_DELETE" ]; then
  ok "diff_hash changes when a tracked file is deleted"
else
  bad "diff_hash changes when a tracked file is deleted" "$H_AFTER_DELETE"
fi

# no baseline given -> refuse rather than silently diff against something else
if dod_diff_hash "$REPO4" ""; then
  bad "diff_hash requires a baseline argument" "accepted empty baseline"
else
  ok "diff_hash requires a baseline argument"
fi

# --- dod_diff_hash: .dod/ must never self-poison the hash -------------------
# Regression: dod__test_make_repo's fixture .gitignore lists .dod/, which
# would mask this bug. Build a repo WITHOUT that ignore rule (as a real repo
# looks before dod's own .gitignore entry has been added, or if it's absent)
# to prove the exclusion is enforced in code, not borrowed from .gitignore.
REPO6=$(dod__test_mktemp_d)
CLEANUP_DIRS="$CLEANUP_DIRS $REPO6"
git -C "$REPO6" init -q -b main
git -C "$REPO6" config user.email "t@t.t"
git -C "$REPO6" config user.name "t"
echo "root" > "$REPO6/root.txt"
git -C "$REPO6" add -A
git -C "$REPO6" commit -q -m root
BASE6=$(git -C "$REPO6" rev-parse HEAD)

H5=$(dod_diff_hash "$REPO6" "$BASE6")
mkdir -p "$REPO6/.dod/main"
echo '{"round":1}' > "$REPO6/.dod/main/result.json"
H6=$(dod_diff_hash "$REPO6" "$BASE6")
eq "diff_hash ignores .dod/ even without a .gitignore rule" "$H5" "$H6"

# --- dod_is_ancestor ---------------------------------------------------------
REPO5=$(dod__test_make_repo)
ROOT_SHA=$(git -C "$REPO5" rev-parse HEAD)
echo "more" >> "$REPO5/root.txt"
git -C "$REPO5" commit -q -am "more"
HEAD_SHA=$(git -C "$REPO5" rev-parse HEAD)

if dod_is_ancestor "$REPO5" "$ROOT_SHA" "$HEAD_SHA"; then
  ok "is_ancestor true for root -> head"
else
  bad "is_ancestor true for root -> head" "false"
fi

if dod_is_ancestor "$REPO5" "$HEAD_SHA" "$ROOT_SHA"; then
  bad "is_ancestor false for head -> root" "true"
else
  ok "is_ancestor false for head -> root"
fi

if dod_is_ancestor "$REPO5" "deadbeef0000000000000000000000000000dead" "$HEAD_SHA"; then
  bad "is_ancestor false for unknown sha" "true"
else
  ok "is_ancestor false for unknown sha"
fi

# --- dod_baseline_worktree ---------------------------------------------------
REPO6=$(dod__test_make_repo)
BASELINE6=$(git -C "$REPO6" rev-parse HEAD)
echo "post-baseline edit" >> "$REPO6/root.txt"
git -C "$REPO6" commit -q -am "post-baseline"

WT=$(dod_baseline_worktree "$REPO6" "main" "$BASELINE6")
if [ -n "$WT" ] && [ -d "$WT" ]; then
  ok "baseline_worktree creates a worktree directory"
else
  bad "baseline_worktree creates a worktree directory" "$WT"
fi
WT_CONTENT=$(cat "$WT/root.txt" 2>/dev/null)
eq "baseline_worktree checks out baseline content, not HEAD's" "root" "$WT_CONTENT"
WT_SHA=$(git -C "$WT" rev-parse -q --verify HEAD 2>/dev/null)
eq "baseline_worktree HEAD is the baseline sha" "$BASELINE6" "$WT_SHA"

# idempotent: second call at the same baseline reuses it (no rebuild, no error)
WT2=$(dod_baseline_worktree "$REPO6" "main" "$BASELINE6")
eq "baseline_worktree is idempotent at the same baseline" "$WT" "$WT2"

# stale: a different baseline_sha (e.g. task amended) rebuilds at the new sha
NEW_BASELINE=$(git -C "$REPO6" rev-parse HEAD)
WT3=$(dod_baseline_worktree "$REPO6" "main" "$NEW_BASELINE")
WT3_SHA=$(git -C "$WT3" rev-parse -q --verify HEAD 2>/dev/null)
eq "baseline_worktree rebuilds when the baseline sha changes" "$NEW_BASELINE" "$WT3_SHA"
WT3_CONTENT=$(cat "$WT3/root.txt" 2>/dev/null)
eq "rebuilt worktree reflects the new baseline's content" "root
post-baseline edit" "$WT3_CONTENT"

if dod_baseline_worktree "$REPO6" "main" "deadbeef0000000000000000000000000000dead" >/dev/null 2>&1; then
  bad "baseline_worktree fails for an unknown sha" "succeeded"
else
  ok "baseline_worktree fails for an unknown sha"
fi

# --- dod_baseline_worktree_remove --------------------------------------------
dod_baseline_worktree_remove "$REPO6" "main"
if [ ! -d "$REPO6/.dod/main/baseline-worktree" ]; then
  ok "baseline_worktree_remove tears down the worktree directory"
else
  bad "baseline_worktree_remove tears down the worktree directory" "still exists"
fi
GONE=$(git -C "$REPO6" worktree list 2>/dev/null | grep -c "baseline-worktree")
eq "baseline_worktree_remove unregisters it from git worktree list" "0" "$GONE"

# safe no-op when nothing to remove
if dod_baseline_worktree_remove "$REPO6" "main"; then
  ok "baseline_worktree_remove is a safe no-op when already removed"
else
  bad "baseline_worktree_remove is a safe no-op when already removed" "failed"
fi

echo
echo "gitref.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
