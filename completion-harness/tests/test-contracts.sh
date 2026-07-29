#!/bin/bash
#
# test-contracts.sh — hard-contract foundation: schemas + hc_validate.
# Sources the source-tree harness-common.sh and reads the source-tree contracts
# (completion-harness/scripts + contracts, resolved relative to this test). No
# install needed. All fixtures are built in a throwaway $TMP dir.

source "$(cd "$(dirname "$0")/../scripts" && pwd)/harness-common.sh"
CONTRACTS="$(cd "$(dirname "$0")/../contracts" && pwd)"

PASS=0
FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
bad(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Validate schema $1 against fixture $2 — returns hc_validate exit code.
vok(){ hc_validate "$1" "$2" >/dev/null 2>&1; }

echo "== test-contracts =="

# --- minimal VALID fixtures for each schema return 0 ------------------------
cat > "$TMP/review-log.json" <<'JSON'
{"contract_version":1,"reviewed_sha":"abc","min_review_level":"high","files_reviewed":["a.txt"],"findings":[]}
JSON
if vok "$CONTRACTS/review-log.schema.json" "$TMP/review-log.json"; then
  ok "review-log minimal valid → 0"
else bad "review-log minimal valid → 0"; fi

cat > "$TMP/done-state.json" <<'JSON'
{"contract_version":1,"session_id":"s","verified_sha":"h","tree_clean":true,"dod":{"sources":["base-dod.md"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[]}
JSON
if vok "$CONTRACTS/done-state.schema.json" "$TMP/done-state.json"; then
  ok "done-state minimal valid → 0"
else bad "done-state minimal valid → 0"; fi

# --- done-state tests oneOf branches (P1-c, #6) -----------------------------
DS_PRE='{"contract_version":1,"session_id":"s","verified_sha":"h","tree_clean":true,"dod":{"sources":["b"],"items":["x"]},"task_checks":[],"tests":'
# (green) exit_code:0 + command + output_tail → valid.
cat > "$TMP/ds-green.json" <<JSON
${DS_PRE}{"exit_code":0,"command":"npm test","output_tail":"ok"}}
JSON
if vok "$CONTRACTS/done-state.schema.json" "$TMP/ds-green.json"; then
  ok "done-state tests green (evidence) → 0"
else bad "done-state tests green (evidence) → 0"; fi

# (green) exit_code:0 but MISSING evidence → INVALID (matches no oneOf branch).
cat > "$TMP/ds-greenbad.json" <<JSON
${DS_PRE}{"exit_code":0}}
JSON
if ! vok "$CONTRACTS/done-state.schema.json" "$TMP/ds-greenbad.json"; then
  ok "done-state tests green WITHOUT evidence → nonzero"
else bad "done-state tests green WITHOUT evidence → nonzero"; fi

# (red) exit_code:1 → valid (red branch: integer != 0).
cat > "$TMP/ds-red.json" <<JSON
${DS_PRE}{"exit_code":1}}
JSON
if vok "$CONTRACTS/done-state.schema.json" "$TMP/ds-red.json"; then
  ok "done-state tests red (exit 1) → 0"
else bad "done-state tests red (exit 1) → 0"; fi

# (not_run) status:not_run + reason → valid.
cat > "$TMP/ds-notrun.json" <<JSON
${DS_PRE}{"status":"not_run","reason":"docker down"}}
JSON
if vok "$CONTRACTS/done-state.schema.json" "$TMP/ds-notrun.json"; then
  ok "done-state tests not_run (reason) → 0"
else bad "done-state tests not_run (reason) → 0"; fi

# (not_run) status:not_run MISSING reason → INVALID.
cat > "$TMP/ds-notrunbad.json" <<JSON
${DS_PRE}{"status":"not_run"}}
JSON
if ! vok "$CONTRACTS/done-state.schema.json" "$TMP/ds-notrunbad.json"; then
  ok "done-state tests not_run WITHOUT reason → nonzero"
else bad "done-state tests not_run WITHOUT reason → nonzero"; fi

cat > "$TMP/done-config.json" <<'JSON'
{"contract_version":1,"detected":{},"overrides":{},"max_fix_attempts":3,"max_review_rounds":2,"baseline_snapshot":true,"start_timeout":30,"untracked_policy":"baseline","min_review_level":"high","auto_branch":true,"branch_prefix":"task/"}
JSON
if vok "$CONTRACTS/done-config.schema.json" "$TMP/done-config.json"; then
  ok "done-config minimal valid → 0"
else bad "done-config minimal valid → 0"; fi

cat > "$TMP/resolver.json" <<'JSON'
{"contract_version":1,"mode":"task","task_key":"br-x","base":"abc","trunk":"main","branch":"x","warn":""}
JSON
if vok "$CONTRACTS/resolver-output.schema.json" "$TMP/resolver.json"; then
  ok "resolver-output minimal valid → 0"
else bad "resolver-output minimal valid → 0"; fi

