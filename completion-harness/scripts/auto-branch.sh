#!/bin/bash
#
# Completion Harness — PreToolUse(Write|Edit) hook: auto-branch off trunk.
#
# Fires before EVERY Write/Edit. Job: if the session is sitting on trunk and is
# about to edit, move it onto a fresh feature branch so the task gains branch
# identity + cross-session continuity (the resolver pins a task base per branch).
#
# This must be cheap and safe on the hot path: the off-trunk fast-path is first,
# every git call is guarded, and the hook NEVER blocks the tool. It always allows
# the Write/Edit to proceed (exit 0, no deny/block decision) and NEVER exits 2.
# No `set -e`.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Read hook JSON from stdin (has session_id etc.). We need session_id to pin the
# task tree baseline from THIS session's clean pre-edit snapshot (see below); we
# do not need tool_input.
HOOK_INPUT=$(cat 2>/dev/null)
SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
fi

# --- fast no-op guards (allow, exit 0) --------------------------------------
# Not a git repo → nothing to branch.
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Detached HEAD → no branch identity to preserve; leave it alone.
if ! git -C "$PROJECT_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
  exit 0
fi

# Rebase / merge in progress → never touch the branch mid-operation.
GIT_DIR=$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null)
if [ -n "$GIT_DIR" ]; then
  case "$GIT_DIR" in
    /*) : ;;                       # already absolute
    *)  GIT_DIR="$PROJECT_DIR/$GIT_DIR" ;;
  esac
  if [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -d "$GIT_DIR/rebase-merge" ]; then
    exit 0
  fi
fi

# --- resolve identity -------------------------------------------------------
# Source the shared resolver and resolve. HC_MODE=task means branch != trunk,
# i.e. we are ALREADY on a feature branch → cheap off-trunk fast path, no-op.
if [ -f "$(dirname "$0")/harness-common.sh" ]; then
  . "$(dirname "$0")/harness-common.sh" 2>/dev/null
fi
if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "" 2>/dev/null
fi

# Already on a feature branch (task mode) → nothing to do.
if [ "$HC_MODE" = "task" ]; then
  exit 0
fi

# Only auto-branch when we are CONFIDENTLY on trunk (branch == trunk). An
# unconfident-trunk session (no main/master, no config trunk) is session mode
# too but NOT on trunk — must not spuriously branch there.
if [ -z "$HC_BRANCH" ] || [ -z "$HC_TRUNK" ] || [ "$HC_BRANCH" != "$HC_TRUNK" ]; then
  exit 0
fi

# --- config: auto_branch (default true; honor a literal false) --------------
# A bare `// true` jq default is WRONG: jq's `//` treats a literal `false` as
# empty and would flip it back to true. Probe with has() first, then read.
AUTO_BRANCH="true"
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
  if jq -e 'has("auto_branch")' "$CONFIG_FILE" >/dev/null 2>&1; then
    AUTO_BRANCH=$(jq -r '.auto_branch' "$CONFIG_FILE" 2>/dev/null)
  fi
fi

# auto_branch:false → stay on trunk (the "just warn at SessionStart" path); allow.
if [ "$AUTO_BRANCH" = "false" ]; then
  exit 0
fi

# --- create the feature branch ----------------------------------------------
# branch_prefix default task/. checkout -b carries any uncommitted WIP onto the
# new branch (git's default behaviour).
PREFIX="task/"
if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
  P=$(jq -r '.branch_prefix // empty' "$CONFIG_FILE" 2>/dev/null)
  if [ -n "$P" ] && [ "$P" != "null" ]; then
    PREFIX="$P"
  fi
fi

BRANCH="${PREFIX}$(date +%Y%m%d-%H%M%S)"

emit_msg() {
  # Non-blocking systemMessage on stdout (guarded); never fail.
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "$1" '{"systemMessage":$m}' 2>/dev/null
  else
    printf '{"systemMessage":"%s"}\n' "$1"
  fi
}

if git -C "$PROJECT_DIR" checkout -b "$BRANCH" >/dev/null 2>&1; then
  # --- pin the task tree baseline from THIS session's clean snapshot ----------
  # We just moved trunk→feature MID-session, so SessionStart already ran (in
  # session mode) and will NOT re-fire. If we left the task tree-base unpinned,
  # the NEXT session's first task-mode SessionStart would seed it from live
  # porcelain — which by then includes this session's own uncommitted work —
  # whitelisting it and violating Invariant 2 (the carryover bug's second path).
  #
  # Fix: pin tree-base/br-<branch>.dirty NOW, from the CLEAN pre-edit snapshot
  # this session's SessionStart recorded at baselines/<session_id>.dirty. This
  # is a PreToolUse hook firing BEFORE the triggering edit, so the tree is still
  # at that clean baseline. Copying the SessionStart snapshot is strictly better
  # than re-snapshotting live: it also blocks anything created via bash between
  # SessionStart and this first edit. Everything guarded; never fail the hook.
  if [ -n "$SESSION_ID" ] && (command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1); then
    hc_resolve "$SESSION_ID" 2>/dev/null
    if [ "$HC_MODE" = "task" ] && [ -n "$HC_TREE_BASE_FILE" ] && [ ! -f "$HC_TREE_BASE_FILE" ]; then
      mkdir -p "$(dirname "$HC_TREE_BASE_FILE")" 2>/dev/null
      SESSION_DIRTY="$HARNESS_DIR/baselines/${SESSION_ID}.dirty"
      if [ -f "$SESSION_DIRTY" ]; then
        cp "$SESSION_DIRTY" "$HC_TREE_BASE_FILE" 2>/dev/null
      else
        # No pre-edit SessionStart snapshot exists, so we have NO trustworthy
        # "pre-existing" set. Live porcelain is NOT trustworthy here (it may
        # already include this session's own WIP). Pin an EMPTY baseline →
        # everything classifies as introduced → blocks (safe direction).
        : > "$HC_TREE_BASE_FILE" 2>/dev/null
      fi
    fi
  fi
  emit_msg "completion harness: created \`$BRANCH\` off \`$HC_TRUNK\` for task continuity — to resume an existing task, checkout its branch first."
else
  emit_msg "completion harness: could not auto-create a task branch off \`$HC_TRUNK\` — staying on trunk (session fallback)."
fi

# Always allow the Write/Edit to proceed.
exit 0
