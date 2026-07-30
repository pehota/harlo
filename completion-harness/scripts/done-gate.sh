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

# --- Step 2b: pending-escalation one-shot pass (P1-b, #6) -------------------
# When /done needs to AskUserQuestion for a Category-C / user_halt escalation, it
# writes pending-escalation/<task_key>.json FIRST. The AskUserQuestion turn ends
# with a Stop the gate would otherwise BLOCK (no green done-state yet) — trapping
# the very question meant for the user. So: if a pending file exists, consume it
# (rm) and allow EXACTLY ONCE, letting that turn reach the user. The next Stop
# finds no pending file and re-gates normally. One file → one allow; it cannot
# indefinitely disarm the gate. Placed after the loop-guard + git checks but
# BEFORE the tree/done-state checks. Reaping is covered by the default age-reap
# (no exclusion needed). Guarded; a missing dir is a no-op.
PENDING="$HARNESS_DIR/pending-escalation/$HC_TASK_KEY.json"
if [ -f "$PENDING" ]; then
  rm -f "$PENDING" 2>/dev/null
  exit 0
fi

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

# --- Step 3b: working tree has INTRODUCED changes -> BLOCK ------------------
# Re-check the tree live at gate time via the shared baseline-relative
# classifier (hc_tree_status). Only changes INTRODUCED this session (not present
# at the SessionStart baseline) block; pre-existing entries are ignored, not
# blocked (and never surfaced) — this is what breaks the pre-existing-untracked deadlock without
# weakening the gate (the changeset's own uncommitted work still blocks). Runs
# BEFORE the done-state checks (Steps 4/4b/5) so an introduced-dirty tree blocks
# with the S1 ("finish the slice") reason — aligned with hc_state, which
# evaluates the introduced-dirty guard FIRST. A clean tree makes this a no-op and
# the done-state checks below proceed exactly as before. Also enforced before
# escalation (Step 7).
if command -v hc_tree_status >/dev/null 2>&1 || type hc_tree_status >/dev/null 2>&1; then
  hc_tree_status "$SESSION_ID" 2>/dev/null
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    block "finish the slice ($(hc_tree_remediation)), then commit"
  fi
else
  # Classifier unavailable (source failed): fall back to the strict live check
  # so the gate never weakens toward allow.
  TREE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
  if [ -n "$TREE_STATUS" ]; then
    block "finish the slice (commit or stash your uncommitted changes), then commit"
  fi
fi

# --- Step 3c: empty changeset -> allow (P0-b, #6) ---------------------------
# Reaching here means Step 3b found NO introduced tree blockers. If the
# commit-range base..HEAD is ALSO empty (no committed work to gate), there is
# nothing to verify → allow. This handles the case where base-advance (Step-A)
# advanced HC_BASE past foreign commits up to a point where HEAD == the advanced
# base only in content (identical trees), and, more importantly, where the
# resolved changeset diff is genuinely empty.
#
# Fail-safe: `git diff --quiet` exits 0 ONLY on a genuinely empty diff; ANY git
# failure exits non-zero → we do NOT short-circuit → fall through to the gate.
# An empty HC_BASE skips the guard entirely (no anchor → cannot judge emptiness).
# Introduced dirt has already blocked above (Step 3b precedes this), so an empty
# range with pre-existing-only dirt correctly reaches here and is allowed.
if [ -n "$HC_BASE" ] && git -C "$PROJECT_DIR" diff --quiet "$HC_BASE" "$HEAD_SHA" 2>/dev/null; then
  exit 0
fi

# --- changeset-missing block reason (P1-a, #6): prepend a content-ful summary -
# The S2 "/done" reason below (Steps 4/4b/5) is a bare instruction. Prepend a
# one-shot changeset summary so the message says WHAT is being gated — file/commit
# counts and how many commits were authored THIS session (HC_BASE_ORIG, the
# unadvanced base, so it can honestly read "0 authored this session" when every
# commit is foreign). Guarded: if the helper is unavailable, S2_REASON degrades to
# the bare string. HC_SESSION_ID lets hc_changeset_summary find the baseline mtime
# for its session-authorship tally.
S2_REASON="run /done to verify the changeset (owns the Step-5 review)"
if command -v hc_changeset_summary >/dev/null 2>&1 || type hc_changeset_summary >/dev/null 2>&1; then
  HC_SESSION_ID="$SESSION_ID"
  CS_SUMMARY=$(hc_changeset_summary "${HC_BASE_ORIG:-$HC_BASE}" "$HEAD_SHA" "$PROJECT_DIR" 2>/dev/null)
  [ -n "$CS_SUMMARY" ] && S2_REASON="$CS_SUMMARY
$S2_REASON"
fi

# --- Step 4: missing done-state -> BLOCK ------------------------------------
if [ ! -f "$DONE_STATE_FILE" ]; then
  block "$S2_REASON"
fi

# --- Step 4b: done-state must satisfy the hard contract (schema) -> BLOCK ----
# The done-state exists; before trusting any of its fields (verified_sha, the
# outcome checks in Step 8, ...) it must be structurally valid. A missing schema
# file itself → hc_validate nonzero → BLOCK (broken install, safe direction). The
# jq-missing degrade at the top of the gate already exited before this point, so
# this never fires on a jq-less host.
if command -v hc_validate >/dev/null 2>&1 || type hc_validate >/dev/null 2>&1; then
  if ! hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$DONE_STATE_FILE" >/dev/null 2>&1; then
    block "$S2_REASON"
  fi
else
  block "$S2_REASON"
fi