cat > "$TMP/base-dod.json" <<'JSON'
{"contract_version":1,"items":[{"id":"a","text":"t","blocking":true}]}
JSON
if vok "$CONTRACTS/base-dod.schema.json" "$TMP/base-dod.json"; then
  ok "base-dod minimal valid → 0"
else bad "base-dod minimal valid → 0"; fi

# --- shipped data files -----------------------------------------------------
# base-dod.json ships and MUST validate against its schema.
if vok "$CONTRACTS/base-dod.schema.json" "$CONTRACTS/base-dod.json"; then
  ok "shipped base-dod.json validates against base-dod.schema.json → 0"
else bad "shipped base-dod.json validates against base-dod.schema.json → 0"; fi

# shell-abi.json is a declared ABI (NOT runtime-validated) — just assert it
# exists and is well-formed JSON.
if [ -f "$CONTRACTS/shell-abi.json" ] && jq empty "$CONTRACTS/shell-abi.json" >/dev/null 2>&1; then
  ok "shell-abi.json exists and is valid JSON"
else bad "shell-abi.json exists and is valid JSON"; fi

# --- NONZERO on invalid instances -------------------------------------------
# contract_version wrong (2).
cat > "$TMP/badver.json" <<'JSON'
{"contract_version":2,"reviewed_sha":"abc","min_review_level":"high","files_reviewed":[],"findings":[]}
JSON
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/badver.json"; then
  ok "contract_version=2 → nonzero"
else bad "contract_version=2 → nonzero"; fi

# contract_version missing (from done-state).
cat > "$TMP/nover.json" <<'JSON'
{"session_id":"s","verified_sha":"h","tree_clean":true,"dod":{"sources":[],"items":[]},"tests":{"exit_code":0},"task_checks":[]}
JSON
if ! vok "$CONTRACTS/done-state.schema.json" "$TMP/nover.json"; then
  ok "contract_version missing → nonzero"
else bad "contract_version missing → nonzero"; fi

# required field missing (reviewed_sha dropped).
cat > "$TMP/noreq.json" <<'JSON'
{"contract_version":1,"min_review_level":"high","files_reviewed":[],"findings":[]}
JSON
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/noreq.json"; then
  ok "required reviewed_sha missing → nonzero"
else bad "required reviewed_sha missing → nonzero"; fi

# enum out of set.
cat > "$TMP/badenum.json" <<'JSON'
{"contract_version":1,"reviewed_sha":"a","min_review_level":"wrong","files_reviewed":[],"findings":[]}
JSON
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/badenum.json"; then
  ok "min_review_level=wrong (enum) → nonzero"
else bad "min_review_level=wrong (enum) → nonzero"; fi

# type mismatch: findings as an OBJECT not array.
cat > "$TMP/badtype.json" <<'JSON'
{"contract_version":1,"reviewed_sha":"a","min_review_level":"high","files_reviewed":[],"findings":{}}
JSON
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/badtype.json"; then
  ok "findings as object (type) → nonzero"
else bad "findings as object (type) → nonzero"; fi

# findings ELEMENT missing severity.
cat > "$TMP/badelem.json" <<'JSON'
{"contract_version":1,"reviewed_sha":"a","min_review_level":"high","files_reviewed":[],"findings":[{"file":"a","line":1,"desc":"d"}]}
JSON
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/badelem.json"; then
  ok "findings element missing severity → nonzero"
else bad "findings element missing severity → nonzero"; fi

# --- additionalProperties:false ---------------------------------------------
cat > "$TMP/strict.schema.json" <<'JSON'
{"type":"object","additionalProperties":false,"required":["contract_version"],"properties":{"contract_version":{"const":1},"a":{"type":"string"}}}
JSON
cat > "$TMP/strict_bad.json" <<'JSON'
{"contract_version":1,"a":"hi","b":"extra"}
JSON
cat > "$TMP/strict_ok.json" <<'JSON'
{"contract_version":1,"a":"hi"}
JSON
if ! vok "$TMP/strict.schema.json" "$TMP/strict_bad.json"; then
  ok "additionalProperties:false + extra key → nonzero"
else bad "additionalProperties:false + extra key → nonzero"; fi
if vok "$TMP/strict.schema.json" "$TMP/strict_ok.json"; then
  ok "additionalProperties:false + only allowed keys → 0"
else bad "additionalProperties:false + only allowed keys → 0"; fi

# --- jq-missing fail-closed path --------------------------------------------
# Strip jq from PATH in a subshell so the rest of the suite is unaffected.
# command -v jq fails → hc_validate prints "ERR: jq unavailable" and returns 1.
( PATH="/nonexistent" hc_validate "$CONTRACTS/review-log.schema.json" "$TMP/review-log.json" >/dev/null 2>&1 )
if [ "$?" -ne 0 ]; then
  ok "jq-missing path → nonzero (fail-closed)"
else bad "jq-missing path → nonzero (fail-closed)"; fi

