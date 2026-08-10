#!/bin/bash
#
# ABI CONFORMANCE test for the shared shell library (harness-common.sh).
#
# Turns completion-harness/contracts/shell-abi.json from a static doc into an
# ENFORCED contract: any DRIFT between the declared ABI and the real hc_*
# functions FAILS this suite. Unlike the behavioural suites (test-tree-status,
# test-gate, ...), this one does not re-test logic — it asserts that reality
# matches what the JSON declares:
#   1. EXISTENCE  — every declared name is a real function, and every PUBLIC
#                   hc_* function is declared (a new public fn without an ABI
#                   entry fails).
#   2. GLOBALS    — driven FROM the JSON: each declared global is actually SET
#                   after the function runs (hc_resolve, hc_tree_status).
#   3. SENTINELS  — the declared sentinel strings are really emitted under
#                   crafted conditions (hc_validate, hc_review_blocking,
#                   hc_review_coverage_gap).
#   4. RETURN CODES — the "always 0" functions return 0 even on their
#                   sentinel/degraded paths.
#
# Sources the source-tree harness-common.sh (completion-harness/scripts/) — it
# resolves its sibling contracts/shell-abi.json via BASH_SOURCE, so no install is
# needed. No set -e.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
HC_COMMON="$SCRIPTS/harness-common.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-abi =="

# Hard preconditions: without the library, jq, and the shipped ABI JSON there is
# nothing to enforce — fail loudly rather than silently pass.
if [ ! -f "$HC_COMMON" ]; then
  bad "harness-common.sh missing at $HC_COMMON"
  echo; echo "test-abi: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot read shell-abi.json"
  echo; echo "test-abi: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

# Source the library. This also sets HC_CONTRACTS_DIR (sibling contracts dir),
# which is where the shipped shell-abi.json lives.
# shellcheck source=/dev/null
. "$HC_COMMON" 2>/dev/null

ABI="$HC_CONTRACTS_DIR/shell-abi.json"
if [ ! -f "$ABI" ]; then
  bad "shell-abi.json not found at $ABI (HC_CONTRACTS_DIR=$HC_CONTRACTS_DIR)"
  echo; echo "test-abi: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

# The set of PUBLIC entrypoints. Each MUST have an ABI entry (drift guard: a new
# public hc_* function without a declared contract fails). Private helpers
# (hc__*, double underscore) are intentionally NOT part of the ABI surface.
PUBLIC_FNS="hc_resolve hc_tree_status hc_tree_remediation hc_changeset_summary hc_changeset_is_code hc_review_blocking hc_review_coverage_gap hc_live_task_keys hc_live_review_shas hc_validate hc_state hc_done_state_blocked hc_hash_stdin hc_pkg_probe hc_verification_state hc_is_harness_own_path hc_filter_harness_own hc_cfg hc_path_is_noncode hc_noncode_globs hc_metadata_json_allowlist hc_path_is_metadata_json_safe hc_read_hook_input hc_has_fn hc_die hc_has_jq hc_require_jq"

# ---------------------------------------------------------------------------
# Fixture helpers (throwaway git repo + .harness state, no remote) — same
# pattern as test-identity.sh / test-tree-status.sh.
# ---------------------------------------------------------------------------
CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# Fresh repo on a FEATURE branch off trunk `main` → hc_resolve picks TASK mode.
new_task_repo() {
  REPO=$(hc__test_mktemp_d); CLEANUP+=("$REPO")
  git -C "$REPO" init -q -b main 2>/dev/null || {
    git init "$REPO" >/dev/null 2>&1; ( cd "$REPO" && git branch -M main >/dev/null 2>&1 )
  }
  git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
  git -C "$REPO" config user.name  "Test" >/dev/null 2>&1
  printf '.claude/\n' > "$REPO/.gitignore"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm gitignore >/dev/null 2>&1
  printf 'base\n' > "$REPO/base.txt"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm base >/dev/null 2>&1        # trunk has history
  # confident trunk so a non-trunk branch → TASK mode
  mkdir -p "$REPO/.claude"
  printf '{"trunk":"main"}\n' > "$REPO/.claude/done-config.json"
  git -C "$REPO" checkout -q -b feat/x 2>/dev/null
  printf 'c1\n' > "$REPO/c1.txt"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm c1 >/dev/null 2>&1          # HEAD past fork
}

