#!/bin/bash
#
# task-DoD plugin — UserPromptSubmit hook. ONE responsibility: the REMINDER.
#
# It reminds, non-blocking, when the changeset carries product-surface work
# that is not covered by a verification result at HEAD.
#
# IT NO LONGER DISARMS THE CLAIM LATCH, and that removal is the point.
#
#   The latch used to be cleared here on the theory that UserPromptSubmit means
#   "the user took the turn back" — a USER-authored signal, and therefore the
#   one signal the asymmetry rule permits to relax the gate. That theory is
#   FALSE. UserPromptSubmit also fires on subagent hand-backs, on background
#   task notifications and on cross-session messages. Captured payloads
#   (dod-log/payloads/) show the full field set — session_id, transcript_path,
#   cwd, scratchpad_dir, prompt_id, permission_mode, hook_event_name, prompt —
#   and NOTHING in it marks origin. prompt_id was investigated and rejected:
#   the transcript mints a distinct prompt_id for every injected turn,
#   automated ones included. The only signal is the SHAPE of the prompt string.
#
#   So a subagent hand-back silently disarmed the latch: an AGENT-triggered
#   relaxation of the gate, i.e. a direct asymmetry violation and a Stop bypass.
#
#   Now exactly ONE thing clears the latch: dod-gate.sh on its covered path (a
#   verification result for HEAD *and* no product-surface tree dirt). There is
#   no origin detection anywhere on the gating path, so there is no fail-open
#   hole to get wrong.
#
# THIS DOES NOT TRAP THE AGENT. dod-gate.sh's block() carries a CATEGORY-SCOPED
# recursion brake that releases on the second Stop of a cycle. A latch that
# persists therefore yields ONE block per turn-end cycle, then release — it can
# never hold the agent, or the user, hostage.
#
# Consequences of the persistent latch, accepted deliberately:
#   * It survives across turns, and in TASK mode across sessions on the same
#     branch. In SESSION mode the task key is "session-<session_id>", so a new
#     session mints a new key and ORPHANS the old latch. Orphaned latches
#     accumulate under task-dod/. No reaper — out of scope; they are inert
#     files keyed to a task key nothing will ever resolve to again.
#   * A claimed task abandoned without verification blocks once per turn-end
#     until it is verified or the latch file is removed by hand. That is the
#     accepted cost of having no agent-reachable release. The manual escape is
#     documented in README.md for a HUMAN; it is deliberately not offered to
#     the agent as remedy text.
#
# There is NO dedup marker on the reminder, deliberately. It fires on EVERY
# human turn while the condition holds. Ignoring it must buy nothing — a
# once-per-task nudge is exactly the thing an agent can outlast.
#
# UserPromptSubmit cannot block, and this hook never tries to. FAIL-SAFE =
# SILENT: missing dependency, no jq, non-git, unresolvable identity → exit 0
# with EMPTY stdout.
#
# Only the ORCHESTRATOR runs dod: no SubagentStop hook and no PostToolUse hook
# is registered anywhere in this plugin.
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
# shellcheck source=lib-log.sh
if [ -f "$PLUGIN_ROOT/scripts/lib-log.sh" ]; then
  . "$PLUGIN_ROOT/scripts/lib-log.sh" 2>/dev/null
fi
if ! declare -F dod_log >/dev/null 2>&1; then
  dod_log() { return 0; }
fi

# dod_is_automated_turn <prompt>
#
# True (0) when the prompt is a HARNESS-GENERATED turn rather than a human one.
# Recognised wrappers, all observed in captured payloads:
#   <agent-message ...>                      subagent hand-back
#   <task-notification>                      background task event
#   <cross-session-message ...>              peer session message
#   Another Claude session sent a message:   peer session message, plain form
#
# Matching is lenient: leading whitespace is stripped and the marker only has
# to START the prompt.
#
# *** FAIL DIRECTION IS MANDATORY: anything NOT recognised as automated is
# *** treated as a HUMAN turn, and the reminder FIRES. Never invert this.
# *** The worst case of a false "human" is one extra reminder — a line of
# *** context. The worst case of a false "automated" would be a missing
# *** reminder, which is the direction that quietly weakens the mechanism.
#
# Content sniffing is acceptable HERE, and only here, because this path is
# NON-BLOCKING. The same technique on the gating path would decide whether the
# gate relaxes, where a mis-read fails OPEN and silently voids the gate — which
# is exactly why the disarm was removed rather than made origin-aware.
dod_is_automated_turn() {
  local p="$1"
  # Strip leading whitespace (pure bash; no external call, no failure mode).
  p="${p#"${p%%[![:space:]]*}"}"
  case "$p" in
    '<agent-message'*)                       return 0 ;;
    '<task-notification>'*)                  return 0 ;;
    '<cross-session-message'*)               return 0 ;;
    'Another Claude session sent a message:'*) return 0 ;;
  esac
  return 1
}

