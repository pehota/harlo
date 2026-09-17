#!/bin/bash
#
# dod/lib/gitref.sh — git-derived identity: task key, diff hash, ancestry.
#
# No `set -e`/`set -u`/pipefail (sourced into hooks). Every git call guarded;
# callers get empty string / non-zero on failure, never a crash.
#
# Sanitisation happens ONCE here, inside dod_task_key, unlike v1
# (harness-common.sh) which re-sanitised at three call sites.

GITREF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# dod__sanitize <str> — every char not in [A-Za-z0-9_.-] becomes '-'.
dod__sanitize() {
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null
}

# dod_task_key <repo_dir> — sanitised current branch name. Empty on failure
# (detached HEAD, non-git dir).
dod_task_key() {
  local repo="$1" branch=""
  branch=$(git -C "$repo" symbolic-ref -q --short HEAD 2>/dev/null)
  [ -n "$branch" ] || return 1
  dod__sanitize "$branch"
}

# dod_diff_hash <repo_dir> <baseline_sha> — stable hash of "which paths
# changed since baseline, and their current blob content". Identical
# working-tree content -> identical hash, regardless of how many times it's
# been committed; any touched/added/deleted path (relative to baseline, plus
# untracked) -> different hash.
#
# MUST diff against the task's baseline SHA, never HEAD, and MUST NOT emit
# `git diff`'s own patch text. Two failure modes were found the hard way:
#
#   1. `git diff HEAD` is distance-from-HEAD, not a content fingerprint —
#      committing moves HEAD to match the working tree, so a HEAD-relative
#      diff collapses to empty even though nothing in the working tree
#      changed. Fixed by diffing against the fixed baseline instead (a
#      commit with no net tree change then can't move the hash).
#
#   2. Even diffed against a fixed baseline, patch text is NOT
#      commit-invariant: before a commit, a newly-added file is untracked and
#      gets dumped once by the untracked-files loop; after committing it, the
#      same file is now tracked and ALSO appears in `git diff <baseline>` as
#      a new-file patch — same logical content, different bytes fed to
#      hash-object (patch-file framing vs a raw dump), so the hash still
#      moved. Fixed by hashing (path, current blob content) pairs instead of
#      patch text: the path list is diff --name-only (tracked, vs baseline)
#      unioned with untracked paths, and each path contributes its OWN
#      current bytes via `git hash-object` — content-addressed and identical
#      whether that path is currently tracked or untracked.
#
# A path present in the diff but missing from the working tree (deleted since
# baseline) hashes to the literal marker "MISSING" rather than being silently
# skipped — a delete must move the hash same as any other change.
#
# Excludes .dod/ defensively even though it belongs in .gitignore: result.json
# and state.json are themselves written as untracked files under .dod/, so
# without this exclusion every dod_diff_hash call after a result_write would
# hash its own output, self-invalidating the very result it just wrote. Never
# rely on .gitignore alone for this — a repo that hasn't picked up the ignore
# rule yet must not wedge the gate.
dod_diff_hash() {
  local repo="$1" baseline="$2"
  [ -n "$baseline" ] || return 1
  {
    {
      git -C "$repo" diff --name-only "$baseline" -- 2>/dev/null
      git -C "$repo" ls-files --others --exclude-standard 2>/dev/null
    } | sort -u | while IFS= read -r f; do
      case "$f" in .dod/*) continue ;; esac
      printf '%s\n' "$f"
      git -C "$repo" hash-object "$repo/$f" 2>/dev/null || printf 'MISSING\n'
    done
  } | git hash-object --stdin 2>/dev/null
}

# dod_is_ancestor <repo_dir> <ancestor_sha> <descendant_sha> — 0 if ancestor
# is reachable from descendant, 1 otherwise (including unknown SHAs).
dod_is_ancestor() {
  local repo="$1" anc="$2" desc="$3"
  [ -n "$anc" ] && [ -n "$desc" ] || return 1
  git -C "$repo" merge-base --is-ancestor "$anc" "$desc" 2>/dev/null
}

# dod_baseline_worktree <repo_dir> <task_key> <baseline_sha> — ensures a
# worktree checked out at baseline_sha exists at
# .dod/<task_key>/baseline-worktree, creating it only if missing or stale
# (§5.3, D18: "resolved lazily in a persistent worktree"). Prints the
# worktree's absolute path on success, prints nothing and returns 1 on
# failure. Idempotent and cheap to call every time a caller needs it — the
# expensive `git worktree add` only actually runs once per task.
#
# Lazy and persistent, not eager-per-check, because most checks pass on the
# first try and never need their baseline verdict at all — building the
# worktree unconditionally at /dod:define time would pay a full checkout's
# cost on every task, including ones with zero pre-existing failures.
# Persistent (not torn down after one lookup) because a single verify round
# commonly re-checks several failing requirements' baselines, and repeated
# `git worktree add`/`remove` churn would be pure waste against the same sha.
#
# Never touches the caller's working tree or index — worktrees are isolated
# checkouts sharing the same .git, so recompiled artefacts or lockfile state
# in the main tree are unaffected by this.
dod_baseline_worktree() {
  local repo="$1" task_key="$2" baseline_sha="$3" wt
  [ -n "$repo" ] && [ -n "$task_key" ] && [ -n "$baseline_sha" ] || return 1
  wt="$repo/.dod/$task_key/baseline-worktree"

  if [ -d "$wt/.git" ] || [ -f "$wt/.git" ]; then
    local wt_sha
    wt_sha=$(git -C "$wt" rev-parse -q --verify HEAD 2>/dev/null)
    if [ "$wt_sha" = "$baseline_sha" ]; then
      printf '%s' "$wt"
      return 0
    fi
    # stale (task amended to a new baseline) -> rebuild it at the new sha.
    git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
    rm -rf "$wt" 2>/dev/null
  fi

  mkdir -p "$(dirname "$wt")" 2>/dev/null
  git -C "$repo" worktree add --detach --force "$wt" "$baseline_sha" >/dev/null 2>&1 || return 1
  printf '%s' "$wt"
  return 0
}

# dod_baseline_worktree_remove <repo_dir> <task_key> — tears down the
# worktree `dod_baseline_worktree` created, if any. Called from gate.sh on
# every terminal-status transition — branch 10 (all pass) alongside
# status:=passed, per §5.1/§6.2's branch-10 row, AND branch 6 (escalation)
# alongside status:=escalated. Both are terminal: once status != "open",
# branch 3 releases every subsequent Stop before branch 6/10 run again, so a
# worktree not torn down here would never be torn down at all. Safe to call
# when no worktree exists.
dod_baseline_worktree_remove() {
  local repo="$1" task_key="$2" wt
  [ -n "$repo" ] && [ -n "$task_key" ] || return 1
  wt="$repo/.dod/$task_key/baseline-worktree"
  [ -d "$wt" ] || return 0
  git -C "$repo" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "$wt" 2>/dev/null
  return 0
}
