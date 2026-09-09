#!/bin/bash
#
# Completion Harness — Bash tool-call hook: session commit ledger.
#
# Wired TWICE, on the same "Bash" matcher, and the mode comes from $1:
#   PreToolUse  → `commit-ledger.sh pre`   pins HEAD into baselines/<sid>.cursor
#   PostToolUse → `commit-ledger.sh`       sweeps CURSOR..HEAD into the ledger
#
# The pair forms a CALL WINDOW. Anything HEAD moved over between pre and post
# happened during an agent tool call, so an agent produced it — that is the
# whole attribution rule, and it is the SINGLE source of truth consumed by
# hc__commit_in_any_ledger / hc__resolve_session_base (harness-common.sh).
#
# WHY OBSERVE HEAD INSTEAD OF READING THE COMMAND: this hook used to gate the
# sweep on a text heuristic over tool_input.command (`*git commit*` &c). That
# missed every indirect commit — inside a shell script, a Makefile target, a
# git alias, `gh pr merge`, a chained one-liner — so real agent commits never
# reached the ledger, were then read as foreign, and got silently skipped by
# the review. HEAD movement cannot be evaded that way.
#
# WHY NOT COMMITTER EMAIL: the human and Claude Code commit under the SAME git
# identity. Email can never separate them, so it was deleted as a signal (see
# hc__commit_in_any_ledger). Absent/empty ledger honestly means "no agent
# commit observed", which is what lets a zero-change session Stop cleanly.
#
# ponytail: ACCEPTED RESIDUAL — a foreign commit that lands DURING the agent's
# own long Bash call (a 3-minute test run, say) is inside the window and gets
# swept in, so it is misattributed as agent work and costs a spurious /done
# demand. Ceiling: every race outcome here is an OVER-block, never a skipped
# review — being missed requires HEAD to move OUTSIDE every call window, which
# is exactly the genuine human/foreign case. Concurrent same-tree sessions are
# already documented as unsupported-racy elsewhere in this codebase. Upgrade
# path if it ever bites: correlate `git reflog HEAD` entries with the call
# window instead of using a bare two-point HEAD diff, or have the agent's own
# commit path stamp the sha directly. Not worth it for an over-block.
#
# Style/guard discipline matches auto-branch.sh: small, guarded everywhere, no
# `set -e`, sources harness-common.sh, uses hc_read_hook_input / hc_resolve,
# and NEVER fails the tool — always exit 0, no stdout, and in `pre` mode never
# any deny/block decision.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-post}"

# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

SESSION_ID=""
if hc_has_fn hc_read_hook_input; then
  hc_read_hook_input
  SESSION_ID="$HC_HOOK_SESSION_ID"
fi
# No session id → no trustworthy filename to write. Leave no file rather than
# guess one: an absent ledger reads as "nothing observed", which is honest.
[ -z "$SESSION_ID" ] && exit 0

# Not a git repo → nothing to ledger.
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Rebase / merge in progress → HEAD is detached and moves repeatedly over
# transient commits; pinning or sweeping them would only dirty the ledger with
# SHAs that vanish when the operation finishes. Same probe shape as
# auto-branch.sh (kept in the SHARED preamble so pre and post cannot diverge on
# it). After the operation completes, the next Bash call pins the cursor at the
# NEW HEAD, so the rewritten commits never enter the ledger at all — and
# hc__resolve_session_base's reachability tripwire then fires on the now-
# unreachable PRE-rebase sha and refuses to advance the base. Over-block,
# never a silent skip.
GIT_DIR=$(git -C "$PROJECT_DIR" rev-parse --git-dir 2>/dev/null)
if [ -n "$GIT_DIR" ]; then
  case "$GIT_DIR" in
    /*) : ;;                       # already absolute
    *)  GIT_DIR="$PROJECT_DIR/$GIT_DIR" ;;
  esac
  if [ -f "$GIT_DIR/MERGE_HEAD" ] || [ -d "$GIT_DIR/rebase-apply" ] || [ -d "$GIT_DIR/rebase-merge" ]; then
    exit 0
  fi
fi

# Task mode's hc__resolve_task_base deliberately never advances past foreign
# commits — "the pinned fork point IS the changeset anchor" (harness-common.sh,
# hc__resolve_task_base comment). The ledger exists to feed base-ADVANCE, which
# only happens in session mode, so task mode has nothing to record into.
if hc_has_fn hc_resolve; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ "$HC_MODE" = "session" ] || exit 0

LEDGER="$HARNESS_DIR/baselines/${SESSION_ID}.own-commits"
CURSOR_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.cursor"
mkdir -p "$HARNESS_DIR/baselines" 2>/dev/null

CURRENT_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)

if [ "$MODE" = "pre" ]; then
  # Ensure the ledger EXISTS even with nothing to record: present-and-empty
  # ("the hook has run, zero agent commits so far") stays a distinct, readable
  # signal from absent ("this hook never ran here") — the same present-vs-
  # missing distinction baseline-snapshot.sh's pin_tree_baseline draws for the
  # .dirty tree baseline.
  [ -f "$LEDGER" ] || : > "$LEDGER" 2>/dev/null
  # Pin the window's lower bound. Whole-file overwrite: the LAST pin wins, so
  # nested/parallel Bash calls narrow the window rather than widening it.
  [ -n "$CURRENT_HEAD" ] && printf '%s\n' "$CURRENT_HEAD" > "$CURSOR_FILE" 2>/dev/null
  exit 0
fi

# --- post: sweep the window --------------------------------------------------
CURSOR=""
[ -f "$CURSOR_FILE" ] && CURSOR=$(cat "$CURSOR_FILE" 2>/dev/null)
# No pin → the PreToolUse hook never fired for this call (an older install that
# only wired PostToolUse, or the tool call was denied before `pre` ran). Fall
# back to the SessionStart-pinned baseline: over-including costs a spurious
# review demand, under-including silently skips one, so over-include.
if [ -z "$CURSOR" ]; then
  SHA_BASELINE="$HARNESS_DIR/baselines/${SESSION_ID}.sha"
  [ -f "$SHA_BASELINE" ] && CURSOR=$(cat "$SHA_BASELINE" 2>/dev/null)
fi
# Still no anchor → nothing safe to diff from. Never guess an attribution.
[ -z "$CURSOR" ] && exit 0
[ -z "$CURRENT_HEAD" ] && exit 0
# HEAD did not move during the call → hot path, nothing to do.
[ "$CURRENT_HEAD" = "$CURSOR" ] && exit 0

# `rev-list CURSOR..HEAD` over a rewritten history (amend/rebase inside the
# window) yields exactly the rewritten commits — which the agent's own rewrite
# authored, so claiming them is correct. No ancestor check is needed: unlike the
# old ledger-tail cursor, an externally pinned per-call cursor has no feedback
# loop, so one orphaned sha cannot poison later calls.
#
# Dedupe against what the ledger already holds — two Bash calls running in
# parallel in one session can both sweep the same commit.
git -C "$PROJECT_DIR" rev-list --reverse "$CURSOR..$CURRENT_HEAD" 2>/dev/null \
| while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    grep -qxF -- "$sha" "$LEDGER" 2>/dev/null && continue
    printf '%s\n' "$sha" >> "$LEDGER" 2>/dev/null
  done

exit 0
