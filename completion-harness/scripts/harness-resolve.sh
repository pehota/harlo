#!/bin/bash
#
# Completion Harness — identity resolver wrapper (executable).
#
# Usage: bash harness-resolve.sh <session_id>
#
# Sources harness-common.sh, runs hc_resolve, prints the resolved identity as
# a single schema-validated JSON object (contract: resolver-output.schema.json).
# Self-validates before printing; on validation failure emits an error to stderr
# and exits non-zero rather than printing a malformed object.
# Guarded end-to-end; never crashes. No `set -e`.

SESSION_ID="$1"

SELF_DIR=$(dirname "$0" 2>/dev/null)
[ -z "$SELF_DIR" ] && SELF_DIR="."

# shellcheck source=harness-common.sh
if [ -f "$SELF_DIR/harness-common.sh" ]; then
  . "$SELF_DIR/harness-common.sh" 2>/dev/null
fi

if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi

# Build the resolver-output object with jq so all values are correctly escaped.
# Empty strings stay empty strings (base/trunk/branch/warn may be "").
OUT_JSON=$(jq -n \
  --arg mode     "$HC_MODE" \
  --arg task_key "$HC_TASK_KEY" \
  --arg base     "$HC_BASE" \
  --arg trunk    "$HC_TRUNK" \
  --arg branch   "$HC_BRANCH" \
  --arg warn     "$HC_WARN" \
  '{contract_version:1, mode:$mode, task_key:$task_key, base:$base, trunk:$trunk, branch:$branch, warn:$warn}' \
  2>/dev/null)

if [ -z "$OUT_JSON" ]; then
  printf 'harness-resolve: failed to build resolver output JSON\n' >&2
  exit 1
fi

# SELF-VALIDATE against the resolver-output contract before printing. HC_CONTRACTS_DIR
# is set by harness-common.sh (sourced above). Write to a tempfile, validate, and
# refuse to print a malformed object.
TMP_JSON=$(mktemp 2>/dev/null)
if [ -z "$TMP_JSON" ]; then
  printf 'harness-resolve: mktemp failed\n' >&2
  exit 1
fi
printf '%s\n' "$OUT_JSON" > "$TMP_JSON"

if ! hc_validate "$HC_CONTRACTS_DIR/resolver-output.schema.json" "$TMP_JSON" >/dev/null 2>&1; then
  printf 'harness-resolve: resolver output failed contract validation: %s\n' \
    "$(hc_validate "$HC_CONTRACTS_DIR/resolver-output.schema.json" "$TMP_JSON" 2>&1)" >&2
  rm -f "$TMP_JSON" 2>/dev/null
  exit 1
fi
rm -f "$TMP_JSON" 2>/dev/null

printf '%s\n' "$OUT_JSON"

exit 0
