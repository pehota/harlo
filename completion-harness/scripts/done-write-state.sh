#!/bin/bash
#
# Completion Harness — /done Step 7: write done-state with live git facts.
#
# The LLM supplies only JUDGMENT fields as a JSON payload on stdin (dod,
# task_checks, escalation, tests summary, optional lint summary, app_started,
# ...). This script injects the git FACTS live — verified_sha = `git rev-parse
# HEAD`, tree_clean from `git status --porcelain` — so a SHA can never be
# hand-written, and it REFUSES to write over a dirty tree (a "done" state must
# not be recorded atop uncommitted changes). `review` is NOT a payload field —
# code-review evidence is the separate HEAD-keyed review-log artifact.
#
# Usage: done-write-state.sh [session_id] < payload.json
#   session_id: optional; else resolved from the most-recent baseline .sha.
#
# Fail-safe reads (guarded), but this script INTENTIONALLY exits nonzero on the
# real failure modes (bad payload, dirty tree, no git) — the caller must know it
# did not record a done-state.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to build done-state" >&2
  exit 1
fi

# --- read + validate the LLM payload ----------------------------------------
PAYLOAD=$(cat 2>/dev/null)
if [ -z "$PAYLOAD" ]; then
  echo "error: no JSON payload on stdin (supply dod/review/task_checks/tests/... )" >&2
  exit 1
fi
if ! printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1; then
  echo "error: stdin payload is not valid JSON" >&2
  exit 1
fi

# --- resolve session id ------------------------------------------------------
SESSION_ID="${1:-}"
BASELINE_DIR="$PROJECT_DIR/.claude/.harness/baselines"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -t "$BASELINE_DIR"/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//')
fi
if [ -z "$SESSION_ID" ]; then
  echo "error: could not resolve session id (no arg and no baseline .sha found)" >&2
  exit 1
fi

# --- inject live git facts ---------------------------------------------------
VERIFIED_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$VERIFIED_SHA" ]; then
  echo "error: not a git repo (git rev-parse HEAD failed) — cannot record done-state" >&2
  exit 1
fi

GIT_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
if [ -n "$GIT_STATUS" ]; then
  echo "error: working tree dirty — commit before recording done-state" >&2
  exit 1
fi
TREE_CLEAN=true

# --- mirror the gate's step 8: refuse a non-green payload ---------------------
# Give the agent the feedback at /done time rather than at stop time. If an
# escalation IS present, allow the write (the escape hatch — the gate honours it
# too). With NO escalation, refuse to write unless the recorded outcomes are all
# green: tests.exit_code == 0, lint green WHEN a lint command is configured, an
# independent review-log for HEAD with open_findings == 0, and every task_check
# passed. Same INVERTED fail direction as the gate: a missing/malformed outcome
# is treated as NOT green so it is refused, not silently written.
HAS_ESCALATION=$(printf '%s' "$PAYLOAD" | jq -r '
  if (.escalation != null) then "yes" else "no" end
' 2>/dev/null)
if [ "$HAS_ESCALATION" != "yes" ]; then
  P_TESTS_EXIT=$(printf '%s' "$PAYLOAD" | jq -r '.tests.exit_code // "MISSING"' 2>/dev/null)
  if [ "$P_TESTS_EXIT" != "0" ]; then
    echo "error: refusing to write — tests are not green (exit_code=${P_TESTS_EXIT}); fix and re-run, or supply an escalation" >&2
    exit 1
  fi

  # lint (conditional on configuration). The trigger is a CONFIGURED lint
  # command in done-config.json (effective = overrides.lint ?? detected.lint),
  # NOT the presence of .lint in the payload. If a lint command is configured,
  # the payload MUST record lint.exit_code == 0 (absent .lint -> "MISSING" ->
  # refuse). If no lint command is configured, ignore lint entirely.
  LINT_CMD=$(jq -r '.overrides.lint // .detected.lint // ""' "$PROJECT_DIR/.claude/done-config.json" 2>/dev/null)
  if [ -n "$LINT_CMD" ]; then
    P_LINT_EXIT=$(printf '%s' "$PAYLOAD" | jq -r '.lint.exit_code // "MISSING"' 2>/dev/null)
    if [ "$P_LINT_EXIT" != "0" ]; then
      echo "error: refusing to write — lint is configured but not green (exit_code=${P_LINT_EXIT}); fix and re-run, or supply an escalation" >&2
      exit 1
    fi
  fi

  # review-log: an independent review-log for the LIVE HEAD must exist with
  # open_findings == 0. Mirrors the gate so the agent gets the feedback at /done
  # time. HEAD is the live rev-parse computed above (VERIFIED_SHA). A missing
  # log, or open_findings absent/nonzero/jq-crash (""), all refuse via the
  # sentinel string compare.
  REVIEW_LOG="$PROJECT_DIR/.claude/.harness/review-log/${VERIFIED_SHA}.json"
  if [ ! -f "$REVIEW_LOG" ]; then
    echo "error: refusing to write — no independent review-log for HEAD ${VERIFIED_SHA:0:7} (.claude/.harness/review-log/${VERIFIED_SHA}.json); run the Step-4 review, or supply an escalation" >&2
    exit 1
  fi
  P_OPEN=$(jq -r '.open_findings // "MISSING"' "$REVIEW_LOG" 2>/dev/null)
  if [ "$P_OPEN" != "0" ]; then
    echo "error: refusing to write — ${P_OPEN} unresolved review findings for HEAD ${VERIFIED_SHA:0:7}; address them and re-run, or supply an escalation" >&2
    exit 1
  fi

  P_TASK_FAILED=$(printf '%s' "$PAYLOAD" | jq -r '[.task_checks[]? | select(.status != "passed")] | length' 2>/dev/null)
  if [ "$P_TASK_FAILED" != "0" ]; then
    echo "error: refusing to write — ${P_TASK_FAILED} task_check(s) not passed; fix and re-run, or supply an escalation" >&2
    exit 1
  fi
fi

# --- merge injected facts over the payload (facts win) ----------------------
DONE_STATE_DIR="$PROJECT_DIR/.claude/.harness/done-state"
mkdir -p "$DONE_STATE_DIR" 2>/dev/null
OUT_FILE="$DONE_STATE_DIR/${SESSION_ID}.json"

RESULT=$(printf '%s' "$PAYLOAD" | jq \
  --arg sid "$SESSION_ID" \
  --arg sha "$VERIFIED_SHA" \
  --argjson clean "$TREE_CLEAN" '
  . * {session_id: $sid, verified_sha: $sha, tree_clean: $clean}
' 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "error: failed to assemble done-state JSON" >&2
  exit 1
fi

printf '%s\n' "$RESULT" > "$OUT_FILE" 2>/dev/null
if [ ! -f "$OUT_FILE" ]; then
  echo "error: failed to write $OUT_FILE" >&2
  exit 1
fi

echo "$OUT_FILE"
exit 0
