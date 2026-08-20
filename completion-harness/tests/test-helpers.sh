#!/bin/bash
#
# Shared test-suite helpers (sourced by completion-harness/tests/test-*.sh).
#
# Consolidates what every suite in this directory used to reimplement:
#   - PASS/FAIL counters + ok()/bad()/eq() (the majority style: ~20 suites).
#   - CASES/FAILS counters + assert_eq()/assert_contains()/assert_empty()/
#     assert_nonempty() (the minority style: test-hc-state.sh, test-p2-emission.sh
#     — kept as its own family rather than forced onto PASS/FAIL, since those
#     files also do their own inline CASES/FAILS bookkeeping outside the
#     assert_* calls; unifying the counter name too would mean rewriting every
#     such inline site for no behavioral gain).
#   - the mktemp-dir + trap cleanup fixture-repo builder (hc__test_make_repo),
#     which had ALREADY DRIFTED between test-tree-status.sh (no cleanup trap at
#     all — a leak, fixed here) and test-p2-emission.sh (CLEANUP_DIRS + trap).
#
# Suites with fixture needs beyond the shared core (extra commits, a modified
# config) keep a small LOCAL make_repo()/seed_*() wrapper that composes
# hc__test_make_repo — see the per-file comments where that happens. That is
# deliberate, non-duplicated, file-specific setup, not the drift this file
# eliminates.
#
# Sourced, never executed.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$TESTS_DIR/fixtures"

# ---------------------------------------------------------------------------
# PASS/FAIL family (ok/bad/eq) — the majority style.
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s (got: %s)\n' "$1" "${2:-}"; }
# eq <label> <expected> <actual>
eq()  { if [ "$2" = "$3" ]; then ok "$1 = $2"; else bad "$1 expected '$2'" "$3"; fi; }

# ---------------------------------------------------------------------------
# CASES/FAILS family (assert_eq/assert_contains/assert_empty/assert_nonempty)
# — test-hc-state.sh, test-p2-emission.sh.
# ---------------------------------------------------------------------------
CASES=0
FAILS=0

# assert_eq <label> <actual> <expected>
assert_eq() {
  local label="$1" actual="$2" expected="$3"
  CASES=$((CASES + 1))
  if [ "$actual" = "$expected" ]; then
    printf 'PASS  %s (= %s)\n' "$label" "$expected"
  else
    printf 'FAIL  %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    FAILS=$((FAILS + 1))
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  CASES=$((CASES + 1))
  case "$haystack" in
    *"$needle"*) printf 'PASS  %s (contains "%s")\n' "$label" "$needle" ;;
    *) printf 'FAIL  %s: [%s] does not contain [%s]\n' "$label" "$haystack" "$needle"
       FAILS=$((FAILS + 1)) ;;
  esac
}

assert_empty() {
  local label="$1" actual="$2"
  CASES=$((CASES + 1))
  if [ -z "$actual" ]; then
    printf 'PASS  %s (empty as expected)\n' "$label"
  else
    printf 'FAIL  %s: expected empty, got [%s]\n' "$label" "$actual"
    FAILS=$((FAILS + 1))
  fi
}

assert_nonempty() {
  local label="$1" actual="$2"
  CASES=$((CASES + 1))
  if [ -n "$actual" ]; then
    printf 'PASS  %s (non-empty: %s)\n' "$label" "$actual"
  else
    printf 'FAIL  %s: expected non-empty, got empty\n' "$label"
    FAILS=$((FAILS + 1))
  fi
}

# ---------------------------------------------------------------------------
# Fixture-repo builder + cleanup tracking.
# ---------------------------------------------------------------------------
CLEANUP_DIRS=""
hc__test_cleanup() {
  local d
  for d in $CLEANUP_DIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null
  done
}
trap hc__test_cleanup EXIT INT TERM

# hc__test_mktemp_d — mktemp -d wrapper that guarantees a non-empty result.
# An empty result would make every subsequent `git -C "$dir"` silently operate
# on the caller's cwd (the real repo checkout) instead of failing loudly —
# the exact bug class hc__test_make_repo's own guard (below) closed. Any
# fixture builder in this suite that rolls its own mktemp -d should route it
# through here instead of duplicating the fallback literal.
hc__test_mktemp_d() {
  local d
  d=$(mktemp -d)
  [ -n "$d" ] || d="/nonexistent-hc-test-mktemp-failed-$$"
  printf '%s' "$d"
}

# hc__test_make_repo [mode]
#   mode "task" -> checks out feature/x off the root commit (task mode:
#                  branch != trunk).
#   default     -> stays on main (session mode).
# Creates a throwaway git repo: harness state dirs, a committed copy of
# fixtures/done-config.json (trunk main), and a .gitignore excluding only
# .claude/.harness/ (the config stays tracked so suites can assert against a
# real trunk config; the harness's own runtime state is gitignored, mirroring
# the shipped plugin). Registers the dir for the EXIT/INT/TERM cleanup trap
# above and echoes its path.
hc__test_make_repo() {
  local mode="${1:-}"
  local dir
  dir=$(hc__test_mktemp_d)
  CLEANUP_DIRS="$CLEANUP_DIRS $dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name  "t"

  mkdir -p "$dir/.claude/.harness/done-state" \
           "$dir/.claude/.harness/review-log" \
           "$dir/.claude/.harness/baselines" \
           "$dir/.claude/.harness/tree-base" \
           "$dir/.claude/.harness/task-base"
  cp "$FIX/done-config.json" "$dir/.claude/done-config.json"
  echo ".claude/.harness/" > "$dir/.gitignore"

  echo "root" > "$dir/root.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m root

  if [ "$mode" = "task" ]; then
    git -C "$dir" checkout -q -b feature/x
  fi

  printf '%s' "$dir"
}