# ===========================================================================
# 1. EXISTENCE — declared ⇄ defined, in both directions.
# ===========================================================================
echo "-- existence --"

# 1a. Every `name` declared in shell-abi.json is a defined shell function.
DECLARED=$(jq -r '.functions[].name' "$ABI" 2>/dev/null)
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if declare -F "$name" >/dev/null 2>&1; then
    ok "declared '$name' is a defined function"
  else
    bad "declared '$name' is NOT a defined function (ABI names a fn that doesn't exist)"
  fi
done <<EOF
$DECLARED
EOF

# 1b. Every PUBLIC hc_* function defined in the library is declared in the ABI.
#     (A new public function without an ABI entry → drift → fail.) We enumerate
#     the actually-defined public functions and confirm each is in the JSON.
DEFINED_PUBLIC=$(declare -F | awk '{print $3}' | grep -E '^hc_[^_]' 2>/dev/null)
while IFS= read -r fn; do
  [ -z "$fn" ] && continue
  # Only the intended public entrypoints are ABI surface; guard against a
  # stray public helper by cross-checking the known PUBLIC_FNS set too.
  case " $PUBLIC_FNS " in
    *" $fn "*) ;;                                   # a known public entrypoint
    *) bad "defined public function '$fn' is NOT in the known public set (unexpected public surface)"; continue ;;
  esac
  if jq -e --arg n "$fn" '.functions[] | select(.name==$n)' "$ABI" >/dev/null 2>&1; then
    ok "public function '$fn' is declared in shell-abi.json"
  else
    bad "public function '$fn' is NOT declared in shell-abi.json (missing ABI entry)"
  fi
done <<EOF
$DEFINED_PUBLIC
EOF

# 1c. Conversely, each expected public entrypoint really is defined (so the
#     PUBLIC_FNS set itself can't silently rot).
for fn in $PUBLIC_FNS; do
  if declare -F "$fn" >/dev/null 2>&1; then
    ok "expected public entrypoint '$fn' is defined"
  else
    bad "expected public entrypoint '$fn' is NOT defined in the library"
  fi
done

# ===========================================================================
# 2. GLOBALS — driven FROM the JSON `globals[]`, asserted actually SET.
# ===========================================================================
echo "-- globals --"

# is_set <VARNAME> → 0 if the variable is currently set (even if empty value).
is_set() { eval "[ \"\${$1+set}\" = set ]"; }

# 2a. hc_resolve — after a real call in a task-mode fixture, every global its
#     shell-abi globals[] declares must be SET.
new_task_repo
( # subshell so the resolver's globals don't leak into later cases
  cd "$REPO" || exit 1
  CLAUDE_PROJECT_DIR="$REPO" hc_resolve "sid-abi" >/dev/null 2>&1
  RC=$?
  # sanity: we are in the intended mode
  [ "$HC_MODE" = "task" ] || printf 'NOTE: hc_resolve mode=%s (expected task)\n' "$HC_MODE" >&2
  RESOLVE_GLOBALS=$(jq -r '.functions[] | select(.name=="hc_resolve") | .globals[]' "$ABI" 2>/dev/null)
  miss=""
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    if is_set "$g" && declare -p "$g" >/dev/null 2>&1; then
      printf 'SET %s\n' "$g"
    else
      printf 'UNSET %s\n' "$g"
      miss="$miss $g"
    fi
  done <<EOF2
$RESOLVE_GLOBALS
EOF2
  # 4-return-code piggyback: hc_resolve declares "always 0".
  printf 'RC %s\n' "$RC"
  [ -z "$miss" ] && printf 'ALLSET\n' || printf 'MISSING%s\n' "$miss"
) > "$REPO/.abi_resolve.out" 2>/dev/null

