#!/bin/bash
#
# Completion Harness — /done triage: compute the applicable steps + audit plan.
#
# Deterministic applicability engine for the thin /done SKILL. Reads the
# EFFECTIVE config from stdin (done-detect.sh output), decides which DoD steps
# apply to THIS changeset, writes a schema-validated FULL plan (applicable +
# excluded, with reasons) to .claude/.harness/done-plan/<task_key>.json (audit
# only — the gate gains NO precondition on it), and prints ONLY the applicable
# steps to stdout in canonical order for the agent to execute.
#
# FAIL-SAFE DIRECTION (the one unacceptable outcome is a wrongly-EXCLUDED step):
#   - a step is excluded ONLY when a deterministic CONFIG signal proves it
#     vacuously N/A; ANY uncertainty INCLUDES the step;
#   - on ANY hard error (jq missing, unreadable config, self-validation failure)
#     → error to stderr, EMPTY stdout, exit non-zero → the SKILL fallback runs
#     ALL steps.
#
# Mirrors harness-resolve.sh: sources harness-common.sh, self-validates the
# assembled plan against contracts/done-plan.schema.json via hc_validate before
# emitting anything usable.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

SELF_DIR=$(dirname "$0" 2>/dev/null)
[ -z "$SELF_DIR" ] && SELF_DIR="."

# shellcheck source=harness-common.sh
if [ -f "$SELF_DIR/harness-common.sh" ]; then
  . "$SELF_DIR/harness-common.sh" 2>/dev/null
fi

# jq is mandatory — without it we cannot read config or build/validate the plan.
if ! command -v jq >/dev/null 2>&1; then
  printf 'done-triage: jq is required — cannot compute plan; run ALL steps (fallback)\n' >&2
  exit 1
fi

CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"

# --- effective config: from stdin (detect output), else recompute from file ---
EFFECTIVE=$(cat 2>/dev/null)
if [ -z "$EFFECTIVE" ] || ! printf '%s' "$EFFECTIVE" | jq empty >/dev/null 2>&1; then
  # No/invalid stdin → fall back to computing effective = detected * overrides.
  if [ -f "$CONFIG_FILE" ]; then
    EFFECTIVE=$(jq -c '((.detected // {}) * (.overrides // {}))' "$CONFIG_FILE" 2>/dev/null)
  fi
fi
[ -z "$EFFECTIVE" ] && EFFECTIVE='{}'
if ! printf '%s' "$EFFECTIVE" | jq empty >/dev/null 2>&1; then
  printf 'done-triage: could not obtain a valid effective config; run ALL steps (fallback)\n' >&2
  exit 1
fi

# --- signals ----------------------------------------------------------------
# LINT / START come from the EFFECTIVE config (overrides over detected).
LINT=$(printf '%s' "$EFFECTIVE" | jq -r '.lint // ""' 2>/dev/null)
START=$(printf '%s' "$EFFECTIVE" | jq -r '.start // ""' 2>/dev/null)
# START_CHECK / DEPLOY_CHECK are top-level sticky config keys (not part of the
# detected/overrides merge), read straight from done-config.json.
START_CHECK=""
DEPLOY_CHECK=""
if [ -f "$CONFIG_FILE" ]; then
  START_CHECK=$(jq -r '.start_check_cmd // ""' "$CONFIG_FILE" 2>/dev/null)
  DEPLOY_CHECK=$(jq -r '.deploy_check_cmd // ""' "$CONFIG_FILE" 2>/dev/null)
fi
# jq prints the string "null" for a JSON null via `// ""` only when the key is
# absent; a literal null yields "" already. Normalize the literal "null" text too.
[ "$LINT" = "null" ] && LINT=""
[ "$START" = "null" ] && START=""
[ "$START_CHECK" = "null" ] && START_CHECK=""
[ "$DEPLOY_CHECK" = "null" ] && DEPLOY_CHECK=""

# --- resolve session id + task_key (same precedence as writer/SKILL Step 1) --
MARKER="$(hc__harness_dir)/current-session"
SID=""
if [ -f "$MARKER" ]; then SID=$(cat "$MARKER" 2>/dev/null); fi
if [ -z "$SID" ]; then
  SID=$(ls -t "$(hc__harness_dir)"/baselines/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//')
fi
if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "$SID" 2>/dev/null
fi
TASK_KEY="${HC_TASK_KEY:-session-$SID}"
[ -z "$TASK_KEY" ] && TASK_KEY="session-"

# --- applicability ----------------------------------------------------------
# id → anchor mapping: 0.5→step-0-5, 2-lint→step-2-lint, else step-<id>.
anchor_for() {
  case "$1" in
    0.5)    printf 'step-0-5' ;;
    2-lint) printf 'step-2-lint' ;;
    *)      printf 'step-%s' "$1" ;;
  esac
}

# 2-lint applies iff a lint command is configured.
LINT_STATUS="applicable"; LINT_REASON=""
if [ -z "$LINT" ]; then
  LINT_STATUS="excluded"; LINT_REASON="no lint command configured"
