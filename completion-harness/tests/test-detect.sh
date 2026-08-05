#!/bin/bash
#
# Tests for done-detect.sh (Step 0 config detection).
# Runs in a throwaway tmpdir Node project so it never mutates the trial's
# checked-in .claude/done-config.json.

SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/done-detect.sh"
PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/.claude"

cat > "$TMP/package.json" <<'JSON'
{
  "name": "detect-fixture",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --test",
    "start": "node src/index.js"
  }
}
JSON

export CLAUDE_PROJECT_DIR="$TMP"
CONFIG="$TMP/.claude/done-config.json"

echo "== test-detect =="

# --- 1. first run detects commands + writes config --------------------------
OUT1=$(bash "$SCRIPT")
if echo "$OUT1" | jq -e '.test == "npm run test"' >/dev/null 2>&1; then
  ok "detects test command (npm run test) in effective stdout"
else
  bad "test command not detected; got: $OUT1"
fi
if echo "$OUT1" | jq -e '.start == "npm run start"' >/dev/null 2>&1; then
  ok "detects start command (npm run start)"
else
  bad "start command not detected; got: $OUT1"
fi
if [ -f "$CONFIG" ]; then
  ok "wrote done-config.json"
else
  bad "done-config.json not written"
fi
if jq -e '.source_fingerprint != null and .source_fingerprint != ""' "$CONFIG" >/dev/null 2>&1; then
  ok "config has a source_fingerprint"
else
  bad "config missing source_fingerprint"
fi
# sticky defaults seeded on a fresh file
if jq -e '.max_fix_attempts == 3 and .baseline_snapshot == true and (.overrides == {})' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded sticky defaults (max_fix_attempts/baseline_snapshot/overrides)"
else
  bad "sticky defaults not seeded correctly"
fi
# identity keys seeded on a fresh file: trunk (null → resolver auto-detects),
# auto_branch (FALSE — opt-in, so a fresh repo never silently moves off the
# branch the user chose), branch_prefix ("task/"). has() proves the key is
# present (== null alone would also be true for an ABSENT key, so use has()).
if jq -e 'has("trunk") and .trunk == null and has("auto_branch") and .auto_branch == false and .branch_prefix == "task/"' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded identity keys (trunk=null, auto_branch=false, branch_prefix=task/)"
else
  bad "identity keys not seeded correctly; got: $(jq -c '{trunk,auto_branch,branch_prefix}' "$CONFIG" 2>/dev/null)"
fi
# untracked_policy sticky key seeded with the baseline default.
if jq -e 'has("untracked_policy") and .untracked_policy == "baseline"' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded untracked_policy = baseline (default)"
else
  bad "untracked_policy not seeded correctly; got: $(jq -c '{untracked_policy}' "$CONFIG" 2>/dev/null)"
fi
# max_review_rounds sticky key seeded with the default (2).
if jq -e 'has("max_review_rounds") and .max_review_rounds == 2' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded max_review_rounds = 2 (default)"
else
  bad "max_review_rounds not seeded correctly; got: $(jq -c '{max_review_rounds}' "$CONFIG" 2>/dev/null)"
fi
# min_review_level sticky key seeded with the default ("high").
if jq -e 'has("min_review_level") and .min_review_level == "high"' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded min_review_level = high (default)"
else
  bad "min_review_level not seeded correctly; got: $(jq -c '{min_review_level}' "$CONFIG" 2>/dev/null)"
fi
# noncode_globs sticky key seeded with the conservative default set (#5). has()
# proves presence; the spot-checks prove the prose/docs/image defaults landed.
if jq -e 'has("noncode_globs") and (.noncode_globs | index("*.md")) != null and (.noncode_globs | index("*.png")) != null and (.noncode_globs | index("LICENSE")) != null' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded noncode_globs = default set (contains *.md, *.png, LICENSE)"
else
  bad "noncode_globs not seeded correctly; got: $(jq -c '{noncode_globs}' "$CONFIG" 2>/dev/null)"
fi
# start_check_cmd sticky key seeded null (default — safe: no readiness probe until
# a human sets one). has() proves the key is present (== null alone would also be
# true for an ABSENT key).
if jq -e 'has("start_check_cmd") and .start_check_cmd == null' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded start_check_cmd = null (default)"
else
  bad "start_check_cmd not seeded correctly; got: $(jq -c '{start_check_cmd}' "$CONFIG" 2>/dev/null)"
fi
# start_timeout sticky key seeded with the default (30 seconds).
if jq -e 'has("start_timeout") and .start_timeout == 30' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded start_timeout = 30 (default)"
else
  bad "start_timeout not seeded correctly; got: $(jq -c '{start_timeout}' "$CONFIG" 2>/dev/null)"