# Report each declared hc_resolve global from the subshell trace.
while IFS= read -r ln; do
  case "$ln" in
    "SET "*)    ok "hc_resolve sets declared global ${ln#SET }" ;;
    "UNSET "*)  bad "hc_resolve does NOT set declared global ${ln#UNSET } (ABI drift)" ;;
    "RC "*)     if [ "${ln#RC }" = "0" ]; then ok "hc_resolve returns 0 (matches declared 'always 0')"; else bad "hc_resolve returned ${ln#RC } (declared always 0)"; fi ;;
  esac
done < "$REPO/.abi_resolve.out"

# 2b. hc_tree_status — after hc_resolve, its declared globals (HC_TREE_BLOCKERS /
#     HC_TREE_WARNINGS) must be SET even when empty.
(
  cd "$REPO" || exit 1
  CLAUDE_PROJECT_DIR="$REPO" hc_resolve "sid-abi" >/dev/null 2>&1
  CLAUDE_PROJECT_DIR="$REPO" hc_tree_status "sid-abi" >/dev/null 2>&1
  RC=$?
  TS_GLOBALS=$(jq -r '.functions[] | select(.name=="hc_tree_status") | .globals[]' "$ABI" 2>/dev/null)
  while IFS= read -r g; do
    [ -z "$g" ] && continue
    if is_set "$g" && declare -p "$g" >/dev/null 2>&1; then
      printf 'SET %s\n' "$g"
    else
      printf 'UNSET %s\n' "$g"
    fi
  done <<EOF2
$TS_GLOBALS
EOF2
  printf 'RC %s\n' "$RC"
) > "$REPO/.abi_ts.out" 2>/dev/null

while IFS= read -r ln; do
  case "$ln" in
    "SET "*)   ok "hc_tree_status sets declared global ${ln#SET } (even if empty)" ;;
    "UNSET "*) bad "hc_tree_status does NOT set declared global ${ln#UNSET } (ABI drift)" ;;
    "RC "*)    if [ "${ln#RC }" = "0" ]; then ok "hc_tree_status returns 0 (matches declared 'always 0')"; else bad "hc_tree_status returned ${ln#RC } (declared always 0)"; fi ;;
  esac
done < "$REPO/.abi_ts.out"

# ===========================================================================
# 3. SENTINELS — the declared sentinel strings are really emittable, AND
# 4. RETURN CODES — always-0 functions stay 0 on degraded/sentinel paths.
# ===========================================================================
echo "-- sentinels + return codes --"

# has_sentinel <fn_name> <literal> → 0 if the ABI declares that sentinel for fn.
has_sentinel() {
  jq -e --arg n "$1" --arg s "$2" \
    '.functions[] | select(.name==$n) | .sentinels | index($s) != null' \
    "$ABI" >/dev/null 2>&1
}

# ---- hc_validate: declares sentinels OK and ERR; return_codes "0 valid, 1 invalid".
if has_sentinel hc_validate OK; then
  SCHEMA=$(mktemp); INST=$(mktemp); CLEANUP+=("$SCHEMA" "$INST")
  printf '{"type":"object","required":["a"],"properties":{"a":{"type":"string"}}}\n' > "$SCHEMA"
  printf '{"a":"hello"}\n' > "$INST"
  OUT=$(hc_validate "$SCHEMA" "$INST" 2>/dev/null); RC=$?
  if [ "$OUT" = "OK" ] && [ "$RC" -eq 0 ]; then
    ok "hc_validate emits declared sentinel 'OK' rc0 on valid input"
  else
    bad "hc_validate did not emit 'OK' rc0 on valid input (out='$OUT' rc=$RC)"
  fi