fi
# 3 applies iff any of start / start_check_cmd / deploy_check_cmd is configured.
STEP3_STATUS="applicable"; STEP3_REASON=""
if [ -z "$START" ] && [ -z "$START_CHECK" ] && [ -z "$DEPLOY_CHECK" ]; then
  STEP3_STATUS="excluded"; STEP3_REASON="no start/start_check_cmd/deploy_check_cmd configured"
fi

# Canonical ordered step table: id | title | status | reason.
# Always-applicable steps carry status "applicable" and no reason. Step 4 is
# ALWAYS listed (triage cannot see task_checks; the step self-skips when empty).
emit_step() {
  # $1=id $2=title $3=status $4=reason
  local id="$1" title="$2" status="$3" reason="$4"
  local anchor; anchor=$(anchor_for "$id")
  jq -nc \
    --arg id "$id" --arg title "$title" --arg status "$status" \
    --arg ref "dod-protocol.md#$anchor" --arg reason "$reason" \
    'if ($reason | length) > 0
     then {id:$id, title:$title, status:$status, ref:$ref, reason:$reason}
     else {id:$id, title:$title, status:$status, ref:$ref} end'
}

STEPS_JSON=$(
  {
    emit_step "0"      "Preflight — prove the gate is winnable"   "applicable" ""
    emit_step "0.5"    "Assemble the effective DoD"               "applicable" ""
    emit_step "1"      "Changeset scope"                          "applicable" ""
    emit_step "2"      "Tests (before/after checkpoint)"          "applicable" ""
    emit_step "2-lint" "Lint (when configured)"                   "$LINT_STATUS" "$LINT_REASON"
    emit_step "3"      "App startup"                              "$STEP3_STATUS" "$STEP3_REASON"
    emit_step "4"      "Task-specific checks"                     "applicable" ""
    emit_step "5"      "Code review (independent subagent)"       "applicable" ""
    emit_step "6"      "Address findings (bounded loop)"          "applicable" ""
    emit_step "7"      "Write done-state (script)"                "applicable" ""
    emit_step "8"      "Report"                                   "applicable" ""
  } | jq -sc '.'
)

if [ -z "$STEPS_JSON" ]; then
  printf 'done-triage: failed to assemble the step plan; run ALL steps (fallback)\n' >&2
  exit 1
fi

PLAN_JSON=$(jq -nc \
  --arg task_key "$TASK_KEY" \
  --argjson steps "$STEPS_JSON" \
  '{contract_version:1, task_key:$task_key, steps:$steps}' 2>/dev/null)

if [ -z "$PLAN_JSON" ]; then
  printf 'done-triage: failed to build plan JSON; run ALL steps (fallback)\n' >&2
  exit 1
fi

# --- SELF-VALIDATE against the done-plan contract before emitting anything ---
TMP_JSON=$(mktemp 2>/dev/null)
if [ -z "$TMP_JSON" ]; then
  printf 'done-triage: mktemp failed; run ALL steps (fallback)\n' >&2
  exit 1
fi
printf '%s\n' "$PLAN_JSON" > "$TMP_JSON"
if ! hc_validate "$HC_CONTRACTS_DIR/done-plan.schema.json" "$TMP_JSON" >/dev/null 2>&1; then
  printf 'done-triage: plan failed contract validation: %s; run ALL steps (fallback)\n' \
    "$(hc_validate "$HC_CONTRACTS_DIR/done-plan.schema.json" "$TMP_JSON" 2>&1)" >&2
  rm -f "$TMP_JSON" 2>/dev/null
  exit 1
fi
rm -f "$TMP_JSON" 2>/dev/null

# --- write the plan (best-effort — a write failure must NOT block stdout) ----
PLAN_DIR="$(hc__harness_dir)/done-plan"
mkdir -p "$PLAN_DIR" 2>/dev/null
PLAN_FILE="$PLAN_DIR/${TASK_KEY}.json"
printf '%s\n' "$PLAN_JSON" > "$PLAN_FILE" 2>/dev/null

# --- STDOUT: header + one line per APPLICABLE step, canonical order ----------
APPLICABLE=$(printf '%s' "$PLAN_JSON" | jq -r '[.steps[] | select(.status=="applicable")] | length' 2>/dev/null)
TOTAL=$(printf '%s' "$PLAN_JSON" | jq -r '.steps | length' 2>/dev/null)
printf 'done plan: %s of %s steps apply (full plan incl. excluded → %s)\n' \
  "${APPLICABLE:-?}" "${TOTAL:-?}" "$PLAN_FILE"

# `[id] <intent, padded> → dod-protocol.md#<anchor>` per applicable step.
printf '%s' "$PLAN_JSON" | jq -r '
  .steps[]
  | select(.status=="applicable")
  | "[" + .id + "] " + (.title | .[0:44] + (" " * (44 - (.|length))) ) + " → " + .ref
' 2>/dev/null

exit 0
