#!/bin/bash
#
# task-DoD plugin — dod-verify Step 7: write the verification result.
#
# Same git-facts-injection discipline as done-write-state.sh (never trust an
# agent-supplied SHA, refuse a dirty tree), but the target shape here is
# task-dod/verified/<task_key>-<verified_sha>.json's results[] array (per
# contracts/task-dod-verified.schema.json), not a done-state blob — because
# dod-verify checks a CONTRACT (task-dod/<task_key>.json) collected upstream by
# dod-collect, not an ad-hoc DoD assembled at verify time.
#
# Usage: dod-verify-write-result.sh [session_id] < payload.json
#   payload (stdin): {"results": [{"requirement_index":0,"status":"pass|fail|skipped","evidence":"..."}]}
#   session_id: optional; else resolved from the current-session marker /
#               newest baselines/*.sha, same precedence as dod-write.sh.
#
# Reads task-dod/<task_key>.json to know how many requirement_index entries to
# expect; refuses to write if the payload's indices don't match the current
# contract's requirements[] length (index set must be exactly 0..N-1, no gaps,
# no dupes, no out-of-range).
#
# Fail-safe reads (guarded), but this script INTENTIONALLY exits nonzero on
# real failure modes (bad payload, no contract on file, index mismatch, dirty
# tree) — the caller must know it did not record a result.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

die() { printf 'dod-verify-write-result: %s\n' "$1" >&2; exit "${2:-1}"; }

hc_has_jq || die "jq is required" 3
hc_has_fn hc_resolve || die "harness-common.sh did not load" 3

# --- read + validate the payload ---------------------------------------------
PAYLOAD=$(cat 2>/dev/null)
[ -n "$PAYLOAD" ] || die "no JSON payload on stdin (supply {\"results\":[...]})"
printf '%s' "$PAYLOAD" | jq empty >/dev/null 2>&1 || die "stdin payload is not valid JSON"

# --- resolve session id (same precedence as dod-write.sh) --------------------
SESSION_ID="${1:-}"
if [ -z "$SESSION_ID" ] && [ -f "$PROJECT_DIR/.claude/.harness/current-session" ]; then
  SESSION_ID=$(cat "$PROJECT_DIR/.claude/.harness/current-session" 2>/dev/null)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -t "$PROJECT_DIR"/.claude/.harness/baselines/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//')
fi
[ -n "$SESSION_ID" ] || SESSION_ID="${DOD_SESSION_ID:-unknown-session}"

hc_resolve "$SESSION_ID" 2>/dev/null
[ -n "$HARNESS_DIR" ] || die "could not resolve HARNESS_DIR" 3
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${HC_TASK_KEY}.json"
VERIFIED_DIR="$DOD_DIR/verified"
SCHEMA="$PLUGIN_ROOT/contracts/task-dod-verified.schema.json"

[ -f "$DOD_FILE" ] || die "no task-dod contract on file for ${HC_TASK_KEY} — run dod-collect first" 3

# --- inject live git facts ----------------------------------------------------
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo" 3
VERIFIED_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
[ -n "$VERIFIED_SHA" ] || die "no HEAD — cannot record verification result" 3

# Refuse a dirty tree — same discipline as done-write-state.sh: a verification
# result must not be recorded atop uncommitted changes it did not cover.
if hc_has_fn hc_tree_status; then
  hc_tree_status "$SESSION_ID" 2>/dev/null
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    die "working tree dirty — $(hc_tree_remediation 2>/dev/null); commit before recording the verification result"
  fi
else
  GIT_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
  [ -z "$GIT_STATUS" ] || die "working tree dirty — commit before recording the verification result"
fi

# --- index-matching refusal: payload results[] must exactly cover 0..N-1 ----
CONTRACT_COUNT=$(jq '.requirements | length' "$DOD_FILE" 2>/dev/null)
case "$CONTRACT_COUNT" in ''|*[!0-9]*) die "could not read requirements[] length from ${DOD_FILE}" 3 ;; esac

RESULTS=$(printf '%s' "$PAYLOAD" | jq -c '.results // empty' 2>/dev/null)
[ -n "$RESULTS" ] || die "payload missing non-empty 'results' array"

RESULT_COUNT=$(printf '%s' "$RESULTS" | jq 'length' 2>/dev/null)
if [ "$RESULT_COUNT" != "$CONTRACT_COUNT" ]; then
  die "results[] has ${RESULT_COUNT} entries but the current contract has ${CONTRACT_COUNT} requirements — one result per requirement_index is required, no more, no fewer"
fi

BAD_INDICES=$(printf '%s' "$RESULTS" | jq -r --argjson n "$CONTRACT_COUNT" '
  ([.[].requirement_index] | sort) as $got
  | ([range(0; $n)]) as $want
  | if $got == $want then empty else "index set " + ($got|tostring) + " != expected 0.." + (($n - 1)|tostring) end
' 2>/dev/null)
[ -z "$BAD_INDICES" ] || die "results[] requirement_index set does not match contract: ${BAD_INDICES}"

# --- build + validate the verification result --------------------------------
CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

OUT_JSON=$(jq -n \
  --arg key "$HC_TASK_KEY" \
  --arg sha "$VERIFIED_SHA" \
  --arg at "$CHECKED_AT" \
  --argjson results "$RESULTS" '
  { task_key: $key, verified_sha: $sha, checked_at: $at, results: $results }
' 2>/dev/null)
[ -n "$OUT_JSON" ] || die "failed to assemble verification result JSON" 3

TMP_OUT=$(mktemp 2>/dev/null) || die "mktemp failed" 3
trap 'rm -f "$TMP_OUT"' EXIT
printf '%s' "$OUT_JSON" > "$TMP_OUT"
if hc_has_fn hc_validate; then
  ERR=$(hc_validate "$SCHEMA" "$TMP_OUT" 2>&1) || die "assembled result fails task-dod-verified.schema.json: $ERR"
else
  die "hc_validate unavailable" 3
fi

mkdir -p "$VERIFIED_DIR" 2>/dev/null
VERIFIED_RESULT="$VERIFIED_DIR/${HC_TASK_KEY}-${VERIFIED_SHA}.json"
printf '%s' "$OUT_JSON" | jq -S . > "$VERIFIED_RESULT" 2>/dev/null || die "write failed"
printf '%s\n' "$VERIFIED_RESULT"
exit 0