else
  bad "shell-abi.json does not declare sentinel 'OK' for hc_validate (drift: fn emits it)"
fi

if has_sentinel hc_validate ERR; then
  SCHEMA=$(mktemp); INST=$(mktemp); CLEANUP+=("$SCHEMA" "$INST")
  printf '{"type":"object","required":["a"],"properties":{"a":{"type":"string"}}}\n' > "$SCHEMA"
  printf '{"a":123}\n' > "$INST"                     # a is a number, not string → invalid
  OUT=$(hc_validate "$SCHEMA" "$INST" 2>/dev/null); RC=$?
  case "$OUT" in
    ERR*) if [ "$RC" -eq 1 ]; then
            ok "hc_validate emits declared sentinel 'ERR...' rc1 on malformed input"
          else
            bad "hc_validate emitted ERR but rc=$RC (declared 1 invalid)"
          fi ;;
    *) bad "hc_validate did not emit 'ERR...' on invalid input (out='$OUT' rc=$RC)" ;;
  esac
else
  bad "shell-abi.json does not declare sentinel 'ERR' for hc_validate (drift: fn emits it)"
fi

# ---- hc_review_blocking: declares sentinel ERR; return_codes "always 0".
#      blocking finding → positive integer; malformed/missing → ERR; clean → 0.
RLOG=$(mktemp); CLEANUP+=("$RLOG")

# a) a blocking (high) finding → positive integer, rc0.
printf '{"findings":[{"severity":"high"}]}\n' > "$RLOG"
OUT=$(hc_review_blocking "$RLOG" "high" 2>/dev/null); RC=$?
if printf '%s' "$OUT" | grep -Eq '^[1-9][0-9]*$' && [ "$RC" -eq 0 ]; then
  ok "hc_review_blocking prints positive integer on a blocking finding (rc0)"
else
  bad "hc_review_blocking not a positive integer on blocking finding (out='$OUT' rc=$RC)"
fi

# b) malformed log (findings present but not an array) → ERR, rc0.
if has_sentinel hc_review_blocking ERR; then
  printf '{"findings":{"bogus":true}}\n' > "$RLOG"
  OUT=$(hc_review_blocking "$RLOG" "high" 2>/dev/null); RC=$?
  if [ "$OUT" = "ERR" ] && [ "$RC" -eq 0 ]; then
    ok "hc_review_blocking emits declared sentinel 'ERR' rc0 on malformed log"
  else
    bad "hc_review_blocking did not emit 'ERR' rc0 on malformed log (out='$OUT' rc=$RC)"
  fi
  # missing log path → ERR too.
  OUT=$(hc_review_blocking "$RLOG.does-not-exist" "high" 2>/dev/null); RC=$?
  if [ "$OUT" = "ERR" ] && [ "$RC" -eq 0 ]; then
    ok "hc_review_blocking emits 'ERR' rc0 on missing log"
  else
    bad "hc_review_blocking did not emit 'ERR' rc0 on missing log (out='$OUT' rc=$RC)"
  fi
else
  bad "shell-abi.json does not declare sentinel 'ERR' for hc_review_blocking (drift)"
fi

# c) clean log (empty findings array) → 0, rc0.
printf '{"findings":[]}\n' > "$RLOG"
OUT=$(hc_review_blocking "$RLOG" "high" 2>/dev/null); RC=$?
if [ "$OUT" = "0" ] && [ "$RC" -eq 0 ]; then
  ok "hc_review_blocking prints '0' rc0 on a clean log"
else
  bad "hc_review_blocking did not print '0' rc0 on clean log (out='$OUT' rc=$RC)"
fi

