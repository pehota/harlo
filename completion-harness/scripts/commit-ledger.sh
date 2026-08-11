#!/bin/bash
#
# Completion Harness — PostToolUse(Bash) hook: session commit ledger.
#
# Fires after EVERY Bash call. Job: record, per session, exactly which commit
# SHAs were created via a tool call in THIS session — a positive, directly-
# observed ledger — so hc__resolve_session_base (harness-common.sh) can use
# ledger MEMBERSHIP instead of committer-email as the primary "is this the
# session's own commit" signal for base-advance.
#
# Why membership beats email: email only tells you WHO committed, not WHETHER
# it happened through this session's tool calls. A human committing directly
# (terminal, `!` passthrough) under the SAME git identity Claude Code commits
# under — the common case, there is no separate "Claude" identity — is
# indistinguishable from the session's own work under email alone. That false
# positive is exactly what blocked the Stop gate forever on a foreign commit
# range sharing the session's email. Ledger membership is authoritative
# (we watched the commit happen here); email is a guess and stays only as the
# fallback for sessions that never ran this hook (see harness-common.sh).
#
# Style/guard discipline matches auto-branch.sh: PostToolUse, small, guarded
# everywhere, no `set -e`, sources harness-common.sh, uses hc_read_hook_input /
# hc_resolve, and NEVER fails the tool — always exit 0, no stdout (pure
# bookkeeping; unlike auto-branch.sh this hook has nothing worth telling the
# user about on the happy path).

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

SESSION_ID=""
TOOL_COMMAND=""
if hc_has_fn hc_read_hook_input; then
  hc_read_hook_input
  SESSION_ID="$HC_HOOK_SESSION_ID"
  TOOL_COMMAND="$HC_HOOK_TOOL_COMMAND"
fi
# No session id → no trustworthy ledger filename to write. Leave no file
# rather than guess one; hc__resolve_session_base's fallback (email-based)
# already covers "ledger absent."
[ -z "$SESSION_ID" ] && exit 0

# Not a git repo → nothing to ledger.
if ! git -C "$PROJECT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# --- resolve identity --------------------------------------------------------
# Task mode's hc__resolve_task_base deliberately never advances past foreign
# commits — "the pinned fork point IS the changeset anchor" (harness-common.sh,
# hc__resolve_task_base comment). The ledger exists to feed base-ADVANCE, which
# only happens in session mode, so task mode has nothing to record into.
if hc_has_fn hc_resolve; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ "$HC_MODE" = "session" ] || exit 0

LEDGER="$HARNESS_DIR/baselines/${SESSION_ID}.own-commits"

# Always ensure the ledger file EXISTS, even when there is nothing new to
# append. An empty-but-PRESENT ledger is a meaningful signal ("this session's
# hook has run and owns zero commits so far"), distinct from an ABSENT ledger
# ("this hook has never fired for this session, unknown") — the same
# present-vs-missing distinction baseline-snapshot.sh's pin_tree_baseline draws
# for the .dirty tree baseline (0 bytes = genuinely clean, missing = strict).
# This runs UNCONDITIONALLY (every Bash call, not just commit-shaped ones) —
# only the sweep below is gated on command shape.
mkdir -p "$(dirname "$LEDGER")" 2>/dev/null
[ -f "$LEDGER" ] || : > "$LEDGER" 2>/dev/null

# ---------------------------------------------------------------------------
# looks_like_commit_command <command>
#
# Script-local helper (not part of the shared hc_*/hc__* library — this hook
# is its only caller), so it deliberately has NO hc_ prefix.
#
# Loose heuristic gate on WHEN to even attempt the sweep below — NOT a
# security boundary, just narrowing "was the command that just ran plausibly
# commit-shaped?" A PostToolUse(Bash) hook fires after EVERY Bash call, and
# the sweep below walks the WHOLE cursor..HEAD range indiscriminately (it
# cannot know which commit, if any, THIS specific call produced). Before this
# gate, a routine `git status`/test-run/whatever Bash call made AFTER a
# foreign commit had already landed would sweep that foreign commit into the
# ledger too — misattributing it as session-owned via nothing more than bad
# timing (fixes the common case: a foreign commit sitting there while the
# session goes on to do unrelated Bash work before Stop). Gating on
# command-shape means non-commit calls skip the sweep entirely, so a foreign
# commit is never picked up just because SOME later Bash call happened to run.
#
# This does not make attribution perfect: a foreign commit landing in the
# narrow window of the agent's own commit-shaped call (nothing observable
# between them) is still indistinguishable and gets swept in together — but
# concurrent same-tree sessions racing on the git tree are already an
# unsupported/documented-racy scenario elsewhere in this codebase, so that
# residual is accepted, not solved here.
looks_like_commit_command() {
  case "$1" in
    *"git commit"*|*"git-commit"*|*"commit-tree"*|*"git cz"*|*"git merge"*|\
    *"git rebase"*|*"git cherry-pick"*|*"git revert"*|*"git am"*|*"git pull"*)
      return 0 ;;
    *) return 1 ;;
  esac
}
looks_like_commit_command "$TOOL_COMMAND" || exit 0

