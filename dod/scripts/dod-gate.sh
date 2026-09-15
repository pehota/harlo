#!/bin/bash
#
# task-DoD plugin — the Stop blocker.
#
# Block contract: on BLOCK print
#   {"decision":"block","reason":"..."}
# to stdout and exit 0. On allow: exit 0, EMPTY stdout. Never exit 2.
#
# FAIL-SAFE = ALLOW. Any unexpected condition releases the Stop — we never trap
# the user.
#
# LATCH-DRIVEN. The gate is SILENT until the agent claims it is finished by
# running dod-complete-task.sh, which arms task-dod/claim-<task_key>. Without
# that latch this hook does nothing at all — that is what stops it blocking at
# the end of every turn while work is legitimately still in progress.
#
# THE ASYMMETRY RULE. An agent-authored signal may only make this gate
# STRICTER, never looser. Arming the latch clears nothing; skipping it buys
# nothing. Exactly two things disarm the latch: THIS hook, when verification
# genuinely covers the changeset, and dod-user-turn.sh (UserPromptSubmit) —
# the user taking the turn back, a USER-authored signal.
#
# COVERED = a verification result exists for HEAD **AND** the working tree
# carries no product-surface dirt. Both halves are required: verified-at-HEAD
# alone would let uncommitted work through. This hook therefore DOES inspect
# the changeset (via lib-classify.sh) — but only on the latched path, and only
# ever to block harder, never to release. If the classifier is unavailable the
# tree check is SKIPPED, not failed: an unknown releases.
#
# Only the ORCHESTRATOR runs dod. Stop does not fire for subagents and
# UserPromptSubmit only fires on real user turns, so no SubagentStop hook and
# no PostToolUse hook is registered by this plugin — that falls out for free.
#
# No `set -e`, no catch-all EXIT trap; every git/jq call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi
# shellcheck source=lib-classify.sh
if [ -f "$PLUGIN_ROOT/scripts/lib-classify.sh" ]; then
  . "$PLUGIN_ROOT/scripts/lib-classify.sh" 2>/dev/null
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
# the "no-verification" -> "still no verification" transition across a turn
# where the agent wrote the DoD but hasn't verified yet. The brake fires only
# when THIS turn's block category equals the previous turn's — an unchanged
# demand the agent has already been told. The category is written by block()
# into last-block/<key> and consulted there.
LAST_BLOCK_FILE=""   # set once HARNESS_DIR is known (below)

# --- non-git / detached HEAD / mid-rebase -> allow, silent ----------
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
# detached HEAD is treated alongside non-git as a no-op case.
if ! git -C "$PROJECT_DIR" symbolic-ref -q HEAD >/dev/null 2>&1; then
  exit 0
fi

# --- resolve identity ------------------------------------------------------
if hc_has_fn hc_resolve; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ -n "$HARNESS_DIR" ] || HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

# HC_TASK_KEY is UNSANITISED in session mode ("session-<session_id>", and the
# session id arrives from hook stdin), so it is sanitised HERE, before it
# becomes a path component. Task mode already sanitises the branch inside
# hc_resolve; sanitising twice is idempotent. Every path below — and every
# writer that must agree with this gate — uses the sanitised form.
if hc_has_fn hc__sanitize; then
  TASK_KEY=$(hc__sanitize "$HC_TASK_KEY")
else
  TASK_KEY=$(printf '%s' "$HC_TASK_KEY" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null)
fi
[ -n "$TASK_KEY" ] || exit 0

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${TASK_KEY}.json"
ARCHIVE_DIR="$DOD_DIR/archive"
VERIFIED_DIR="$DOD_DIR/verified"
VERIFIED_RESULT="$VERIFIED_DIR/${TASK_KEY}-${HEAD_SHA}.json"
LATCH="$DOD_DIR/claim-${TASK_KEY}"
LAST_BLOCK_FILE="$HARNESS_DIR/last-block/dod-${TASK_KEY}"

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
  printf 'task-dod: %s\n' "$reason" >&2
  exit 0
}

# Call before every non-block exit 0 so a stale category can't brake a later,
# different block.
clear_last_block() { rm -f "$LAST_BLOCK_FILE" 2>/dev/null; }

# --- 1. no latch -> the agent has not claimed -> SILENT ----------------------
# This is the whole mechanism that stops the gate blocking at the end of every
# turn while work is legitimately in progress. Not claiming buys nothing: the
# agent is simply still un-verified, and the reminder on the next user turn
# (dod-user-turn.sh) says so.
if [ ! -f "$LATCH" ]; then
  clear_last_block
  exit 0
fi

# --- 2. latched: is there a contract to verify against at all? ---------------
# A claim with neither a recorded DoD nor a verification result means the agent
# declared done without ever agreeing what done means. Point it at collection.
if [ ! -f "$DOD_FILE" ] && [ ! -f "$VERIFIED_RESULT" ]; then
  block "dod-no-contract" "task completion was claimed but no Definition of Done was ever recorded for this task — record it with the dod-collect skill, then verify with the dod-verify skill, then stop again."
fi

# --- 3. no verification result for this HEAD --------------------------------
if [ ! -f "$VERIFIED_RESULT" ]; then
  block "dod-no-verify" "task completion was claimed but no verification result exists for this changeset — run the dod-verify skill, then stop again."
fi

# --- 4. malformed result ----------------------------------------------------
FAIL_COUNT=$(jq '[.results[]? | select(.status == "fail")] | length' "$VERIFIED_RESULT" 2>/dev/null)
case "$FAIL_COUNT" in
  ''|*[!0-9]*)
    block "dod-no-verify" "the verification result for this changeset is malformed or unreadable — re-run the dod-verify skill, then stop again."
    ;;
esac

# --- 5. failing requirements ------------------------------------------------
if [ "$FAIL_COUNT" -gt 0 ]; then
  block "dod-verify-failed" "the verification result for this changeset has ${FAIL_COUNT} failing requirement(s) — fix them, re-run the dod-verify skill, then stop again."
fi

# --- 6. verified at HEAD, but is the tree still dirty on product surface? ----
# Verified-at-HEAD alone is NOT coverage: uncommitted product changes are, by
# construction, changes the verification at HEAD could not have seen. Guarded
# by hc_has_fn — if the classifier did not load, SKIP the check (fail-safe
# allow) rather than blocking on an unknown.
if hc_has_fn dod_tree_has_product && dod_tree_has_product "$SESSION_ID" 2>/dev/null; then
  block "dod-uncommitted" "verification passed at HEAD but the working tree still carries product changes that verification did not cover — commit them and re-run the dod-verify skill, then stop again."
fi

# --- 7. covered -> disarm, archive, allow -----------------------------------
# Disarm the latch: the claim has been honoured, and leaving it armed would
# re-block the very next Stop. Then move the live DoD into the archive keyed by
# HEAD_SHA, so a later product mutation past this SHA finds no live DoD
# (dod-collect must run again).
rm -f "$LATCH" 2>/dev/null
mkdir -p "$ARCHIVE_DIR" 2>/dev/null
if [ -f "$DOD_FILE" ]; then
  mv -f "$DOD_FILE" "$ARCHIVE_DIR/${HEAD_SHA}.json" 2>/dev/null
fi
clear_last_block

exit 0
