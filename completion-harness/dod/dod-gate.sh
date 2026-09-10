#!/bin/bash
#
# Completion Harness — task-DoD walking skeleton: the Stop blocker.
#
# Part of the dod/ skeleton (issue #11 / ADR-0001). Wired ONLY by dod/hooks.json
# for the headless trial's merged bundle — nothing in the live
# completion-harness/hooks.json invokes it. It runs ALONGSIDE the real
# done-gate.sh in that merged bundle; the two are independent Stop hooks.
#
# Block contract (identical to done-gate.sh): on BLOCK print
#   {"decision":"block","reason":"..."}
# to stdout and exit 0. On allow: exit 0, EMPTY stdout. Never exit 2.
#
# FAIL-SAFE = ALLOW. Any unexpected condition releases the Stop — we never trap
# the user. The ONE exception, which is the entire point of the skeleton: a
# product-surface changeset with NO task DoD BLOCKS.
#
# No `set -e`, no catch-all EXIT trap; every git/jq call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi
if [ -f "$PLUGIN_ROOT/dod/lib-classify.sh" ]; then
  . "$PLUGIN_ROOT/dod/lib-classify.sh" 2>/dev/null
fi

# No jq → cannot reason about state → fail safe (allow), matching done-gate.sh.
hc_has_jq || exit 0

# --- read hook stdin ------------------------------------------------------------
if hc_has_fn hc_read_hook_input; then
  hc_read_hook_input
  SESSION_ID="$HC_HOOK_SESSION_ID"
  STOP_HOOK_ACTIVE="$HC_HOOK_STOP_ACTIVE"
else
  HOOK_INPUT=$(cat 2>/dev/null)
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
  STOP_HOOK_ACTIVE=$(printf '%s' "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
fi
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"

# Recursion brake — CATEGORY-SCOPED, matching done-gate.sh's block() guard.
# A blanket `stop_hook_active => exit 0` here would swallow a REQUIRED block on
# the "no-DoD" -> "DoD present, /done not run" transition: the agent writes the
# DoD inside the block-response cycle, stops again with the flag still true, and
# a blanket brake would let it finish with /done never run. So the brake fires
# only when THIS turn's block category equals the previous turn's — an unchanged
# demand the agent has already been told. The category is written by block()
# into last-block/<key> and consulted there.
LAST_BLOCK_FILE=""   # set once HARNESS_DIR is known (below)

# --- case 12: non-git / detached HEAD / mid-rebase -> allow, silent ----------
GIT_DIR=$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null)
if [ -z "$GIT_DIR" ]; then
  exit 0
