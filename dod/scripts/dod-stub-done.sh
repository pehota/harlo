#!/bin/bash
#
# task-DoD plugin — the STUB /done.
#
# A stand-in for the real Definition-of-Done checklist. The real /done —
# config detect, tests with a before/after checkpoint, app startup,
# task_checks, a fresh-agent changeset review, fix loop — is DELIBERATELY OUT
# OF SCOPE here: the expensive middle already works elsewhere and is not what
# this plugin proves. What IS being proven is the lifecycle around it:
# nudge -> write task DoD -> block at Stop -> unblock -> archive at verified_sha.
#
# All this does: write .claude/.harness/task-dod/.stub-done-<task_key>, whose
# content is `git rev-parse HEAD`. dod-gate.sh treats that marker's presence as
# "the model ran /done"; the test suite invokes this to simulate that step.
#
# Exit 0 on success (marker path printed). Nonzero + reason on stderr otherwise.
# No `set -e`; every git call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi

die() { printf 'dod-stub-done: %s\n' "$1" >&2; exit "${2:-1}"; }

hc_has_fn hc_resolve || die "harness-common.sh did not load" 3

SESSION_ID="${1:-${DOD_SESSION_ID:-unknown-session}}"
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo" 3
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
[ -n "$HEAD_SHA" ] || die "no HEAD" 3

hc_resolve "$SESSION_ID" 2>/dev/null
[ -n "$HARNESS_DIR" ] || die "could not resolve HARNESS_DIR" 3
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$HARNESS_DIR/task-dod"
STUB_MARKER="$DOD_DIR/.stub-done-${HC_TASK_KEY}"

mkdir -p "$DOD_DIR" 2>/dev/null
printf '%s\n' "$HEAD_SHA" > "$STUB_MARKER" 2>/dev/null || die "write failed"
printf '%s\n' "$STUB_MARKER"
exit 0
