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

# dod_diff_hash <repo_dir> — stable hash of tracked-file diff (vs HEAD) plus
# untracked file contents. Identical tree -> identical hash; any touched
# tracked file or added untracked file -> different hash.
dod_diff_hash() {
  local repo="$1"
  {
    git -C "$repo" diff HEAD -- 2>/dev/null
    git -C "$repo" ls-files --others --exclude-standard -z 2>/dev/null \
      | while IFS= read -r -d '' f; do
          printf '%s\n' "$f"
          cat "$repo/$f" 2>/dev/null
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