fi
case "$GIT_DIR" in /*) : ;; *) GIT_DIR="$PROJECT_DIR/$GIT_DIR" ;; esac
if [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -d "$GIT_DIR/rebase-merge" ]; then
  exit 0
fi
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse -q --verify HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  exit 0
fi
# Detached HEAD: symbolic-ref fails. hc_resolve then falls back to session mode;
# the issue lists detached HEAD alongside non-git as a no-op case.
if ! git -C "$PROJECT_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
  exit 0
fi

# --- resolve identity ------------------------------------------------------
if hc_has_fn hc_resolve; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ -n "$HARNESS_DIR" ] || HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${HC_TASK_KEY}.json"
ARCHIVE_DIR="$DOD_DIR/archive"
STUB_MARKER="$DOD_DIR/.stub-done-${HC_TASK_KEY}"
VERIFIED_MARKER="$DOD_DIR/.verified-${HC_TASK_KEY}"
LAST_BLOCK_FILE="$HARNESS_DIR/last-block/dod-${HC_TASK_KEY}"

# block <category> <reason>
# Emits the block JSON and exits 0 — UNLESS we are inside a stop-hook turn AND
# this category equals the one recorded last turn (the agent has already seen
# this exact demand): then release, to avoid trapping it on an unchanging block.
# A DIFFERENT category still blocks under stop_hook_active — that is a new demand.
block() {
  local category="$1" reason="$2" prev=""
  [ -f "$LAST_BLOCK_FILE" ] && prev=$(cat "$LAST_BLOCK_FILE" 2>/dev/null | tr -d '\r\n')
  if [ "$STOP_HOOK_ACTIVE" = "true" ] && [ "$category" = "$prev" ]; then
    exit 0
  fi
  mkdir -p "$(dirname "$LAST_BLOCK_FILE")" 2>/dev/null
  printf '%s\n' "$category" > "$LAST_BLOCK_FILE" 2>/dev/null
  jq -n --arg r "$reason" '{"decision":"block","reason":$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s"}\n' "$reason"
  printf 'Completion harness (dod skeleton): %s\n' "$reason" >&2
  exit 0
}

# Call before every non-block exit 0 so a stale category can't brake a later,
# different block.
clear_last_block() { rm -f "$LAST_BLOCK_FILE" 2>/dev/null; }

# --- is there product surface in the changeset? --------------------------------
if ! hc_has_fn dod_changeset_has_product; then
  # classifier lib unavailable → cannot make the missing-DoD call safely →
  # fail-safe allow (this is NOT the missing-DoD-on-product case; we cannot even
  # tell what surface changed).
  exit 0
fi

# --- case 10: past a prior verified boundary? --------------------------------
# .verified-<key> holds the verified_sha stamped when this task last passed.
# If HEAD is still that SHA and the tree carries no NEW product change, the task
# is still over → stay allowed. If HEAD advanced OR product-surface tree dirt
# appeared, this is a FRESH task: the live DoD was archived at the boundary, so
# dod_changeset_has_product below finds product + no DoD and blocks for a new one.
if [ -f "$VERIFIED_MARKER" ]; then
  PREV_SHA=$(cat "$VERIFIED_MARKER" 2>/dev/null | tr -d '\r\n')
  if [ "$PREV_SHA" = "$HEAD_SHA" ]; then
    if dod_changeset_has_product "$SESSION_ID"; then
      # HEAD unchanged but product tree dirt since the boundary → fresh task.
      : # fall through to the missing-DoD logic below
    else
      clear_last_block
      exit 0
    fi
  fi
  # HEAD advanced → fresh task; fall through.
fi

if ! dod_changeset_has_product "$SESSION_ID"; then
  # case 1: artifact-only or empty changeset → allow silently.
  clear_last_block
  exit 0
fi

# --- product surface changed -------------------------------------------------
# case 6: no task DoD → BLOCK (the whole point; fail toward block here).
if [ ! -f "$DOD_FILE" ]; then
  block "no-dod" "product surface changed but no task DoD exists — write .claude/.harness/task-dod/${HC_TASK_KEY}.json (requirements + blast_radius {tier, reason}) before finishing. See dod/base-dod.md and issue #11."
fi

# case 7: DoD present but the stub /done has not run → BLOCK.
if [ ! -f "$STUB_MARKER" ]; then
  block "dod-no-done" "task DoD present but /done has not run for this changeset — run the /done checklist (skeleton: dod/dod-stub-done.sh), then stop again."
fi

# --- DoD present AND stub-done present -> allow + stamp the boundary --------
# case 10 setup: record verified_sha, move the live DoD into the archive keyed
# by that SHA. A later product mutation past this SHA then finds no live DoD.
mkdir -p "$ARCHIVE_DIR" 2>/dev/null
printf '%s\n' "$HEAD_SHA" > "$VERIFIED_MARKER" 2>/dev/null
if [ -f "$DOD_FILE" ]; then
  mv -f "$DOD_FILE" "$ARCHIVE_DIR/${HEAD_SHA}.json" 2>/dev/null
fi
# The stub-done and nudge markers belong to the task that just closed — clear
# them so the next task starts clean.
rm -f "$STUB_MARKER" "$DOD_DIR/.nudged-${HC_TASK_KEY}" 2>/dev/null
clear_last_block

exit 0
