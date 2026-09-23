#!/bin/bash
#
# test-host-isolation.sh — on-demand proof that the test suites never write
# into the repo that runs them.
#
# Inherited repo-local git env overrides `git -C <dir>`: with GIT_DIR (and
# GIT_WORK_TREE / GIT_INDEX_FILE) exported, every fixture's init/config/
# commit/branch/worktree-add lands in the HOST repo. Git hooks export it — a
# pre-push or pre-commit fired from a LINKED worktree sets GIT_DIR (+
# GIT_INDEX_FILE) — and GIT_DIR + GIT_WORK_TREE together commit the host's
# own dirty tree. run-tests.sh and the suites' test-helpers.sh unset it; this
# script proves they do.
#
# How: clone the current checkout (INCLUDING uncommitted changes) into a temp
# dir, add a linked worktree to the clone, snapshot the clone's git state, run
# from that worktree, with GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE exported
# at it, the clone's run-tests.sh and then one suite per test-helpers.sh /
# own-copy unset site directly; re-snapshot and diff after each. Exits
# non-zero, printing the diff, on any change. The invoking repo is only ever READ
# (git clone + ls-files + tar).
#
# Not a run-tests.sh suite (its glob only picks up test-version.sh at the
# root): it runs the whole suite itself, so it is invoked on demand:
#
#     bash test-host-isolation.sh

set -u

# This script must not leak either: drop any inherited repo-local git env so
# every git call below goes where its -C / cwd says.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars)

SRC="$(cd "$(dirname "$0")" && pwd)"
TMP=$(mktemp -d) && [ -n "$TMP" ] && [ -d "$TMP" ] || { echo "mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
CLONE="$TMP/clone"
PUSHER="$TMP/pusher"

# --- 1. clone the checkout, overlay the working tree, freeze it as a commit --
step_clone() {
  git clone -q --no-hardlinks "$SRC" "$CLONE" || return 1
  [ "$(git -C "$CLONE" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse HEAD)" ] || return 1
  # Mirror the working tree so the proof tests THIS checkout's code, not just
  # its HEAD commit: tracked changes as a patch, untracked-not-ignored files
  # copied as-is.
  local patch="$TMP/wt.patch"
  git -C "$SRC" diff --binary HEAD > "$patch" || return 1
  if [ -s "$patch" ]; then git -C "$CLONE" apply "$patch" || return 1; fi
  (cd "$SRC" && git ls-files -z -o --exclude-standard | tar --null -T - -cf -) \
    | (cd "$CLONE" && tar -xf -) || return 1
  git -C "$CLONE" add -A
  git -C "$CLONE" -c user.name=isolation -c user.email=isolation@invalid \
    commit -q --allow-empty -m "snapshot of working tree" || return 1
  git -C "$CLONE" worktree add -q --detach "$PUSHER" || return 1
}

# --- 2. snapshot every piece of git state a leak could touch ----------------
snapshot() {
  local wt
  for wt in "$CLONE" "$PUSHER"; do
    echo "## $wt"
    echo "HEAD $(git -C "$wt" rev-parse HEAD 2>&1) $(git -C "$wt" symbolic-ref -q HEAD)"
    echo "index $(git -C "$wt" ls-files -s | git hash-object --stdin)"
    echo "reflog-lines $(git -C "$wt" reflog 2>/dev/null | wc -l | tr -d ' ')"
    echo "status $(git -C "$wt" status --porcelain 2>&1 | git hash-object --stdin)"
  done
  echo "## refs";      git -C "$CLONE" for-each-ref --format='%(refname) %(objectname)'
  echo "## config";    git -C "$CLONE" config --local --list
  echo "## worktrees"; git -C "$CLONE" worktree list --porcelain
}

step_clone || { echo "test-host-isolation: could not build the clone" >&2; exit 2; }

# --- 3. run each entrypoint with repo-local git env aimed at the clone -------
# check <label> <cmd...> — run <cmd> from the pusher worktree with GIT_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE exported, then diff the clone's git state.
# Suite pass/fail is informational; only a state change fails the proof.
FAILED=0
check() {
  local label="$1"; shift
  snapshot > "$TMP/before"
  echo "test-host-isolation: [$label] running with GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE exported …"
  (
    cd "$PUSHER" || exit 1
    GIT_DIR="$(git rev-parse --absolute-git-dir)"
    GIT_WORK_TREE="$PUSHER"
    GIT_INDEX_FILE="$GIT_DIR/index"
    GIT_PREFIX=""
    export GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX
    "$@"
  ) > "$TMP/out" 2>&1
  echo "test-host-isolation: [$label] exit $? (informational)"
  snapshot > "$TMP/after"
  if diff -u "$TMP/before" "$TMP/after" > "$TMP/diff"; then
    echo "test-host-isolation: [$label] PASS — host repo git state unchanged"
  else
    echo "test-host-isolation: [$label] FAIL — wrote into the host repo:" >&2
    sed -e "s#$TMP#<tmp>#g" "$TMP/diff" >&2
    FAILED=1
  fi
}

# Pass 1: the entrypoint (its unset runs first and shadows the rest).
check "run-tests.sh" bash run-tests.sh
# Pass 2: one suite per remaining unset site, run DIRECTLY so each is proven.
check "completion-harness/tests/test-helpers.sh" bash completion-harness/tests/test-hc-state.sh
check "dod/tests/test-helpers.sh" bash dod/tests/test-gitref.sh
check "completion-harness/tests/test-gate.sh" bash completion-harness/tests/test-gate.sh

[ "$FAILED" -eq 0 ] && echo "test-host-isolation: PASS — all entrypoints isolated"
exit "$FAILED"
