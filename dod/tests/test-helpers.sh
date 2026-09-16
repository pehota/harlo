#!/bin/bash
#
# Shared test-suite helpers (sourced by dod/tests/test-*.sh).
#
# PASS/FAIL counters + ok()/bad()/eq(), and a mktemp-dir + trap cleanup
# fixture-repo builder (dod__test_make_repo). Ported from the v1 suite
# (tag dod-v1-final, dod/tests/test-helpers.sh), trimmed and retargeted at
# v2's .dod/ state layout instead of .claude/.harness/.
#
# Sourced, never executed.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# PASS/FAIL family (ok/bad/eq).
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s (got: %s)\n' "$1" "${2:-}"; }
# eq <label> <expected> <actual>
eq()  { if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1 expected '$2'" "$3"; fi; }

# ---------------------------------------------------------------------------
# Fixture-repo builder + cleanup tracking.
# ---------------------------------------------------------------------------
CLEANUP_DIRS=""
dod__test_cleanup() {
  local d
  for d in $CLEANUP_DIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null
  done
}
trap dod__test_cleanup EXIT INT TERM

# dod__test_mktemp_d — mktemp -d wrapper guaranteed non-empty. An empty
# result would make every `git -C "$dir"` silently operate on the caller's
# real cwd instead of failing loudly.
dod__test_mktemp_d() {
  local d
  d=$(mktemp -d)
  [ -n "$d" ] || d="/nonexistent-dod-test-mktemp-failed-$$"
  printf '%s' "$d"
}

# dod__test_make_repo [mode]
#   mode "task" -> checks out feature/x off the root commit (branch != trunk).
#   default     -> stays on main.
# Throwaway git repo, single root commit, .dod/ gitignored. Registers the dir
# for the EXIT/INT/TERM cleanup trap and echoes its path.
dod__test_make_repo() {
  local mode="${1:-}"
  local dir
  dir=$(dod__test_mktemp_d)
  CLEANUP_DIRS="$CLEANUP_DIRS $dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name  "t"

  echo ".dod/" > "$dir/.gitignore"
  echo "root" > "$dir/root.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m root

  if [ "$mode" = "task" ]; then
    git -C "$dir" checkout -q -b feature/x
  fi

  printf '%s' "$dir"
}
