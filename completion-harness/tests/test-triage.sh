#!/bin/bash
#
# Tests for done-triage.sh (computed /done plan: applicability + audit plan).
# Runs in throwaway tmpdirs so it never mutates the trial's checked-in state.
# Sources the source-tree harness-common.sh for hc_validate + HC_CONTRACTS_DIR.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
SCRIPT="$SCRIPTS/done-triage.sh"
PROTO="$(cd "$(dirname "$0")/../skills/done" && pwd)/dod-protocol.md"
OLD_SKILL_HEADINGS=(
  "Step 0 — Preflight" "Config detection" "Step 0.5" "Step 1" "Step 2"
  "Step 3" "Step 4" "Step 5" "Step 6" "Step 7" "Step 8" "Escalation rules"
)

# shellcheck source=/dev/null
. "$SCRIPTS/harness-common.sh" 2>/dev/null

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-triage =="

# Build a throwaway project with a done-config.json shaped by the args, run
# triage, and capture stdout / the written plan file. Sets globals:
#   T_OUT (stdout), T_RC (exit), T_PLAN (plan file path), T_TMP (dir).
# $1 = detected JSON, $2 = start_check_cmd (json), $3 = deploy_check_cmd (json).
run_triage() {
  local detected="$1" start_check="${2:-null}" deploy_check="${3:-null}"
  T_TMP=$(mktemp -d)
  mkdir -p "$T_TMP/.claude/.harness/baselines"
  cat > "$T_TMP/.claude/done-config.json" <<JSON
{"contract_version":1,"detected":${detected},"overrides":{},"start_check_cmd":${start_check},"deploy_check_cmd":${deploy_check}}
JSON
  local eff
  eff=$(jq -c '.detected' "$T_TMP/.claude/done-config.json")
  T_OUT=$(CLAUDE_PROJECT_DIR="$T_TMP" printf '%s' "$eff" | CLAUDE_PROJECT_DIR="$T_TMP" bash "$SCRIPT" 2>/dev/null)
  T_RC=$?
  T_PLAN=$(ls "$T_TMP"/.claude/.harness/done-plan/*.json 2>/dev/null | head -1)
}

cleanup_triage() { [ -n "$T_TMP" ] && rm -rf "$T_TMP"; }

# --- 1. full config (lint + start) → 2-lint AND 3 applicable ----------------
run_triage '{"lint":"npm run lint","start":"npm start"}'
if [ "$T_RC" -eq 0 ]; then ok "full config: exit 0"; else bad "full config exit ($T_RC)"; fi
if echo "$T_OUT" | grep -q '^\[2-lint\]'; then ok "full config: 2-lint applicable (stdout)"; else bad "2-lint not in stdout"; fi
if echo "$T_OUT" | grep -q '^\[3\]'; then ok "full config: 3 applicable (stdout)"; else bad "3 not in stdout"; fi
if jq -e '[.steps[]|select(.status=="applicable")]|length == 11' "$T_PLAN" >/dev/null 2>&1; then
  ok "full config: all 11 steps applicable in plan"
else bad "full config: plan not all-applicable"; fi
# plan self-validates against done-plan.schema.json
if hc_validate "$HC_CONTRACTS_DIR/done-plan.schema.json" "$T_PLAN" >/dev/null 2>&1; then
  ok "full config: written plan validates against done-plan.schema.json"
else bad "full config: plan failed schema: $(hc_validate "$HC_CONTRACTS_DIR/done-plan.schema.json" "$T_PLAN" 2>&1)"; fi
cleanup_triage

# --- 2. no-lint / no-start → both 2-lint AND 3 EXCLUDED ---------------------
run_triage '{}'
if [ "$T_RC" -eq 0 ]; then ok "no-lint/no-start: exit 0"; else bad "no-lint/no-start exit ($T_RC)"; fi
# EXCLUDED steps must be ABSENT from stdout.
if ! echo "$T_OUT" | grep -q '^\[2-lint\]'; then ok "2-lint ABSENT from stdout (excluded)"; else bad "2-lint leaked to stdout"; fi
if ! echo "$T_OUT" | grep -q '^\[3\]'; then ok "3 ABSENT from stdout (excluded)"; else bad "3 leaked to stdout"; fi
# EXCLUDED steps carry the EXACT reason strings, in the PLAN FILE.
if jq -e '.steps[]|select(.id=="2-lint")|.status=="excluded" and .reason=="no lint command configured"' "$T_PLAN" >/dev/null 2>&1; then
  ok "2-lint excluded with exact reason (plan file)"
else bad "2-lint exclusion/reason wrong: $(jq -c '.steps[]|select(.id=="2-lint")' "$T_PLAN" 2>/dev/null)"; fi
if jq -e '.steps[]|select(.id=="3")|.status=="excluded" and .reason=="no start/start_check_cmd/deploy_check_cmd configured"' "$T_PLAN" >/dev/null 2>&1; then
  ok "3 excluded with exact reason (plan file)"
else bad "3 exclusion/reason wrong: $(jq -c '.steps[]|select(.id=="3")' "$T_PLAN" 2>/dev/null)"; fi
# excluded steps carry a reason; applicable steps carry a ref anchor.
if jq -e '[.steps[]|select(.status=="excluded")|has("reason")]|all' "$T_PLAN" >/dev/null 2>&1; then
  ok "every excluded step carries a reason"
else bad "an excluded step lacks a reason"; fi
if jq -e '[.steps[]|select(.status=="applicable")|.ref|test("^dod-protocol\\.md#step-")]|all' "$T_PLAN" >/dev/null 2>&1; then
  ok "every applicable step ref matches dod-protocol.md#step-*"
else bad "an applicable ref anchor is malformed"; fi
# Step 4 ALWAYS applicable regardless of config.
if jq -e '.steps[]|select(.id=="4")|.status=="applicable"' "$T_PLAN" >/dev/null 2>&1; then
  ok "Step 4 ALWAYS applicable (no config)"
else bad "Step 4 not applicable"; fi
# always-steps present in canonical order in stdout.
CANON=$(echo "$T_OUT" | grep -oE '^\[[0-9.]+\]' | tr -d '[]')
EXPECT=$(printf '0\n0.5\n1\n2\n4\n5\n6\n7\n8')
if [ "$CANON" = "$EXPECT" ]; then ok "always-steps in canonical order (stdout)"; else bad "order wrong: got [$CANON]"; fi
cleanup_triage

# --- 3. start_check_cmd-only → 3 applicable ---------------------------------
run_triage '{}' '"curl -sf localhost/health"' 'null'
if echo "$T_OUT" | grep -q '^\[3\]' && jq -e '.steps[]|select(.id=="3")|.status=="applicable"' "$T_PLAN" >/dev/null 2>&1; then
  ok "start_check_cmd-only: 3 applicable"
else bad "start_check_cmd-only: 3 not applicable"; fi
cleanup_triage

# --- 4. deploy_check_cmd-only → 3 applicable --------------------------------
run_triage '{}' 'null' '"kubectl rollout status"'
if echo "$T_OUT" | grep -q '^\[3\]' && jq -e '.steps[]|select(.id=="3")|.status=="applicable"' "$T_PLAN" >/dev/null 2>&1; then
  ok "deploy_check_cmd-only: 3 applicable"
else bad "deploy_check_cmd-only: 3 not applicable"; fi
# Step 4 still applicable regardless.
if jq -e '.steps[]|select(.id=="4")|.status=="applicable"' "$T_PLAN" >/dev/null 2>&1; then
  ok "Step 4 ALWAYS applicable (deploy-only config)"
else bad "Step 4 not applicable in deploy-only config"; fi
cleanup_triage

# --- 5. overrides win: detected lint absent but override sets it → applicable
T5=$(mktemp -d); mkdir -p "$T5/.claude/.harness/baselines"
cat > "$T5/.claude/done-config.json" <<'JSON'
{"contract_version":1,"detected":{},"overrides":{"lint":"eslint ."},"start_check_cmd":null,"deploy_check_cmd":null}
JSON
EFF5=$(jq -c '((.detected)*(.overrides))' "$T5/.claude/done-config.json")
OUT5=$(CLAUDE_PROJECT_DIR="$T5" printf '%s' "$EFF5" | CLAUDE_PROJECT_DIR="$T5" bash "$SCRIPT" 2>/dev/null)
if echo "$OUT5" | grep -q '^\[2-lint\]'; then ok "override lint wins → 2-lint applicable"; else bad "override lint ignored"; fi
rm -rf "$T5"

# --- 6. hard-error path (jq missing) → non-zero exit + EMPTY stdout ----------
T6=$(mktemp -d); mkdir -p "$T6/nojq" "$T6/.claude/.harness/baselines"
cat > "$T6/.claude/done-config.json" <<'JSON'
{"contract_version":1,"detected":{"lint":"x"},"overrides":{}}
JSON
BASHBIN=$(command -v bash)
for t in bash sh cat ls head sed xargs mkdir rm dirname basename mktemp printf grep; do
  p=$(command -v "$t" 2>/dev/null); [ -n "$p" ] && ln -sf "$p" "$T6/nojq/$t"
done
OUT6=$(PATH="$T6/nojq" CLAUDE_PROJECT_DIR="$T6" "$BASHBIN" "$SCRIPT" </dev/null 2>/dev/null)
RC6=$?
if [ "$RC6" -ne 0 ] && [ -z "$OUT6" ]; then
  ok "jq-missing hard error → non-zero exit ($RC6) + empty stdout"
else bad "jq-missing path: rc=$RC6 stdout=[$OUT6]"; fi
rm -rf "$T6"

# --- 7. anchor integrity: every ref triage emits EXISTS in dod-protocol.md ---
run_triage '{"lint":"l","start":"s"}'
MISSING_ANCHOR=0
while IFS= read -r a; do
  [ -z "$a" ] && continue
  if ! grep -qF "<a id=\"$a\">" "$PROTO"; then
    MISSING_ANCHOR=1; echo "    missing anchor: $a"
  fi
done < <(jq -r '.steps[].ref | sub("^dod-protocol\\.md#";"")' "$T_PLAN" 2>/dev/null)
if [ "$MISSING_ANCHOR" -eq 0 ]; then
  ok "every triage ref anchor exists as <a id=...> in dod-protocol.md"
else bad "at least one triage ref anchor is missing from dod-protocol.md"; fi
cleanup_triage

# --- 8. self-sufficiency: dod-protocol.md has all old SKILL step headings ----
MISSING_HEAD=0
for h in "${OLD_SKILL_HEADINGS[@]}"; do
  if ! grep -qF "$h" "$PROTO"; then MISSING_HEAD=1; echo "    missing heading: $h"; fi
done
if [ "$MISSING_HEAD" -eq 0 ]; then
  ok "dod-protocol.md contains every old SKILL step heading (no content dropped)"
else bad "dod-protocol.md is missing a step heading the old SKILL body had"; fi

echo
echo "test-triage: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
