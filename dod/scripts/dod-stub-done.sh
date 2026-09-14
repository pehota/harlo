#!/bin/bash
#
# task-DoD plugin — the STUB /done.
#
# A stand-in for the real Definition-of-Done checklist. The real /done —
# config detect, tests with a before/after checkpoint, app startup,
# task_checks, a fresh-agent changeset review, fix loop — is DELIBERATELY OUT
# OF SCOPE here: the expensive middle already works elsewhere and is not what
# this plugin proves. What IS being proven is the lifecycle around it:
# dod-collect writes the task DoD -> block at Stop -> unblock on a passing
# verification result -> archive at HEAD_SHA.
#
# All this does: write a trivially-passing
# .claude/.harness/task-dod/verified/<task_key>-<HEAD_SHA>.json (per
# contracts/task-dod-verified.schema.json), with one "pass" result per
# requirement in the currently-collected task-dod/<task_key>.json.
# dod-gate.sh treats that file's presence (with zero failing entries) as "the
# model ran /done"; the test suite invokes this to simulate that step.
#
# Exit 0 on success (path printed). Nonzero + reason on stderr otherwise.
# No `set -e`; every git/jq call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi

die() { printf 'dod-stub-done: %s\n' "$1" >&2; exit "${2:-1}"; }

hc_has_jq || die "jq is required" 3
hc_has_fn hc_resolve || die "harness-common.sh did not load" 3

SESSION_ID="${1:-${DOD_SESSION_ID:-unknown-session}}"
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repo" 3
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
[ -n "$HEAD_SHA" ] || die "no HEAD" 3

hc_resolve "$SESSION_ID" 2>/dev/null
[ -n "$HARNESS_DIR" ] || die "could not resolve HARNESS_DIR" 3
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${HC_TASK_KEY}.json"
VERIFIED_DIR="$DOD_DIR/verified"
VERIFIED_RESULT="$VERIFIED_DIR/${HC_TASK_KEY}-${HEAD_SHA}.json"

[ -f "$DOD_FILE" ] || die "no task-dod contract on file for ${HC_TASK_KEY} — run dod-collect first" 3

CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)

RESULT=$(jq -n \
  --arg key "$HC_TASK_KEY" \
  --arg sha "$HEAD_SHA" \
  --arg at "$CHECKED_AT" \
  --slurpfile dod <(cat "$DOD_FILE" 2>/dev/null) '
  {
    task_key: $key,
    verified_sha: $sha,
    checked_at: $at,
    results: ($dod[0].requirements | to_entries | map({
      requirement_index: .key,
      status: "pass",
      evidence: "stub-done: simulated pass (no real checklist executed)"
    }))
  }
' 2>/dev/null)
[ -n "$RESULT" ] || die "failed to build verification result" 3

mkdir -p "$VERIFIED_DIR" 2>/dev/null
printf '%s' "$RESULT" | jq -S . > "$VERIFIED_RESULT" 2>/dev/null || die "write failed"
printf '%s\n' "$VERIFIED_RESULT"
exit 0
