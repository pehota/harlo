#!/bin/bash
#
# Shared test-suite helpers (sourced by dod/tests/test-*.sh).
#
# PASS/FAIL counters + ok()/bad()/eq(), and a mktemp-dir + trap cleanup
# fixture-repo builder (hc__test_make_repo). Ported from
# completion-harness/tests/test-helpers.sh, trimmed to what this plugin's
# suite actually uses.
#
# Sourced, never executed.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$TESTS_DIR/fixtures"

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

# ---------------------------------------------------------------------------
# UNTIDY fixtures.
#
# hc__test_make_repo above builds the TIDY shape: CLAUDE_PROJECT_DIR == git
# toplevel, a tracked+committed .claude/done-config.json, and a .gitignore
# carrying .claude/.harness/. Every suite using only that shape passed while
# four gate bypasses were live, because the bypasses are all invisible in it.
# The builders below deliberately break one property each.
# ---------------------------------------------------------------------------

# hc__test_seed_session_baseline <repo> <session_id> [base_sha]
#
# Writes the two session-mode anchors hc_resolve reads: baselines/<sid>.sha
# (default: current HEAD) and an EMPTY baselines/<sid>.dirty, plus the
# current-session marker.
#
# The .dirty is written EMPTY but PRESENT on purpose. hc_tree_status treats an
# ABSENT baseline as "degraded" and a zero-length one as "nothing was
# pre-existing" — both classify every current porcelain line as a BLOCKER, but
# only the present-and-empty form says so by intent. A classification test
# wants every line to reach the classifier, so nothing can pass by being
# whitelisted as pre-existing dirt.
hc__test_seed_session_baseline() {
  local repo="$1" sid="$2" sha="${3:-}"
  [ -n "$sha" ] || sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
  mkdir -p "$repo/.claude/.harness/baselines" 2>/dev/null
  printf '%s\n' "$sha" > "$repo/.claude/.harness/baselines/${sid}.sha"
  : > "$repo/.claude/.harness/baselines/${sid}.dirty"
  printf '%s' "$sid" > "$repo/.claude/.harness/current-session"
}

# hc__test_make_repo_subdir [mode] — CLAUDE_PROJECT_DIR is a SUBDIRECTORY of
# the git toplevel (toplevel/app), not the toplevel itself. Echoes the SUBDIR
# (the project dir); the toplevel is its parent.
#
# Catches pathspec and ownership derivation. `git status --porcelain` prints
# paths relative to the REPOSITORY ROOT, so every path the classifier sees here
# is prefixed "app/" while the harness's own path literals (.claude/.harness,
# .claude/done-config.json) are project-dir-relative. A pathspec built from a
# porcelain path and handed to git WITHOUT a ':/' (root-relative) prefix is
# resolved relative to the CWD — i.e. against app/app/... — and silently
# matches nothing.
hc__test_make_repo_subdir() {
  local mode="${1:-}"
  local dir proj
  dir=$(hc__test_mktemp_d)
  CLEANUP_DIRS="$CLEANUP_DIRS $dir"
  proj="$dir/app"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name  "t"

  mkdir -p "$proj/.claude/.harness/baselines" \
           "$proj/.claude/.harness/tree-base" \
           "$proj/.claude/.harness/task-base"
  cp "$FIX/done-config.json" "$proj/.claude/done-config.json"
  printf 'app/.claude/.harness/\n' > "$dir/.gitignore"

  echo "root" > "$dir/root.txt"
  echo "app root" > "$proj/app-root.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m root

  if [ "$mode" = "task" ]; then
    git -C "$dir" checkout -q -b feature/x
  fi

  printf '%s' "$proj"
}

# hc__test_make_repo_untracked_claude — .claude/ is WHOLLY UNTRACKED and NOT
# gitignored, and holds ONLY harness state (no done-config.json, so the
# classifier falls back to its built-in artifact globs).
#
# Catches the porcelain collapse: git reports a wholly-untracked directory as
# the single line "?? .claude/", never its contents. A classifier that excludes
# harness state by literal ".claude/.harness" prefix never matches that line,
# so the state dir the harness created for itself reads as PRODUCT dirt — a
# repo that manufactures its own permanent blocker. This is the real shape of
# any repo where dod-session-start.sh runs before .claude/ is gitignored.
hc__test_make_repo_untracked_claude() {
  local dir
  dir=$(hc__test_mktemp_d)
  CLEANUP_DIRS="$CLEANUP_DIRS $dir"

  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name  "t"

  echo "root" > "$dir/root.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m root

  # Created AFTER the commit and never added: porcelain collapses the lot.
  mkdir -p "$dir/.claude/.harness/baselines" \
           "$dir/.claude/.harness/tree-base" \
           "$dir/.claude/.harness/task-base" \
           "$dir/.claude/.harness/task-dod/verified" \
           "$dir/.claude/.harness/task-dod/archive"

  printf '%s' "$dir"
}

# hc__test_make_repo_two_keys — one repo, TWO task keys: branches feature/a and
# feature/b, both off the root commit, left checked out on feature/a.
#
# Catches key isolation. Every earlier fixture used a single task key, so a
# latch, contract or verification result keyed under the WRONG key was
# indistinguishable from one keyed correctly.
hc__test_make_repo_two_keys() {
  local dir
  dir=$(hc__test_make_repo)
  git -C "$dir" branch feature/a main
  git -C "$dir" branch feature/b main
  git -C "$dir" checkout -q feature/a
  printf '%s' "$dir"
}

# hc__test_plant_base_sha <repo> <session_id> <value> — write <value> verbatim
# into baselines/<sid>.sha.
#
# That file is AGENT-WRITABLE and its contents are handed straight to git.
# `git rev-parse -q --verify` resolves ANY refname, so "HEAD", "main" or
# "refs/heads/main" all "verify" — and "HEAD" collapses HC_BASE..HEAD to the
# empty range, making the whole committed half of the changeset disappear.
# That was a full gate bypass.
hc__test_plant_base_sha() {
  mkdir -p "$1/.claude/.harness/baselines" 2>/dev/null
  printf '%s\n' "$3" > "$1/.claude/.harness/baselines/$2.sha"
}

# hc__test_amend_head <repo> [message] — rewrite HEAD in place.
#
# Catches anchors that still RESOLVE but are no longer ancestors of HEAD: the
# pre-amend sha survives in the object db (so rev-parse succeeds) while every
# HEAD-keyed artefact — a verification result above all — now names a commit
# that is not on the branch.
hc__test_amend_head() {
  git -C "$1" commit -q --amend --allow-empty -m "${2:-amended}" >/dev/null 2>&1
}

# hc__test_write_session_config <repo> <json> — write the AGENT-WRITABLE
# session override layer, .claude/.harness/session-config.json.
#
# Catches the classification bypass: hc_cfg consults this layer FIRST, so a
# single {"artifact_paths":["*"]} written here used to classify the entire repo
# as artifact surface and silence the gate completely. artifact_paths must be
# read from the REPO config only.
hc__test_write_session_config() {
  mkdir -p "$1/.claude/.harness" 2>/dev/null
  printf '%s' "$2" > "$1/.claude/.harness/session-config.json"
}
