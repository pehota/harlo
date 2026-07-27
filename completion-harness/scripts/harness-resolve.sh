#!/bin/bash
#
# Completion Harness — identity resolver wrapper (executable).
#
# Usage: bash harness-resolve.sh <session_id>
#
# Sources harness-common.sh, runs hc_resolve, prints the resolved identity as
# key=value lines. Guarded end-to-end; never crashes.
# No `set -e`.

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

printf 'mode=%s\n'     "$HC_MODE"
printf 'task_key=%s\n' "$HC_TASK_KEY"
printf 'base=%s\n'     "$HC_BASE"
printf 'trunk=%s\n'    "$HC_TRUNK"
printf 'branch=%s\n'   "$HC_BRANCH"
printf 'warn=%s\n'     "$HC_WARN"

exit 0
