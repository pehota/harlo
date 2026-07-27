#!/bin/bash
#
# Completion Harness — Stop hook (the gate).
#
# Fires on every main-agent turn exit. Blocks the stop unless a valid done-state
# exists for this session and matches the live git state.
#
# Contract (matches the repo block pattern): on BLOCK, print a JSON object
#   {"decision":"block","reason":"..."}
# to stdout AND exit 0. On exit 0 the runtime parses the stdout JSON and honours
# the block decision; the reason is delivered to the agent from that JSON. (Exit
# 2 is deliberately NOT used: on exit 2 the runtime reads STDERR and ignores the
# stdout JSON, discarding the structured reason.) A short human-log line is also
# written to stderr for hook logs, but the decisive output is the stdout JSON.
#
# Fail-safe: any unexpected condition -> allow the stop (exit 0 with no decision
# JSON). We never trap the user. EXCEPTION: Step 8 (recorded-outcome check)
# deliberately INVERTS this — a missing/malformed/red outcome there fails toward
# BLOCK (see the Step 8 comment). There is deliberately NO `set -e` and NO
# catch-all EXIT trap: a stray mid-script failure must not abort before the block
# JSON is emitted, nor produce a spurious nonzero exit. Every jq/git call is
# guarded explicitly. An allow is exit 0 with empty stdout; a block is exit 0
# with the decision JSON on stdout — the two are distinguished by stdout, not by
# exit code.

# --- project root -----------------------------------------------------------
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- read hook JSON from stdin ----------------------------------------------
HOOK_INPUT=$(cat 2>/dev/null)

# jq missing -> cannot reason about state -> fail safe.
command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
STOP_HOOK_ACTIVE=$(printf '%s' "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)

# Fallback session id so the gate path matches baseline-snapshot.sh exactly
# when session_id is absent (both fall back to "unknown-session").
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"

# --- resolve identity (task_key, base) via the shared resolver --------------
# Sourced library: sets HC_MODE HC_TASK_KEY HC_BASE (+ PROJECT_DIR HARNESS_DIR).
# Done-state is keyed by HC_TASK_KEY (task-branch continuity across sessions),
# not the raw session id. Guarded: if it cannot be sourced we fall back to a
# session-scoped key so the gate never crashes.
if [ -f "$(dirname "$0")/harness-common.sh" ]; then
  . "$(dirname "$0")/harness-common.sh" 2>/dev/null
fi
if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ -z "$HC_TASK_KEY" ] && HC_TASK_KEY="session-${SESSION_ID}"

# --- helper: emit block + exit 0 --------------------------------------------
block() {
  local reason="$1"
  # stdout: the machine-readable decision the runtime consumes on exit 0.
  jq -n --arg r "$reason" '{"decision":"block","reason":$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s"}\n' "$reason"
  # stderr: human-readable log line only; not parsed by the runtime on exit 0.
  printf 'Completion harness: %s\n' "$reason" >&2
  exit 0
}

# --- Step 1: loop guard -----------------------------------------------------
# A block must never trap the agent forever.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Step 2: not a git repo -> no changeset baseline possible ---------------
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  exit 0
fi

# --- paths (task-mandated locations under .harness) -------------------------
# Done-state is keyed by HC_TASK_KEY (task mode: br-<branch>; session mode:
# session-<id>) so a task's done-state is shared across resuming sessions.
HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
DONE_STATE_FILE="$HARNESS_DIR/done-state/$HC_TASK_KEY.json"

# --- Step 3: no commits on this changeset (HEAD == base) AND clean tree ------
# Quiet exit ONLY when nothing was committed since the base AND the working tree
# is clean. HC_BASE is the resolver's anchor: in task mode it is the pinned fork
# base (HEAD==base => no commits yet on the branch); in session mode it is the
# SessionStart baseline (HEAD==baseline => no session commits). If HC_BASE is
# empty (no anchor) we skip the quiet-exit and fall through. If HEAD == base but
# the tree is DIRTY, we do NOT exit here: an uncommitted "done" must still be
# gated, so we fall through to the remaining steps (Step 4 -> block).
if [ -n "$HC_BASE" ] && [ "$HC_BASE" = "$HEAD_SHA" ]; then
  STEP3_TREE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
  if [ -z "$STEP3_TREE_STATUS" ]; then
    exit 0
  fi
fi

# --- Step 4: missing done-state -> BLOCK ------------------------------------
if [ ! -f "$DONE_STATE_FILE" ]; then
  block "/done has not passed for the current changeset (HEAD: ${HEAD_SHA:0:7}). Run /done to verify tests, app start, code review, and task-specific checks before declaring done."
fi