fi
# contract_version stamp: a freshly seeded config declares schema v1 as a number.
if jq -e '.contract_version == 1' "$CONFIG" >/dev/null 2>&1; then
  ok "seeded contract_version == 1"
else
  bad "contract_version not stamped; got: $(jq -c '{contract_version}' "$CONFIG" 2>/dev/null)"
fi
# The seeded config VALIDATES against the shipped done-config contract. Use
# hc_validate + HC_CONTRACTS_DIR from the source harness-common.sh (resolves its
# sibling contracts/ via BASH_SOURCE).
HC_COMMON="$(cd "$(dirname "$0")/../scripts" && pwd)/harness-common.sh"
if [ -f "$HC_COMMON" ]; then
  # shellcheck source=/dev/null
  . "$HC_COMMON" 2>/dev/null
fi
if type hc_validate >/dev/null 2>&1 && hc_validate "$HC_CONTRACTS_DIR/done-config.schema.json" "$CONFIG" >/dev/null 2>&1; then
  ok "seeded config validates against done-config contract"
else
  bad "seeded config failed contract validation: $(hc_validate "$HC_CONTRACTS_DIR/done-config.schema.json" "$CONFIG" 2>&1)"
fi

# --- 2. idempotent: second run does not change the file ---------------------
# The config already carries contract_version == 1 from the seed, so a second run
# (unchanged fingerprint, already at v1) must be a no-op — byte-identical.
BEFORE=$(cat "$CONFIG")
FP_BEFORE=$(jq -r '.source_fingerprint' "$CONFIG")
bash "$SCRIPT" >/dev/null
AFTER=$(cat "$CONFIG")
if [ "$BEFORE" = "$AFTER" ]; then
  ok "idempotent — second run left config byte-identical (contract_version present)"
else
  bad "second run altered config (not idempotent)"
  diff <(printf '%s' "$BEFORE") <(printf '%s' "$AFTER")
fi

# --- 3. set an override, then rename a script → fingerprint flips -----------
# add an overrides entry that must survive the re-detect
tmp=$(mktemp); jq '.overrides = {"start": "node server.js"}' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
# also mutate the identity keys away from their defaults to prove the rewrite
# PRESERVES human-owned identity config (including a literal auto_branch=true,
# which is now the NON-DEFAULT value — seeding the default would prove nothing,
# and it is the back-compat promise the flip rests on).
tmp=$(mktemp); jq '.trunk = "develop" | .auto_branch = true | .branch_prefix = "feature/" | .untracked_policy = "strict" | .max_review_rounds = 4 | .min_review_level = "critical" | .start_check_cmd = "curl -sf localhost:3000/health" | .start_timeout = 90' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"

# rename the "test" script to "check" in package.json
cat > "$TMP/package.json" <<'JSON'
{
  "name": "detect-fixture",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "check": "node --test",
    "start": "node src/index.js"
  }
}
JSON

OUT3=$(bash "$SCRIPT")
FP_AFTER=$(jq -r '.source_fingerprint' "$CONFIG")
if [ "$FP_BEFORE" != "$FP_AFTER" ]; then
  ok "script rename flipped the fingerprint"
else
  bad "fingerprint did not change after script rename"
fi
# detected.test should now be gone (renamed to check, which isn't a probed name)
if jq -e '.detected | has("test") | not' "$CONFIG" >/dev/null 2>&1; then
  ok "detected block updated (old 'test' command dropped)"
else
  bad "detected block still has stale test command"
fi
# override must be PRESERVED across the re-detect
if jq -e '.overrides.start == "node server.js"' "$CONFIG" >/dev/null 2>&1; then
  ok "overrides preserved across re-detect"
else
  bad "overrides were clobbered by re-detect"
fi
# identity keys must be PRESERVED across the re-detect — including auto_branch=true,
# the back-compat promise the default flip rests on: a repo seeded true by an
# older install must keep branching until a human says otherwise.
if jq -e '.trunk == "develop" and .auto_branch == true and .branch_prefix == "feature/"' "$CONFIG" >/dev/null 2>&1; then
  ok "identity keys preserved across re-detect (trunk/auto_branch=true/branch_prefix)"
else
  bad "identity keys clobbered by re-detect; got: $(jq -c '{trunk,auto_branch,branch_prefix}' "$CONFIG" 2>/dev/null)"
fi
# untracked_policy (a sticky non-identity key) must survive re-detect too —
# including a non-default literal value.
if jq -e '.untracked_policy == "strict"' "$CONFIG" >/dev/null 2>&1; then
  ok "untracked_policy preserved across re-detect (strict not clobbered)"
else
  bad "untracked_policy clobbered by re-detect; got: $(jq -c '{untracked_policy}' "$CONFIG" 2>/dev/null)"
