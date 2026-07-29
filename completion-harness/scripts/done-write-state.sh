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
  echo "error: no JSON payload on stdin (supply dod/task_checks/tests/... )" >&2
  exit 1
fi
if ! printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1; then
  echo "error: stdin payload is not valid JSON" >&2
  exit 1
fi

# --- resolve session id ------------------------------------------------------
# Same precedence as the skill/preflight so writer-key == gate-key: arg →
# authoritative current-session marker → newest baselines/*.sha heuristic. The
# skill normally passes the marker-resolved id as $1; the marker fallback is
# defense-in-depth if the writer is ever invoked without one. The env var is
# deliberately NOT used — it leaks into child/subagent shells and test
# subprocesses, so the per-project marker is the trustworthy source.
SESSION_ID="${1:-}"
BASELINE_DIR="$PROJECT_DIR/.claude/.harness/baselines"
if [ -z "$SESSION_ID" ] && [ -f "$PROJECT_DIR/.claude/.harness/current-session" ]; then
  SESSION_ID=$(cat "$PROJECT_DIR/.claude/.harness/current-session" 2>/dev/null)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -t "$BASELINE_DIR"/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//')
fi
if [ -z "$SESSION_ID" ]; then
  echo "error: could not resolve session id (no arg and no baseline .sha found)" >&2
  exit 1
fi

# --- resolve identity (task_key) via the shared resolver --------------------
# Done-state is keyed by HC_TASK_KEY (task-branch continuity across sessions),
# not the raw session id — the gate reads the same key. The injected session_id
# JSON field below stays the raw resolved id. Guarded: on any failure fall back
# to a session-scoped key so the writer still produces a consistent path.
if [ -f "$(dirname "$0")/harness-common.sh" ]; then
  . "$(dirname "$0")/harness-common.sh" 2>/dev/null
fi
if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ -z "$HC_TASK_KEY" ] && HC_TASK_KEY="session-${SESSION_ID}"

