#!/bin/bash
#
# task-DoD plugin — SessionStart hook.
#
# Records the AUTHORITATIVE current-session marker and pins the tree baseline
# so the rest of the plugin (dod-write.sh, dod-verify-*.sh, dod-gate.sh) can
# resolve a REAL session id and classify "pre-existing vs introduced" changes
# — instead of every caller falling back to the "unknown-session" / "newest
# baselines/*.sha" heuristics, which can silently key a written contract or
# verification result under a DIFFERENT id than the one the Stop gate reads.
#
# This is a deliberately MINIMAL, dod-scoped subset of
# completion-harness/scripts/baseline-snapshot.sh — that script also handles
# test-snapshot capture, done-config seeding, FSM steering messages, and
# multi-directory state reaping, none of which dod's own scripts consume.
# Porting all of that would be scope creep; dod needs exactly: the
# current-session marker (read by dod-write.sh, dod-verify-*.sh) and the tree
# baseline (read by hc_tree_status, via dod-verify-preflight.sh and
# dod-verify-write-result.sh).
#
# Never blocks session start and never exits non-zero: everything is guarded.
# No `set -e`.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

SESSION_ID=""
SOURCE=""
if hc_has_fn hc_read_hook_input; then
  hc_read_hook_input
  SESSION_ID="$HC_HOOK_SESSION_ID"
  # SessionStart source: startup | resume | clear | compact | fork (top-level).
  SOURCE="$HC_HOOK_SOURCE"
fi
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"

IS_COMPACT=0
[ "$SOURCE" = "compact" ] && IS_COMPACT=1

# Literal, not hc__harness_dir: mirrors baseline-snapshot.sh's own reasoning —
# avoids coupling this bootstrap mkdir to whether sourcing above succeeded.
HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
BASELINE_DIR="$HARNESS_DIR/baselines"
mkdir -p "$BASELINE_DIR" 2>/dev/null

# --- record the AUTHORITATIVE current-session marker ------------------------
# SessionStart is the one hook that knows the REAL session_id (from its own
# hook stdin) and reliably runs before any edit. dod-write.sh,
# dod-verify-preflight.sh, and dod-verify-write-result.sh all prefer this
# marker over the "newest baselines/*.sha" heuristic, which can pick the
# WRONG id (a stale or a parallel session's baseline). Written before the
# git-repo check so it is recorded even in a non-git dir.
printf '%s\n' "$SESSION_ID" > "$HARNESS_DIR/current-session" 2>/dev/null

# --- record baseline SHA -----------------------------------------------------
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  printf 'no-git\n' > "$BASELINE_DIR/${SESSION_ID}.sha" 2>/dev/null
  exit 0
fi
# Compact preserves an existing session baseline (mid-task continuation); it
# must not be re-snapshotted from the dirty mid-task HEAD. Write only if absent.
if [ "$IS_COMPACT" -eq 1 ] && [ -f "$BASELINE_DIR/${SESSION_ID}.sha" ]; then
  : # keep the existing session baseline
else
  printf '%s\n' "$HEAD_SHA" > "$BASELINE_DIR/${SESSION_ID}.sha" 2>/dev/null
fi

# --- resolve identity (lazily pins the task base in task mode) --------------
if hc_has_fn hc_resolve; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi

# --- pin the tree baseline (for hc_tree_status) ------------------------------
# Whole `git status --porcelain` lines — the "pre-existing" set hc_tree_status
# uses to distinguish pre-existing changes from ones the agent introduces. The
# path is resolver-pinned (HC_TREE_BASE_FILE): task-scoped in task mode,
# session-scoped otherwise. SessionStart is the one entry point that reliably
# runs BEFORE any edits, so pinning here is safe.
#
#   SESSION mode → rewrite every SessionStart (fresh per session; the
#                  changeset IS the session).
#   TASK mode    → write ONLY IF it does not already exist — pin ONCE at the
#                  first session on the branch and NEVER re-seed.
#
# Always create the file (even when empty) so "missing" (→ strict, per
# hc_tree_status) is distinguishable from "clean at baseline". Captured
# atomically (temp + mv) so a failed capture leaves NO file rather than a
# misleadingly-empty one.
if [ -z "${HC_TREE_BASE_FILE:-}" ]; then
  HC_TREE_BASE_FILE="$BASELINE_DIR/${SESSION_ID}.dirty"
fi

pin_tree_baseline() {
  local file="$1" tmp="$1.tmp.$$"
  mkdir -p "$(dirname "$file")" 2>/dev/null
  if git -C "$PROJECT_DIR" status --porcelain > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" "$file" 2>/dev/null; }
  else
    rm -f "$tmp" "$file" 2>/dev/null
  fi
}

if [ -n "$HC_TREE_BASE_FILE" ]; then
  if [ "${HC_MODE:-}" = "task" ]; then
    [ -f "$HC_TREE_BASE_FILE" ] || pin_tree_baseline "$HC_TREE_BASE_FILE"
  elif [ "$IS_COMPACT" -eq 1 ] && [ -f "$HC_TREE_BASE_FILE" ]; then
    : # compact: preserve the existing session tree baseline (do not re-seed)
  else
    pin_tree_baseline "$HC_TREE_BASE_FILE"
  fi
fi

exit 0