fi
# max_review_rounds (a sticky non-identity key) must survive re-detect too —
# including a non-default literal value.
if jq -e '.max_review_rounds == 4' "$CONFIG" >/dev/null 2>&1; then
  ok "max_review_rounds preserved across re-detect (4 not clobbered)"
else
  bad "max_review_rounds clobbered by re-detect; got: $(jq -c '{max_review_rounds}' "$CONFIG" 2>/dev/null)"
fi
# min_review_level (a sticky non-identity key) must survive re-detect too —
# including a non-default literal value.
if jq -e '.min_review_level == "critical"' "$CONFIG" >/dev/null 2>&1; then
  ok "min_review_level preserved across re-detect (critical not clobbered)"
else
  bad "min_review_level clobbered by re-detect; got: $(jq -c '{min_review_level}' "$CONFIG" 2>/dev/null)"
fi
# start_check_cmd (a sticky non-identity key) must survive re-detect too —
# including a non-default (non-null) value.
if jq -e '.start_check_cmd == "curl -sf localhost:3000/health"' "$CONFIG" >/dev/null 2>&1; then
  ok "start_check_cmd preserved across re-detect (custom probe not clobbered)"
else
  bad "start_check_cmd clobbered by re-detect; got: $(jq -c '{start_check_cmd}' "$CONFIG" 2>/dev/null)"
fi
# start_timeout (a sticky non-identity key) must survive re-detect too —
# including a non-default literal value.
if jq -e '.start_timeout == 90' "$CONFIG" >/dev/null 2>&1; then
  ok "start_timeout preserved across re-detect (90 not clobbered)"
else
  bad "start_timeout clobbered by re-detect; got: $(jq -c '{start_timeout}' "$CONFIG" 2>/dev/null)"
fi
# effective stdout must reflect override winning over detected
if echo "$OUT3" | jq -e '.start == "node server.js"' >/dev/null 2>&1; then
  ok "effective config: override wins over detected start"
else
  bad "override did not win in effective stdout; got: $OUT3"
fi

# --- 4. AUTO-UPGRADE: an old config (no contract_version) gets stamped -------
# Simulate a pre-contract config: strip contract_version and set human-owned
# fields to custom, non-default values. done-detect must (a) add
# contract_version == 1 and (b) PRESERVE the human-owned fields, even when the
# source fingerprint is unchanged.
tmp=$(mktemp); jq 'del(.contract_version) | .overrides = {"lint": "custom-lint"} | .max_fix_attempts = 7' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
if jq -e 'has("contract_version") | not' "$CONFIG" >/dev/null 2>&1; then
  ok "precondition: simulated old config lacks contract_version"
else
  bad "precondition failed: contract_version still present before upgrade"
fi

bash "$SCRIPT" >/dev/null

if jq -e '.contract_version == 1' "$CONFIG" >/dev/null 2>&1; then
  ok "auto-upgrade stamped contract_version == 1"
else
  bad "auto-upgrade did not stamp contract_version; got: $(jq -c '{contract_version}' "$CONFIG" 2>/dev/null)"
fi
# human-owned overrides must survive the upgrade
if jq -e '.overrides.lint == "custom-lint"' "$CONFIG" >/dev/null 2>&1; then
  ok "auto-upgrade preserved human-owned overrides"
else
  bad "auto-upgrade clobbered overrides; got: $(jq -c '{overrides}' "$CONFIG" 2>/dev/null)"
fi
# human-owned max_fix_attempts must survive the upgrade
if jq -e '.max_fix_attempts == 7' "$CONFIG" >/dev/null 2>&1; then
  ok "auto-upgrade preserved human-owned max_fix_attempts"
else
  bad "auto-upgrade clobbered max_fix_attempts; got: $(jq -c '{max_fix_attempts}' "$CONFIG" 2>/dev/null)"
fi
# the upgraded config must validate against the contract
if type hc_validate >/dev/null 2>&1 && hc_validate "$HC_CONTRACTS_DIR/done-config.schema.json" "$CONFIG" >/dev/null 2>&1; then
  ok "auto-upgraded config validates against done-config contract"
else
  bad "auto-upgraded config failed contract validation: $(hc_validate "$HC_CONTRACTS_DIR/done-config.schema.json" "$CONFIG" 2>&1)"
fi
# idempotent after upgrade: a second run (now at v1, unchanged fingerprint) is a no-op
UP_BEFORE=$(cat "$CONFIG")
bash "$SCRIPT" >/dev/null
UP_AFTER=$(cat "$CONFIG")
if [ "$UP_BEFORE" = "$UP_AFTER" ]; then
  ok "idempotent after auto-upgrade — subsequent run byte-identical"
else
  bad "post-upgrade run altered config (not idempotent)"
  diff <(printf '%s' "$UP_BEFORE") <(printf '%s' "$UP_AFTER")
fi

echo
echo "test-detect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
