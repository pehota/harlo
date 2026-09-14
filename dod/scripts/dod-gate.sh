#!/bin/bash
#
# task-DoD plugin — the Stop blocker.
#
# Block contract: on BLOCK print
#   {"decision":"block","reason":"..."}
# to stdout and exit 0. On allow: exit 0, EMPTY stdout. Never exit 2.
#
# FAIL-SAFE = ALLOW. Any unexpected condition releases the Stop — we never trap
# the user. The ONE exception, which is the entire point of this plugin: a
# COLLECTED task DoD with no matching verification result BLOCKS.
#
# Purely structural: this hook does NOT decide whether a task needed a DoD —
# that call was moved to the dod-collect skill (agent-invoked, not a hook).
# If no task-dod/<task_key>.json exists, there is nothing to verify and this
# hook is silent. It never inspects the changeset or classifies paths.
#
# No `set -e`, no catch-all EXIT trap; every git/jq call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
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

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${HC_TASK_KEY}.json"
ARCHIVE_DIR="$DOD_DIR/archive"
VERIFIED_DIR="$DOD_DIR/verified"
VERIFIED_RESULT="$VERIFIED_DIR/${HC_TASK_KEY}-${HEAD_SHA}.json"
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
  printf 'task-dod: %s\n' "$reason" >&2
  exit 0
}

# Call before every non-block exit 0 so a stale category can't brake a later,
# different block.
clear_last_block() { rm -f "$LAST_BLOCK_FILE" 2>/dev/null; }

# --- no collected DoD -> nothing to verify -> allow, silent ------------------
# Collection is agent-invoked (dod-collect skill), not hook-driven, so the
# mere absence of a task-dod file is never itself a block condition here.
if [ ! -f "$DOD_FILE" ]; then
  clear_last_block
  exit 0
fi

# --- DoD present: does a passing verification result exist for HEAD? --------
if [ ! -f "$VERIFIED_RESULT" ]; then
  block "dod-no-verify" "task DoD present but /done has not run for this changeset — run the /done checklist (scripts/dod-stub-done.sh), then stop again."
fi

FAIL_COUNT=$(jq '[.results[]? | select(.status == "fail")] | length' "$VERIFIED_RESULT" 2>/dev/null)
case "$FAIL_COUNT" in
  ''|*[!0-9]*)
    block "dod-no-verify" "verification result for this changeset is malformed or unreadable — re-run the /done checklist (scripts/dod-stub-done.sh), then stop again."
    ;;
esac
if [ "$FAIL_COUNT" -gt 0 ]; then
  block "dod-verify-failed" "verification result for this changeset has ${FAIL_COUNT} failing requirement(s) — fix them, re-run the /done checklist, then stop again."
fi

# --- DoD present AND a passing verification result for HEAD -> allow + archive
# Move the live DoD into the archive keyed by HEAD_SHA. A later product
# mutation past this SHA then finds no live DoD (dod-collect must run again).
mkdir -p "$ARCHIVE_DIR" 2>/dev/null
mv -f "$DOD_FILE" "$ARCHIVE_DIR/${HEAD_SHA}.json" 2>/dev/null
clear_last_block

exit 0