# --- structural backstop: reject a DEAD session id in session mode ----------
# In SESSION mode the done-state key is "session-<id>", the SAME key the Stop
# gate derives from ITS hook-stdin session_id. If this id has NO matching
# baselines/<id>.sha, SessionStart never recorded it → the gate will key off a
# DIFFERENT id and never read what we write → a silent forever-block. Fail LOUD
# here instead. (In TASK mode the branch keys the done-state, not the id, so this
# check applies only to the session-mode path.) Skipped when the baselines dir is
# absent entirely (no baselines to compare against → nothing to reconcile).
# NOTE: this guard fires for an id passed EXPLICITLY as $1 with no matching .sha
# (the skill's Step-7 call). The no-arg `ls -t` fallback above can only ever pick
# an id that HAS a .sha (it globbed them), so it cannot itself produce a dead id;
# the DRIFT case (ls -t picking a stale/parallel session) is prevented UPSTREAM by
# the skill preferring the current-session marker. The two protections are
# complementary — do not remove one assuming the other is redundant.
if [ "$HC_MODE" = "session" ] && [ -d "$BASELINE_DIR" ] && ls "$BASELINE_DIR"/*.sha >/dev/null 2>&1; then
  if [ ! -f "$BASELINE_DIR/${SESSION_ID}.sha" ]; then
    VALID_IDS=$(ls -t "$BASELINE_DIR"/*.sha 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//' | tr '\n' ' ')
    MARKER_ID=$(cat "$PROJECT_DIR/.claude/.harness/current-session" 2>/dev/null)
    echo "error: refusing to write — session id '${SESSION_ID}' has no baselines/${SESSION_ID}.sha, so the done-state key 'session-${SESSION_ID}' is one the Stop gate never reads (silent forever-block). Pass the id the gate uses: the current-session marker (${MARKER_ID:-none recorded}), or one of the valid ids: ${VALID_IDS:-none}" >&2
    exit 1
  fi
fi

# --- inject live git facts ---------------------------------------------------
VERIFIED_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$VERIFIED_SHA" ]; then
  echo "error: not a git repo (git rev-parse HEAD failed) — cannot record done-state" >&2
  exit 1
fi

# Baseline-relative tree check via the shared classifier (same predicate the
# gate uses). Refuse iff there are INTRODUCED blockers (the changeset's own
# uncommitted work); pre-existing entries are ignored (never surfaced). tree_clean reflects
# "no blockers". Keeps the word "dirty" in the refusal for parity/clarity.
TREE_CLEAN=true
if command -v hc_tree_status >/dev/null 2>&1 || type hc_tree_status >/dev/null 2>&1; then
  hc_tree_status "$SESSION_ID" 2>/dev/null
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    echo "error: working tree dirty — $(hc_tree_remediation); commit before recording done-state" >&2
    exit 1
  fi
else
  # Classifier unavailable: fall back to the strict live check (never weaken).
  GIT_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
  if [ -n "$GIT_STATUS" ]; then
    echo "error: working tree dirty — commit before recording done-state" >&2
    exit 1
  fi
fi

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
  # tests must be GREEN AND carry evidence. tests.status=="not_run" is allowed
  # ONLY with an escalation (handled by the outer branch — we are in the no-
  # escalation path here, so a not_run reaching this point is refused). A green
  # tests payload must record exit_code==0 AND a non-empty command AND a
  # non-empty output_tail — "green must carry evidence" (P1-c, #6). A
  # missing/empty field fails toward refuse.
  P_TESTS_STATUS=$(printf '%s' "$PAYLOAD" | jq -r '.tests.status // ""' 2>/dev/null)
  if [ "$P_TESTS_STATUS" = "not_run" ]; then
    echo "error: refusing to write — tests were not run (status=not_run) and there is no escalation; run the tests, or supply an escalation recording why they cannot run" >&2
    exit 1
  fi
  P_TESTS_EXIT=$(printf '%s' "$PAYLOAD" | jq -r '.tests.exit_code // "MISSING"' 2>/dev/null)
  if [ "$P_TESTS_EXIT" != "0" ]; then
    echo "error: refusing to write — tests are not green (exit_code=${P_TESTS_EXIT}); fix and re-run, or supply an escalation" >&2
    exit 1
  fi
  P_TESTS_CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tests.command // ""' 2>/dev/null)
  P_TESTS_TAIL=$(printf '%s' "$PAYLOAD" | jq -r '.tests.output_tail // ""' 2>/dev/null)
  if [ -z "$P_TESTS_CMD" ] || [ -z "$P_TESTS_TAIL" ]; then
    echo "error: refusing to write — green tests must carry evidence: a non-empty 'command' and 'output_tail'; record what ran and its output tail, or supply an escalation" >&2
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

  # review-log: an independent review-log for the LIVE HEAD must exist. The
  # BLOCKING count is computed STRUCTURALLY by hc_review_blocking (the same shared
  # function the gate uses) from findings[].severity and the configured
  # min_review_level (default "high") — mirrors the gate so the agent gets the
  # feedback at /done time. Findings below the threshold are advisory and never
  # refuse. HEAD is the live rev-parse computed above (VERIFIED_SHA). A missing
  # log, or a jq crash / unknown severity ("ERR"), all refuse (fail toward block).
  REVIEW_LOG="$PROJECT_DIR/.claude/.harness/review-log/${VERIFIED_SHA}.json"
  if [ ! -f "$REVIEW_LOG" ]; then
    echo "error: refusing to write — no independent review-log for HEAD ${VERIFIED_SHA:0:7} (.claude/.harness/review-log/${VERIFIED_SHA}.json); run the Step-4 review, or supply an escalation" >&2
    exit 1
  fi
  # Hard contract: the review-log must be structurally valid before any severity
  # or coverage reasoning trusts its fields. A malformed/forged log fails schema
  # and is refused here, before hc_review_blocking/hc_review_coverage_gap run.
  if command -v hc_validate >/dev/null 2>&1 || type hc_validate >/dev/null 2>&1; then
    if ! hc_validate "$HC_CONTRACTS_DIR/review-log.schema.json" "$REVIEW_LOG" >/dev/null 2>&1; then
      echo "error: refusing to write — review-log fails contract (schema) for HEAD ${VERIFIED_SHA:0:7}; the log is malformed or missing required fields" >&2
      exit 1
    fi
  else
    echo "error: refusing to write — contract validator unavailable (broken install); cannot verify review-log integrity" >&2
    exit 1
  fi
  MIN_LEVEL=$(jq -r '.min_review_level // "high"' "$PROJECT_DIR/.claude/done-config.json" 2>/dev/null)
  [ -z "$MIN_LEVEL" ] && MIN_LEVEL="high"
  # Explicit availability guard (parity with the hc_tree_status fallback): if the
  # library failed to source, force ERR so we refuse the write, never write silently.
  if command -v hc_review_blocking >/dev/null 2>&1 || type hc_review_blocking >/dev/null 2>&1; then
    P_OPEN=$(hc_review_blocking "$REVIEW_LOG" "$MIN_LEVEL")
  else
    P_OPEN="ERR"
  fi
  if [ "$P_OPEN" != "0" ]; then
    echo "error: refusing to write — ${P_OPEN} blocking (≥ ${MIN_LEVEL}) review findings for HEAD ${VERIFIED_SHA:0:7}; address them and re-run, or supply an escalation" >&2
    exit 1
  fi

  # review COVERAGE: mirror the gate's structural coverage check via the same
  # shared function. The review-log must attest EVERY file the changeset touched
  # (git diff --name-only HC_BASE..VERIFIED_SHA). A non-empty gap refuses; SKIP
  # (no changeset base → not computable) passes (no-regression degrade). Gives the
  # agent the coverage feedback at /done time rather than at stop time. Same
  # fail-toward-block discipline: a computation error with a real changeset returns
  # the full changed set (non-empty → refuse), never SKIP.
  if command -v hc_review_coverage_gap >/dev/null 2>&1 || type hc_review_coverage_gap >/dev/null 2>&1; then
    P_GAP=$(hc_review_coverage_gap "$REVIEW_LOG" "$HC_BASE" "$VERIFIED_SHA" "$PROJECT_DIR")
  else
    # Library failed to source — the review-log refusal above already exited via
    # the ERR path, so we never reach here without the function; but guard anyway
    # by refusing (fail toward block, never silently write).
    P_GAP="LIBUNAVAILABLE"
  fi
  if [ -n "$P_GAP" ] && [ "$P_GAP" != "SKIP" ]; then
    P_GAP_LIST=$(printf '%s' "$P_GAP" | tr '\n' ' ')
    echo "error: refusing to write — review did not cover changed files: ${P_GAP_LIST}(HEAD ${VERIFIED_SHA:0:7} vs base ${HC_BASE:0:7}); re-review the full changeset and record every changed file in the review-log's files_reviewed, or supply an escalation" >&2
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
OUT_FILE="$DONE_STATE_DIR/${HC_TASK_KEY}.json"

RESULT=$(printf '%s' "$PAYLOAD" | jq \
  --arg sid "$SESSION_ID" \
  --arg sha "$VERIFIED_SHA" \
  --argjson clean "$TREE_CLEAN" '
  . * {contract_version: 1, session_id: $sid, verified_sha: $sha, tree_clean: $clean}
' 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "error: failed to assemble done-state JSON" >&2
  exit 1
fi

# Hard contract: validate the assembled done-state BEFORE writing it. This is
# UNCONDITIONAL — escalation bypasses green-OUTCOME refusals only, never
# structural validity. A done-state that fails schema must never reach disk.
VALIDATE_TMP=$(mktemp 2>/dev/null)
if [ -z "$VALIDATE_TMP" ]; then
  echo "error: failed to create temp file for contract validation" >&2
  exit 1
fi
printf '%s\n' "$RESULT" > "$VALIDATE_TMP" 2>/dev/null
if command -v hc_validate >/dev/null 2>&1 || type hc_validate >/dev/null 2>&1; then
  if ! hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$VALIDATE_TMP" >/dev/null 2>&1; then
    rm -f "$VALIDATE_TMP" 2>/dev/null
    echo "error: refusing to write — assembled done-state fails contract (schema); it is missing required fields or has an invalid shape" >&2
    exit 1
  fi
else
  rm -f "$VALIDATE_TMP" 2>/dev/null
  echo "error: refusing to write — contract validator unavailable (broken install); cannot verify done-state integrity" >&2
  exit 1
fi
rm -f "$VALIDATE_TMP" 2>/dev/null

printf '%s\n' "$RESULT" > "$OUT_FILE" 2>/dev/null
if [ ! -f "$OUT_FILE" ]; then
  echo "error: failed to write $OUT_FILE" >&2
  exit 1
fi

echo "$OUT_FILE"
exit 0