CURRENT_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
[ -z "$CURRENT_HEAD" ] && exit 0

# --- derive the diff cursor (no sidecar file) --------------------------------
# 1. ledger non-empty → cursor = its LAST line (where we left off).
# 2. else the SessionStart-pinned original baseline (baselines/<sid>.sha).
# 3. else current HEAD — nothing to backfill, this call is a no-op. This is
#    what stops a first-ever invocation from walking pre-existing history into
#    the ledger: an empty ledger with no .sha baseline has no anchor to diff
#    from, so it starts counting from right now, not from the repo's genesis.
#
# BASELINE_CURSOR is also kept around (not just folded into CURSOR) because
# the ancestor-recovery step below needs to retry against it specifically —
# see there for why.
LEDGER_CURSOR=""
if [ -s "$LEDGER" ]; then
  LEDGER_CURSOR=$(tail -n 1 "$LEDGER" 2>/dev/null)
fi
SHA_BASELINE="$HARNESS_DIR/baselines/${SESSION_ID}.sha"
BASELINE_CURSOR=""
[ -f "$SHA_BASELINE" ] && BASELINE_CURSOR=$(cat "$SHA_BASELINE" 2>/dev/null)

CURSOR="$LEDGER_CURSOR"
[ -z "$CURSOR" ] && CURSOR="$BASELINE_CURSOR"
[ -z "$CURSOR" ] && CURSOR="$CURRENT_HEAD"

# HEAD unchanged since the last time we looked → no-op.
[ "$CURRENT_HEAD" = "$CURSOR" ] && exit 0

# Only append when the cursor is a real ancestor of HEAD. If history diverged
# underneath us (amend, rebase, branch switch) `--is-ancestor` fails.
#
# RECOVERY (do not get permanently stuck): the naive fix — "leave the ledger
# as-is, try again next time" — is a trap. Once the ledger has ANY content,
# CURSOR is ALWAYS its last line (see above), so a rewrite that orphans that
# one commit makes EVERY future call re-derive the exact same stale, forever-
# failing cursor. The ledger would stop growing permanently: real commits made
# after the rewrite never get appended, so hc__resolve_session_base sees them
# as absent from the ledger — confidently-foreign — and advances the base
# straight past them, silently defeating review for the rest of the session.
# That is backwards: absence from a KNOWN-STALE cursor must not read as a
# positive foreign signal.
#
# So: on ancestor failure, retry ONCE against BASELINE_CURSOR (the original
# SessionStart-pinned anchor) instead of the stale ledger tail. A rewrite
# (amend/rebase) replaces commits ABOVE the baseline but essentially never the
# baseline itself, so the baseline is almost always still a real ancestor of
# the rewritten HEAD — this is what lets the ledger resynchronize on the very
# next commit-shaped call instead of staying stuck for the rest of the
# session. If even the baseline is not an ancestor (or unavailable), there is
# genuinely nothing safe to diff from: append nothing, leave the ledger as-is,
# and try again next call — never guess an attribution.
if ! git -C "$PROJECT_DIR" merge-base --is-ancestor "$CURSOR" "$CURRENT_HEAD" 2>/dev/null; then
  if [ -n "$BASELINE_CURSOR" ] && [ "$BASELINE_CURSOR" != "$CURSOR" ] \
     && git -C "$PROJECT_DIR" merge-base --is-ancestor "$BASELINE_CURSOR" "$CURRENT_HEAD" 2>/dev/null; then
    CURSOR="$BASELINE_CURSOR"
  else
    exit 0
  fi
fi

git -C "$PROJECT_DIR" rev-list --reverse "$CURSOR..$CURRENT_HEAD" 2>/dev/null >> "$LEDGER"

exit 0
