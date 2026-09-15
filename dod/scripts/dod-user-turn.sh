#!/bin/bash
#
# task-DoD plugin — UserPromptSubmit hook. "The user took the turn back."
#
# ONE responsibility, two consequences:
#
#   1. DISARM the completion latch (task-dod/claim-<task_key>), unconditionally.
#      A new user prompt means the previous claim of "I am finished" is void.
#      This is the ONLY relaxing signal in the mechanism, and it is allowed to
#      relax precisely because it is USER-authored: the asymmetry rule bars an
#      AGENT-authored signal from ever making the gate looser, but the user
#      taking the turn back is not an agent signal. The disarm happens BEFORE
#      any classification work, so a later failure cannot leave a stale latch
#      armed and trap the user behind a gate they already released.
#
#   2. REMIND, non-blocking, when the changeset carries product-surface work
#      that is not covered by a verification result at HEAD.
#
# There is NO dedup marker, deliberately. The reminder fires on EVERY user turn
# while the condition holds. Ignoring it must buy nothing — a once-per-task
# nudge (dod-nudge.sh's shape) is exactly the thing an agent can outlast.
#
# UserPromptSubmit cannot block, and this hook never tries to. FAIL-SAFE =
# SILENT: missing dependency, no jq, non-git, unresolvable identity → exit 0
# with EMPTY stdout.
#
# Only the ORCHESTRATOR runs dod. UserPromptSubmit fires on real user turns
# only, so subagents never reach this — which is why no SubagentStop hook and
# no PostToolUse hook are registered anywhere in this plugin.
#
# No `set -e`, no catch-all EXIT trap; every git/jq call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

# shellcheck source=harness-common.sh
if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi
# shellcheck source=lib-classify.sh
if [ -f "$PLUGIN_ROOT/scripts/lib-classify.sh" ]; then
  . "$PLUGIN_ROOT/scripts/lib-classify.sh" 2>/dev/null
fi

# No jq → cannot read the hook payload or emit a clean JSON object → silent.
hc_has_jq || exit 0
hc_has_fn hc_read_hook_input || exit 0
hc_has_fn hc_resolve || exit 0

hc_read_hook_input
SESSION_ID="$HC_HOOK_SESSION_ID"
[ -n "$SESSION_ID" ] || SESSION_ID="unknown-session"

# Not a git repo → no changeset, nothing to classify. The latch lives under the
# state dir and is meaningless without a repo, so bail before resolving.
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

hc_resolve "$SESSION_ID" 2>/dev/null
[ -n "$HARNESS_DIR" ] || HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

# HC_TASK_KEY is unsanitised in session mode — sanitise before it is used as a
# path component (same reasoning as dod-complete-task.sh / dod-gate.sh).
if hc_has_fn hc__sanitize; then
  TASK_KEY=$(hc__sanitize "$HC_TASK_KEY")
else
  TASK_KEY=$(printf '%s' "$HC_TASK_KEY" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null)
fi
[ -n "$TASK_KEY" ] || exit 0

DOD_DIR="$HARNESS_DIR/task-dod"

# --- 1. disarm, first and unconditionally -----------------------------------
rm -f "$DOD_DIR/claim-${TASK_KEY}" 2>/dev/null

# --- 2. remind, only when product work is uncovered --------------------------
hc_has_fn dod_changeset_has_product || exit 0
dod_changeset_has_product "$SESSION_ID" 2>/dev/null || exit 0

HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse -q --verify HEAD 2>/dev/null)
if [ -n "$HEAD_SHA" ] && [ -f "$DOD_DIR/verified/${TASK_KEY}-${HEAD_SHA}.json" ]; then
  # Verified AT HEAD. Still only "covered" if the tree carries no product dirt
  # the verification could not have seen — verified-at-HEAD alone would let
  # uncommitted work through. Unavailable classifier → assume covered and stay
  # quiet (fail-safe silent), rather than nagging on an unknown.
  if hc_has_fn dod_tree_has_product; then
    dod_tree_has_product "$SESSION_ID" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi

MSG="[task-dod] This changeset touches product surface and is not covered by a verification result for the current HEAD. When the task is done, run the dod-verify skill — it writes the verification result the Stop gate reads. dod-complete-task.sh records the completion claim; it verifies nothing on its own."

jq -n --arg m "$MSG" '
  {
    systemMessage: $m,
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $m }
  }
' 2>/dev/null || printf '{"systemMessage":"%s"}\n' "$MSG"

exit 0