# --- Step 5: verified_sha != HEAD -> BLOCK ----------------------------------
# Re-check live, do not trust any stored convenience flag. This is enforced
# BEFORE any escalation is honoured, so a stale escalation cannot disarm the
# gate once HEAD has moved past the changeset it was recorded against.
VERIFIED_SHA=$(jq -r '.verified_sha // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$VERIFIED_SHA" != "$HEAD_SHA" ]; then
  block "$S2_REASON"
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

# tests must be GREEN with EVIDENCE (P1-c, #6). Escalation already short-circuited
# at Step 7, so a tests.status=="not_run" here is an unverified green claim ->
# block. A green result carries exit_code==0 AND non-empty command AND non-empty
# output_tail (un-forgeable green); a missing field -> "MISSING"/"" -> block.
TESTS_STATUS=$(jq -r '.tests.status // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TESTS_STATUS" = "not_run" ]; then
  block "tests were not run and there is no escalation — run tests, re-commit, re-run /done"
fi
TESTS_EXIT=$(jq -r '.tests.exit_code // "MISSING"' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TESTS_EXIT" != "0" ]; then
  block "fix failing tests, re-commit, re-run /done"
fi
TESTS_CMD=$(jq -r '.tests.command // ""' "$DONE_STATE_FILE" 2>/dev/null)
TESTS_TAIL=$(jq -r '.tests.output_tail // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ -z "$TESTS_CMD" ] || [ -z "$TESTS_TAIL" ]; then
  block "green tests must carry evidence (command + output_tail); re-run /done recording them"
fi

# lint (conditional). Only projects with a lint command record a .lint object.
# If .lint is PRESENT its exit_code must be exactly "0"; if it is absent/null
# (no lint configured) skip — write-state enforces lint-when-configured, so a
# missing .lint here is not a failure. A present-but-nonzero (or a jq crash
# yielding "") fails toward BLOCK via the string compare.
LINT_EXIT=$(jq -r '.lint.exit_code // "MISSING"' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$LINT_EXIT" != "MISSING" ] && [ "$LINT_EXIT" != "0" ]; then
  block "fix lint, re-commit, re-run /done"
fi

# review: an INDEPENDENT review-log must exist for the current HEAD, written by
# the Step-4 review subagent (not a self-reported count in done-state). The
# BLOCKING count is computed STRUCTURALLY by hc_review_blocking from the log's
# findings[].severity and the configured min_review_level (default "high") — the
# reviewer cannot dodge the gate by miscounting open_findings. Findings BELOW the
# threshold are advisory and never block. A missing log, or a jq crash / unknown
# severity ("ERR"), all fail toward BLOCK — same fail-toward-block discipline as
# the tests.exit_code check.
REVIEW_LOG="$HARNESS_DIR/review-log/$HEAD_SHA.json"
if [ ! -f "$REVIEW_LOG" ]; then
  block "run an independent code review, then re-run /done"
fi
# Hard contract: the review-log must be structurally valid before its
# findings[]/files_reviewed are trusted by the severity + coverage checks below.
# A missing schema file → hc_validate nonzero → BLOCK (broken install, safe).
if command -v hc_validate >/dev/null 2>&1 || type hc_validate >/dev/null 2>&1; then
  if ! hc_validate "$HC_CONTRACTS_DIR/review-log.schema.json" "$REVIEW_LOG" >/dev/null 2>&1; then
    block "$S2_REASON"
  fi
else
  block "$S2_REASON"
fi
MIN_LEVEL=$(jq -r '.min_review_level // "high"' "$PROJECT_DIR/.claude/done-config.json" 2>/dev/null)
[ -z "$MIN_LEVEL" ] && MIN_LEVEL="high"
# Explicit availability guard (parity with the hc_tree_status fallback): if the
# library failed to source, force ERR so we fail toward BLOCK, never toward allow.
if command -v hc_review_blocking >/dev/null 2>&1 || type hc_review_blocking >/dev/null 2>&1; then
  OPEN=$(hc_review_blocking "$REVIEW_LOG" "$MIN_LEVEL")
else
  OPEN="ERR"
fi
if [ "$OPEN" != "0" ]; then
  block "address the blocking review findings (${OPEN}), then re-run /done"
fi

# review COVERAGE: the review-log must attest (in .files_reviewed) EVERY file the
# changeset touched (git diff --name-only HC_BASE..HEAD). This turns "the review
# covered the whole changeset" into a STRUCTURAL check, not prose hope —
# recomputed by the same shared function the writer uses (hc_review_coverage_gap)
# so the two can never diverge. A non-empty gap (files changed but not attested)
# BLOCKS; SKIP (no changeset base → coverage not computable) passes — a
# no-regression degrade, there was no coverage check before. hc_review_blocking's
# availability guard above already forces a block if the library failed to source,
# so a missing function here cannot silently allow. A coverage-computation error
# with a real changeset returns the full changed set (non-empty → block), never
# SKIP — so it fails toward block, not toward an accidental allow.
GAP=$(hc_review_coverage_gap "$REVIEW_LOG" "$HC_BASE" "$HEAD_SHA" "$PROJECT_DIR")
if [ -n "$GAP" ] && [ "$GAP" != "SKIP" ]; then
  GAP_LIST=$(printf '%s' "$GAP" | tr '\n' ' ')
  block "review the uncovered files (${GAP_LIST}), then re-run /done"
fi

# task_checks: every entry must be status "passed". Count the non-passed ones;
# an absent task_checks array yields length 0 (vacuously green). A jq crash
# yields "" which is != "0" -> block.
TASK_FAILED=$(jq -r '[.task_checks[]? | select(.status != "passed")] | length' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TASK_FAILED" != "0" ]; then
  block "fix ${TASK_FAILED} task check(s) not passed, then re-run /done"
fi

# --- Step 9: all checks pass -> allow the stop ------------------------------
exit 0
