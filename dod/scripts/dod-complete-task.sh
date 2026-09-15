#!/bin/bash
#
# task-DoD plugin — the completion CLAIM (latch arming).
#
#   dod-complete-task.sh [session_id]
#
# The agent runs this to declare "I am finished". It records the claim and
# nothing else. It is DELIBERATELY DUMB and must NEVER grow a check: the
# moment a claim script can also clear something, an agent that runs it has
# bought itself a pass.
#
# THE ASYMMETRY RULE (governs the whole mechanism): an agent-authored signal
# may only make the Stop gate STRICTER, never looser. Arming this latch clears
# NOTHING. Skipping it buys NOTHING — without a latch the gate is merely
# silent, and the agent is still not verified.
#
# The latch is $HARNESS_DIR/task-dod/claim-<task_key>. Its EXISTENCE is the
# whole signal; the content (armed-at UTC + HEAD sha) is a hint for a human
# reading the state dir. Exactly two things disarm it:
#   1. dod-gate.sh, when verification genuinely covers the changeset, and
#   2. dod-user-turn.sh (UserPromptSubmit) — the user taking the turn back.
#      That is a USER-authored signal, which is why it is allowed to relax.
#
# Only the ORCHESTRATOR runs dod. Subagents run none of it, so this script is
# never invoked from a subagent turn (Stop does not fire for subagents and
# UserPromptSubmit only fires on real user turns).
#
# Exit: 0 once the latch is on disk. NONZERO only if the latch could not be
# written — the caller must know the claim was not recorded. No `set -e`; every
# git call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=harness-common.sh
if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi

die() { printf 'dod-complete-task: %s\n' "$1" >&2; exit "${2:-1}"; }

hc_has_fn hc_resolve || die "harness-common.sh did not load" 3

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

# HC_TASK_KEY is UNSANITISED in session mode (it is "session-<session_id>", and
# the session id comes from hook stdin / an agent-writable marker file), so it
# is sanitised HERE before it becomes a path component. Task mode already
# sanitises the branch name inside hc_resolve; sanitising twice is idempotent.
if hc_has_fn hc__sanitize; then
  TASK_KEY=$(hc__sanitize "$HC_TASK_KEY")
else
  TASK_KEY=$(printf '%s' "$HC_TASK_KEY" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null)
fi
[ -n "$TASK_KEY" ] || die "could not derive a safe task key" 3

DOD_DIR="$HARNESS_DIR/task-dod"
LATCH="$DOD_DIR/claim-${TASK_KEY}"

mkdir -p "$DOD_DIR" 2>/dev/null || die "could not create $DOD_DIR"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse -q --verify HEAD 2>/dev/null)
[ -n "$HEAD_SHA" ] || HEAD_SHA="no-head"

printf 'armed_at=%s\nhead=%s\n' "$NOW" "$HEAD_SHA" > "$LATCH" 2>/dev/null \
  || die "could not write the claim latch: $LATCH"
[ -f "$LATCH" ] || die "claim latch missing after write: $LATCH"

printf 'task-dod: completion claim recorded (%s).\n' "$LATCH"
printf 'task-dod: this claim clears NOTHING by itself — now run the dod-verify skill; the Stop gate stays blocked until a verification result covers this changeset.\n'

exit 0