# No jq → cannot read the hook payload or emit a clean JSON object → silent.
hc_has_jq || exit 0
hc_has_fn hc_read_hook_input || { dod_log UserPromptSubmit "silent:no-helpers" "hc_read_hook_input missing"; exit 0; }
hc_has_fn hc_resolve || { dod_log UserPromptSubmit "silent:no-helpers" "hc_resolve missing"; exit 0; }

hc_read_hook_input
SESSION_ID="$HC_HOOK_SESSION_ID"
[ -n "$SESSION_ID" ] || SESSION_ID="unknown-session"

# Not a git repo → no changeset, nothing to classify.
git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { dod_log UserPromptSubmit "silent:non-git" "not a work tree"; exit 0; }

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
[ -n "$TASK_KEY" ] || { dod_log UserPromptSubmit "silent:no-task-key" "task key sanitised away"; exit 0; }

DOD_DIR="$HARNESS_DIR/task-dod"

# --- 0. TEMPORARY DIAGNOSTIC: capture the raw payload, BOUNDED ---------------
# Still scaffolding, not a feature. The question it was added to answer — "is
# there a field that separates a human turn from a harness-generated one?" — is
# RESOLVED: there is not. Origin is visible only in the shape of .prompt, which
# is why dod_is_automated_turn above sniffs content and why the gating path no
# longer depends on origin at all.
#
# It is KEPT, capped, for one remaining job: discovering a NEW wrapper type. An
# unrecognised wrapper shows up as a reminder fired on an automated turn, and
# these files are how its exact shape gets read off.
#
# Bounded at the 20 most recent files; everything guarded, because a capping
# failure must never break the hook.
if [ -n "${HC_HOOK_RAW:-}" ]; then
  PAYLOAD_DIR="$HARNESS_DIR/dod-log/payloads"
  if mkdir -p "$PAYLOAD_DIR" 2>/dev/null; then
    PAYLOAD_STAMP=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)
    [ -n "$PAYLOAD_STAMP" ] || PAYLOAD_STAMP="unknown-time"
    printf '%s\n' "$HC_HOOK_RAW" 2>/dev/null > "$PAYLOAD_DIR/${PAYLOAD_STAMP}-$$.json"
    # Reap everything past the 20 newest. `ls -t` is mtime-ordered, so it is
    # correct even for the "unknown-time" filename fallback.
    (
      cd "$PAYLOAD_DIR" 2>/dev/null || exit 0
      ls -1t 2>/dev/null | tail -n +21 | while IFS= read -r stale; do
        [ -n "$stale" ] && rm -f -- "$stale" 2>/dev/null
      done
    ) >/dev/null 2>&1
  fi
fi

# --- 1. skip harness-generated turns ----------------------------------------
# No decision point on an automated turn, so a reminder there is pure noise —
# and noise is what got the reminder tuned out in a real session. Logged, so
# the human:automated ratio is measurable from dod-log/.
PROMPT=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.prompt // ""' 2>/dev/null)
if dod_is_automated_turn "$PROMPT"; then
  dod_log UserPromptSubmit "quiet:automated-turn" "harness-generated turn, no reminder"
  exit 0
fi

# --- 2. remind, only when product work is uncovered --------------------------
hc_has_fn dod_changeset_has_product \
  || { dod_log UserPromptSubmit "silent:no-classifier" "dod_changeset_has_product missing"; exit 0; }
dod_changeset_has_product "$SESSION_ID" 2>/dev/null \
  || { dod_log UserPromptSubmit "quiet" "no uncovered product surface in the changeset"; exit 0; }

HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse -q --verify HEAD 2>/dev/null)
if [ -n "$HEAD_SHA" ] && [ -f "$DOD_DIR/verified/${TASK_KEY}-${HEAD_SHA}.json" ]; then
  # Verified AT HEAD. Still only "covered" if the tree carries no product dirt
  # the verification could not have seen — verified-at-HEAD alone would let
  # uncommitted work through. Unavailable classifier → assume covered and stay
  # quiet (fail-safe silent), rather than nagging on an unknown.
  if hc_has_fn dod_tree_has_product; then
    dod_tree_has_product "$SESSION_ID" 2>/dev/null \
      || { dod_log UserPromptSubmit "quiet" "verified at HEAD, tree clean"; exit 0; }
  else
    dod_log UserPromptSubmit "quiet" "verified at HEAD, classifier unavailable"
    exit 0
  fi
fi

# --- 3. build a STATE-AWARE reminder ----------------------------------------
# The previous reminder was byte-identical on every turn and named
# dod-complete-task.sh only in a trailing caveat about what it does NOT do. Two
# consequences, both observed in a real session: the text was tuned out as
# noise, and nothing ever told the agent to arm the claim — so the Stop gate,
# which is latch-driven, never engaged at all.
#
# Fixed on both counts. The text now (a) names BOTH steps as ordered actions,
# keeping the asymmetry rule as a CLAUSE inside step 1 rather than as the only
# mention of the script, and (b) reports real, cheaply-derived state, so it
# visibly tracks the changeset instead of repeating one sentence. Nothing here
# is fabricated: when the state genuinely has not moved, the text is genuinely
# unchanged.
WHERE="in this changeset"
TREE_DIRT=0
COMMITTED=0
if hc_has_fn dod_tree_has_product && dod_tree_has_product "$SESSION_ID" 2>/dev/null; then
  TREE_DIRT=1
fi
# Committed half: HC_BASE_ORIG..HEAD, the same unadvanced base the classifier
# uses. Skipped entirely unless both ends resolve — this is wording, never a
# gating decision, so an unknown simply falls back to the generic phrase.
if hc_has_fn dod_range_has_product && [ -n "${HC_BASE_ORIG:-}" ] && [ -n "$HEAD_SHA" ] \
   && [ "$HC_BASE_ORIG" != "$HEAD_SHA" ]; then
  dod_range_has_product "$HC_BASE_ORIG" "$HEAD_SHA" 2>/dev/null && COMMITTED=1
fi
if [ "$TREE_DIRT" -eq 1 ] && [ "$COMMITTED" -eq 1 ]; then
  WHERE="committed + uncommitted"
elif [ "$TREE_DIRT" -eq 1 ]; then
  WHERE="uncommitted"
elif [ "$COMMITTED" -eq 1 ]; then
  WHERE="committed"
fi

if [ ! -f "$DOD_DIR/${TASK_KEY}.json" ]; then
  STATE="no DoD recorded yet — run the dod-collect skill first"
elif [ -n "$HEAD_SHA" ] && [ -f "$DOD_DIR/verified/${TASK_KEY}-${HEAD_SHA}.json" ]; then
  # Reachable only via the dirty-tree branch above: verified AT HEAD, but the
  # tree still carries product changes that verification could not have seen.
  STATE="verified at HEAD, but the uncommitted changes are not covered"
elif [ -n "$(ls "$DOD_DIR/verified/${TASK_KEY}-"*.json 2>/dev/null)" ]; then
  STATE="DoD recorded; the only verification result is for an older HEAD"
else
  STATE="DoD recorded, never verified"
fi

MSG="[task-dod] Uncovered product work (${WHERE}); ${STATE}. When done, in order: 1) run \`bash ${PLUGIN_ROOT}/scripts/dod-complete-task.sh\` — records the completion claim (it arms the Stop gate and clears nothing), 2) run the dod-verify skill — its result is the only thing that clears the gate. Orchestrator only; subagents run no dod script."

dod_log UserPromptSubmit "remind" "${WHERE}; ${STATE}"

jq -n --arg m "$MSG" '
  {
    systemMessage: $m,
    hookSpecificOutput: { hookEventName: "UserPromptSubmit", additionalContext: $m }
  }
' 2>/dev/null || printf '{"systemMessage":"%s"}\n' "$MSG"

exit 0