# ---- hc_review_coverage_gap: declares sentinel SKIP; return_codes "always 0".
#      empty base → SKIP; full coverage → empty; changed-but-unreviewed → non-empty.
new_task_repo                                         # fixture with base.txt+c1.txt
BASE=$(git -C "$REPO" merge-base main feat/x 2>/dev/null)
HEAD=$(git -C "$REPO" rev-parse HEAD 2>/dev/null)     # tip has c1.txt over base

# The coverage log lives in a directory the chain is derived from, and must be
# named <sha>.json so it is recognized as a chain-log and its reviewed_sha
# resolves to a real commit for blob-attestation. Place it at
# review-log/<HEAD>.json inside the repo's harness dir.
CLOGDIR="$REPO/.claude/.harness/review-log"
mkdir -p "$CLOGDIR"
CLOG="$CLOGDIR/$HEAD.json"

# a) empty base → SKIP, rc0.
if has_sentinel hc_review_coverage_gap SKIP; then
  printf '{"reviewed_sha":"%s","files_reviewed":[]}\n' "$HEAD" > "$CLOG"
  OUT=$(hc_review_coverage_gap "$CLOG" "" "$HEAD" "$REPO" 2>/dev/null); RC=$?
  if [ "$OUT" = "SKIP" ] && [ "$RC" -eq 0 ]; then
    ok "hc_review_coverage_gap emits declared sentinel 'SKIP' rc0 on empty base"
  else
    bad "hc_review_coverage_gap did not emit 'SKIP' rc0 on empty base (out='$OUT' rc=$RC)"
  fi
else
  bad "shell-abi.json does not declare sentinel 'SKIP' for hc_review_coverage_gap (drift)"
fi

# b) full coverage (files_reviewed lists the whole changeset AT its current blob,
#    reviewed_sha=HEAD so the attested blob == current blob) → empty, rc0.
CHANGED=$(git -C "$REPO" diff --name-only "$BASE" "$HEAD" 2>/dev/null)   # c1.txt
printf '{"reviewed_sha":"%s","files_reviewed":%s}\n' "$HEAD" "$(printf '%s\n' "$CHANGED" | jq -R . | jq -s .)" > "$CLOG"
OUT=$(hc_review_coverage_gap "$CLOG" "$BASE" "$HEAD" "$REPO" 2>/dev/null); RC=$?
if [ -z "$OUT" ] && [ "$RC" -eq 0 ]; then
  ok "hc_review_coverage_gap prints empty (full coverage) rc0"
else
  bad "hc_review_coverage_gap not empty on full coverage (out='$OUT' rc=$RC)"
fi

# c) changed-but-unreviewed file → non-empty gap naming it, rc0.
printf '{"reviewed_sha":"%s","files_reviewed":[]}\n' "$HEAD" > "$CLOG"
OUT=$(hc_review_coverage_gap "$CLOG" "$BASE" "$HEAD" "$REPO" 2>/dev/null); RC=$?
if [ -n "$OUT" ] && printf '%s' "$OUT" | grep -q 'c1.txt' && [ "$RC" -eq 0 ]; then
  ok "hc_review_coverage_gap prints non-empty gap (names unreviewed file) rc0"
else
  bad "hc_review_coverage_gap did not report the unreviewed file (out='$OUT' rc=$RC)"
fi

# ---- Return-code closure: hc_resolve was covered in §2a; here confirm the
#      remaining always-0 functions on a plain degraded path also stay rc0
#      (already exercised above per-case, so assert the declared contract text).
for fn in hc_tree_status hc_review_blocking hc_review_coverage_gap hc_resolve; do
  RCDECL=$(jq -r --arg n "$fn" '.functions[] | select(.name==$n) | .return_codes' "$ABI" 2>/dev/null)
  case "$RCDECL" in
    *"always 0"*) ok "hc_* '$fn' declares 'always 0' return code (asserted 0 on its paths above)" ;;
    *) bad "expected '$fn' to declare 'always 0' return code, got '$RCDECL'" ;;
  esac
done

echo
echo "test-abi: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