# --- C1 regression: fractional numbers must NOT pass as integers ------------
# review-log with a findings element whose line is 3.5 (fractional) → nonzero.
cat > "$TMP/frac-line.json" <<'JSON'
{"contract_version":1,"reviewed_sha":"a","min_review_level":"high","files_reviewed":[],"findings":[{"severity":"low","file":"a","line":3.5,"desc":"d"}]}
JSON
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/frac-line.json"; then
  ok "findings line=3.5 (fractional integer) → nonzero"
else bad "findings line=3.5 (fractional integer) → nonzero"; fi

# done-config with max_fix_attempts=2.5 (fractional) → nonzero.
cat > "$TMP/frac-cfg.json" <<'JSON'
{"contract_version":1,"detected":{},"overrides":{},"max_fix_attempts":2.5,"max_review_rounds":2,"baseline_snapshot":true,"start_timeout":30,"untracked_policy":"baseline","min_review_level":"high","auto_branch":true,"branch_prefix":"task/"}
JSON
if ! vok "$CONTRACTS/done-config.schema.json" "$TMP/frac-cfg.json"; then
  ok "max_fix_attempts=2.5 (fractional integer) → nonzero"
else bad "max_fix_attempts=2.5 (fractional integer) → nonzero"; fi

# whole-number integer still accepted: findings line=3 → 0.
cat > "$TMP/int-line.json" <<'JSON'
{"contract_version":1,"reviewed_sha":"a","min_review_level":"high","files_reviewed":[],"findings":[{"severity":"low","file":"a","line":3,"desc":"d"}]}
JSON
if vok "$CONTRACTS/review-log.schema.json" "$TMP/int-line.json"; then
  ok "findings line=3 (whole integer) → 0"
else bad "findings line=3 (whole integer) → 0"; fi

# --- H1 regression: top-level null/false valid against a nullable union -----
cat > "$TMP/nullable.schema.json" <<'JSON'
{"type":["string","null"]}
JSON
cat > "$TMP/null-inst.json" <<'JSON'
null
JSON
if vok "$TMP/nullable.schema.json" "$TMP/null-inst.json"; then
  ok "top-level null vs [string,null] → 0"
else bad "top-level null vs [string,null] → 0"; fi

cat > "$TMP/str-inst.json" <<'JSON'
"hello"
JSON
if vok "$TMP/nullable.schema.json" "$TMP/str-inst.json"; then
  ok "top-level string vs [string,null] → 0"
else bad "top-level string vs [string,null] → 0"; fi

cat > "$TMP/num-inst.json" <<'JSON'
5
JSON
if ! vok "$TMP/nullable.schema.json" "$TMP/num-inst.json"; then
  ok "top-level number vs [string,null] → nonzero"
else bad "top-level number vs [string,null] → nonzero"; fi

# --- nullable field positive: done-state escalation:null → 0 ----------------
cat > "$TMP/done-state-null-esc.json" <<'JSON'
{"contract_version":1,"session_id":"s","verified_sha":"h","tree_clean":true,"dod":{"sources":["base-dod.md"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[],"escalation":null}
JSON
if vok "$CONTRACTS/done-state.schema.json" "$TMP/done-state-null-esc.json"; then
  ok "done-state escalation:null → 0"
else bad "done-state escalation:null → 0"; fi

# --- additionalProperties absent (default true) allows extra keys → 0 -------
cat > "$TMP/lax.schema.json" <<'JSON'
{"type":"object","required":["contract_version"],"properties":{"contract_version":{"const":1},"a":{"type":"string"}}}
JSON
cat > "$TMP/lax_extra.json" <<'JSON'
{"contract_version":1,"a":"hi","b":"extra"}
JSON
if vok "$TMP/lax.schema.json" "$TMP/lax_extra.json"; then
  ok "additionalProperties absent (default true) + extra key → 0"
else bad "additionalProperties absent (default true) + extra key → 0"; fi

# --- fail-closed: empty / whitespace / multi-doc must NOT validate ----------
# Regression for the fail-OPEN hole where `jq .` over an empty instance exits 0
# and the validator body ran over no input → printed OK. Each must be rejected
# (nonzero), in BOTH instance and schema position.
: > "$TMP/empty.json"
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/empty.json"; then
  ok "empty instance file → nonzero (no fail-open)"
else bad "empty instance file → nonzero (no fail-open)"; fi

printf '   \n\t\n' > "$TMP/ws.json"
if ! vok "$CONTRACTS/review-log.schema.json" "$TMP/ws.json"; then
  ok "whitespace-only instance → nonzero (no fail-open)"
else bad "whitespace-only instance → nonzero (no fail-open)"; fi

printf '{"contract_version":1}\n{"contract_version":1}\n' > "$TMP/multi.json"
if ! vok "$TMP/lax.schema.json" "$TMP/multi.json"; then
  ok "multi-document instance → nonzero"
else bad "multi-document instance → nonzero"; fi

: > "$TMP/empty-schema.json"
cat > "$TMP/anything.json" <<'JSON'
{"whatever":true}
JSON
if ! vok "$TMP/empty-schema.json" "$TMP/anything.json"; then
  ok "empty schema file → nonzero (no fail-open)"
else bad "empty schema file → nonzero (no fail-open)"; fi

echo
echo "test-contracts: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