# --- Step 5: verified_sha != HEAD -> BLOCK ----------------------------------
# Re-check live, do not trust any stored convenience flag. This is enforced
# BEFORE any escalation is honoured, so a stale escalation cannot disarm the
# gate once HEAD has moved past the changeset it was recorded against.
VERIFIED_SHA=$(jq -r '.verified_sha // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$VERIFIED_SHA" != "$HEAD_SHA" ]; then
  block "changes committed since last /done (HEAD: ${HEAD_SHA:0:7}) — re-run /done to re-verify the current changeset."
fi

# --- Step 6: working tree dirty -> BLOCK ------------------------------------
# Re-check tree cleanliness live at gate time. Also enforced before escalation.
TREE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
if [ -n "$TREE_STATUS" ]; then
  block "uncommitted changes in the working tree — commit or stash them, then re-run /done."
fi

# --- Step 7: valid escalation present -> exit 0 -----------------------------
# "Valid" = escalation field present and non-null. Escalation is honoured LAST,
# after the SHA and tree checks above. Consequence: an escalation only disarms
# the exact committed changeset it was recorded against (verified_sha == HEAD,
# clean tree). Any new commit moves HEAD, Step 5 blocks first, and /done must
# be re-run — a stale escalation can no longer disarm the gate for the session.
ESCALATION=$(jq -r '.escalation // "null"' "$DONE_STATE_FILE" 2>/dev/null)
if [ -n "$ESCALATION" ] && [ "$ESCALATION" != "null" ]; then
  exit 0
fi

# --- Step 8: recorded checklist outcomes must all be green -> else BLOCK -----
# With no escalation (step 7 already returned if one was present), the gate
# enforces the CHECKLIST OUTCOMES, not just commit hygiene: a done-state that
# records red tests / red lint / a failed task_check, or a HEAD with no
# independent review-log (or one with open findings), must NOT pass.
#
# Fail direction is deliberately INVERTED from the script's global fail-safe:
# here a MISSING/null/malformed outcome (or a jq crash) is treated as NOT green
# -> BLOCK. A complete done-state written by done-write-state.sh always carries
# these fields and parses fine, so a valid green state passes; anything else is
# blocked in the safe direction. All comparisons are STRING comparisons against
# a sentinel default so an empty jq result fails toward BLOCK (never toward an
# accidental allow via a broken numeric test).

# tests.exit_code must be exactly "0". Absent -> "MISSING" -> block.
TESTS_EXIT=$(jq -r '.tests.exit_code // "MISSING"' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TESTS_EXIT" != "0" ]; then
  block "recorded tests are not green (exit_code=${TESTS_EXIT}) — fix and re-run /done, or escalate."
fi

# lint (conditional). Only projects with a lint command record a .lint object.
# If .lint is PRESENT its exit_code must be exactly "0"; if it is absent/null
# (no lint configured) skip — write-state enforces lint-when-configured, so a
# missing .lint here is not a failure. A present-but-nonzero (or a jq crash
# yielding "") fails toward BLOCK via the string compare.
LINT_EXIT=$(jq -r '.lint.exit_code // "MISSING"' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$LINT_EXIT" != "MISSING" ] && [ "$LINT_EXIT" != "0" ]; then
  block "recorded lint is not green (exit_code=${LINT_EXIT}) — fix and re-run /done, or escalate."
fi

# review: an INDEPENDENT review-log must exist for the current HEAD, written by
# the Step-4 review subagent (not a self-reported count in done-state). Its
# open_findings must be exactly "0". A missing log, or open_findings absent
# ("MISSING") / nonzero / a jq crash (""), all fail toward BLOCK via the string
# compare against a sentinel — same discipline as the tests.exit_code check.
REVIEW_LOG="$HARNESS_DIR/review-log/$HEAD_SHA.json"
if [ ! -f "$REVIEW_LOG" ]; then
  block "no independent code review recorded for HEAD ${HEAD_SHA:0:7} — run /done."
fi
OPEN=$(jq -r '.open_findings // "MISSING"' "$REVIEW_LOG" 2>/dev/null)
if [ "$OPEN" != "0" ]; then
  block "${OPEN} unresolved review findings — address them and re-run /done, or escalate."
fi

# task_checks: every entry must be status "passed". Count the non-passed ones;
# an absent task_checks array yields length 0 (vacuously green). A jq crash
# yields "" which is != "0" -> block.
TASK_FAILED=$(jq -r '[.task_checks[]? | select(.status != "passed")] | length' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TASK_FAILED" != "0" ]; then
  block "recorded task_checks are not all passed (${TASK_FAILED} not passed) — fix and re-run /done, or escalate."
fi

# --- Step 9: all checks pass -> allow the stop ------------------------------
exit 0
