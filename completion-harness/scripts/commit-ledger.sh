#!/bin/bash
#
# Completion Harness — Bash tool-call hook: session commit ledger.
#
# Wired TWICE, on the same `Bash|SlashCommand|mcp__.*` matcher, and the mode
# comes from $1:
#   PreToolUse  → `commit-ledger.sh pre`   pins HEAD into
#                                          baselines/<sid>.cursor.<tool_use_id>
#                                          (baselines/<sid>.cursor when the
#                                          payload carries no per-call id)
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
# demand. Ceiling: that race is an OVER-block, never a skipped review.
# Concurrent same-tree sessions are already documented as unsupported-racy
# elsewhere in this codebase. Upgrade path if it ever bites: correlate
# `git reflog HEAD` entries with the call window instead of using a bare
# two-point HEAD diff, or have the agent's own commit path stamp the sha
# directly. Not worth it for an over-block.
#
# THE WINDOW RULE IS AN INFERENCE IN BOTH DIRECTIONS, AND IT LEAKS BOTH WAYS.
#
# "INSIDE A WINDOW ⇒ AGENT-AUTHORED" is false for a FAST-FORWARD. `git pull
# --ff-only` moves HEAD, inside a window, over commits authored elsewhere and
# earlier — receiving a commit and creating one are indistinguishable at the
# window level. This one is NOT closable by any window rule; only a property of
# the commit itself can separate them, which is what the COMMITTER-DATE FILTER in
# the sweep below does (see it for the production incident and the residual).
#
# "MISSED ⇒ FOREIGN" has THREE further holes. This header used to claim that
# being missed "requires HEAD to move OUTSIDE every call window, which is
# exactly the genuine human/foreign case". It is not:
#
#   (a) BACKGROUNDED Bash calls. PostToolUse fires when the TOOL RETURNS, not
#       when a backgrounded shell exits. The job commits later, the next `pre`
#       pins the cursor ABOVE that commit, and the agent's own commit never
#       enters the ledger — a SILENT SKIP. Closed by the watermark below: a
#       session that never backgrounded a job cannot have committed between
#       windows, so for it the inference is sound and an empty ledger still
#       means "authored nothing". Once a session HAS backgrounded a job the
#       inference is dead for the rest of its life, so from then on `pre` pins
#       to the WATERMARK (the last HEAD a sweep actually reached) rather than to
#       current HEAD — an over-block, and only for sessions that really
#       backgrounded something. The flag is deliberately per-session and
#       conditional: making it global or unconditional would sweep the human's
#       between-window commit into every session's ledger and re-introduce the
#       exact bug the ledger removed.
#
#       ponytail: ACCEPTED RESIDUAL — a job the agent backgrounds ITSELF, with
#       `&` or nohup inside an otherwise foreground Bash call, sets no
#       run_in_background flag, so no .bg-seen marker is written and a commit it
#       makes after the tool returns is missed. Undetectable from the payload
#       (the only evidence is the command text, and this hook deliberately
#       stopped reading that — see WHY OBSERVE HEAD above). Ceiling: a SILENT
#       SKIP, the bad direction; the honest fix is a commit-time stamp from the
#       agent's own commit path, not more heuristics here.
#
#   (b) TASK-MODE commits later merged by the human. This hook used to exit
#       early when HC_MODE != session, so a feature-branch session ledgered
#       nothing; if the human then merged to trunk outside a window, the session
#       flipped to session mode with an ABSENT ledger and advanced the base
#       straight to HEAD. The write path therefore now runs in TASK MODE TOO.
#       It is inert where it is written — hc__resolve_task_base returns the
#       pinned fork point and never advances past anything, ledger or not — and
#       matters only when a later session-mode resolve reads it. Consequence
#       accepted: a session that works on a branch and then checks trunk out
#       mid-session holds ledger shas unreachable from trunk's HEAD, so the
#       rewrite tripwire fires and over-blocks. That is the safe direction.
#
#   (c) NON-BASH tools that move HEAD (an MCP git server, a SlashCommand that
#       commits). No Bash window exists at all, so nothing pins and nothing
#       sweeps. Closed by WIDENING both hook matchers to
#       `Bash|SlashCommand|mcp__.*` (hooks/hooks.json AND install.sh — keep them
#       in sync). Deliberately NOT every tool: Read/Edit/Glob cannot move HEAD,
#       and pinning on them would add two process spawns to every single tool
#       call for nothing. ACCEPTED RESIDUAL: a HEAD-moving tool outside that
#       matcher set is still missed.
#
# Style/guard discipline matches the other hooks: small, guarded everywhere, no
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
# SHAs that vanish when the operation finishes. Kept in the SHARED preamble so
# pre and post cannot diverge on it. After the operation completes, the next
# Bash call pins the cursor at the NEW HEAD, so the rewritten commits never
# enter the ledger at all — and hc__resolve_session_base's reachability
# tripwire then fires on the now-unreachable PRE-rebase sha and refuses to
# advance the base. Over-block, never a silent skip.
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

# All this hook needs is WHERE the state dir is (and, for context only, which
# mode it is in). hc_resolve_light gives exactly that and NOTHING else — no base
# resolution, no advance, no rewrite tripwire. Calling full hc_resolve here (as
# this hook used to, purely to read HC_MODE) put the whole ledger walk on every
# single Bash tool call: ~0.6s at 0 ledger lines, ~4.9s at 40, ~19s at 200.
# There is no mode gate any more — see hole (b) in the header: task mode writes
# the ledger too.
if hc_has_fn hc_resolve_light; then
  hc_resolve_light 2>/dev/null
fi
[ -n "$HARNESS_DIR" ] || exit 0

LEDGER="$HARNESS_DIR/baselines/${SESSION_ID}.own-commits"
CURSOR_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.cursor"
# The last HEAD a sweep actually reached. Only consulted once this session has
# backgrounded a job (see BG_SEEN_FILE) — see hole (a) in the header.
WATERMARK_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.watermark"
# Sticky for the session's life: "this session backgrounded a Bash call, so a
# commit of its own can land outside every window".
BG_SEEN_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.bg-seen"
# "A sweep could not be completed" — read by hc__resolve_session_base as
# uncertainty, not as absence of work.
SWEEP_FAILED_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.sweep-failed"
# SessionStart's epoch (see baseline-snapshot.sh) — the committer-date floor for
# the sweep. Content, not mtime.
STARTED_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.started"
mkdir -p "$HARNESS_DIR/baselines" 2>/dev/null

# PER-CALL CURSOR. One shared .cursor cannot serve two windows at once: with
# parallel tool calls in one session (a normal Claude Code behaviour) the
# sequence pre(A) → commit → pre(B) → post → post left the agent's own commit in
# NO ledger — B's `pre` overwrote the shared cursor ABOVE the commit, and the
# watermark then advanced past it so nothing could rescue it. A SILENT SKIP.
#
# The payload carries a per-call id: both PreToolUse and PostToolUse hook events
# include `tool_use_id` (verified against the Claude Code 2.1.267 payload
# builder). So each call pins its OWN cursor, baselines/<sid>.cursor.<id>, and
# only its own `post` reads and removes it. A concurrent window then cannot
# narrow another's range at all — there is no shared lower bound left to narrow.
#
# NO OLDEST-OUTSTANDING UNION, deliberately: sweeping every open cursor's range
# would make an ORPHANED cursor (a `pre` whose `post` never fired — a denied or
# rejected tool call) widen every later sweep for the rest of the session, and a
# human between-window commit would then be claimed as agent work. Per-call
# cursors make orphans inert instead. They are also reaped with the rest of the
# session group (baseline-snapshot.sh keys that reap on the basename up to the
# first dot, i.e. the session id).
#
# NO id in the payload (an older CLI) → the shared cursor, exactly as before.
# The id is validated by SHAPE rather than sanitized: a shape we would not put
# in a filename falls back to the shared cursor (the old behaviour) instead of
# being rewritten into some other call's filename. Pure `case`, no fork — this
# hook runs on every tool call.
SHARED_CURSOR_FILE="$CURSOR_FILE"
case "${HC_HOOK_TOOL_USE_ID:-}" in
  ''|*[!A-Za-z0-9_-]*) : ;;
  *) CURSOR_FILE="$HARNESS_DIR/baselines/${SESSION_ID}.cursor.${HC_HOOK_TOOL_USE_ID}" ;;
esac

CURRENT_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)

if [ "$MODE" = "pre" ]; then
  # Ensure the ledger EXISTS even with nothing to record: present-and-empty
  # ("the hook has run, zero agent commits so far") stays a distinct, readable
  # signal from absent ("this hook never ran here") — the same present-vs-
  # missing distinction baseline-snapshot.sh's pin_tree_baseline draws for the
  # .dirty tree baseline.
  [ -f "$LEDGER" ] || : > "$LEDGER" 2>/dev/null

  # Backgrounded call → the inference in hole (a) is dead from here on. Sticky:
  # once created it is never removed, because a job backgrounded at call 3 can
  # still commit during call 30.
  #
  # TRUNCATED UNCONDITIONALLY, not created-if-absent: the file's CONTENT is
  # irrelevant (its existence is the signal), but its MTIME is not. Created
  # once and never touched again, it froze at creation time while the state it
  # qualifies (.cursor/.watermark/.own-commits) stayed fresh — so an age reap
  # deleted the marker and spared the ledger, and `pre` silently reverted to
  # pinning HEAD. baseline-snapshot.sh's grouped per-session reap is the real
  # fix; keeping the mtime honest here is defence in depth.
  case "$HC_HOOK_TOOL_BACKGROUND" in
    true|True|TRUE|1) : > "$BG_SEEN_FILE" 2>/dev/null ;;
  esac

  # Pin the window's lower bound. The file is THIS CALL's (keyed by
  # tool_use_id), so a parallel call's pin lands elsewhere and cannot narrow
  # this window; only on the no-id fallback path is it a whole-file overwrite
  # where the last pin wins.
  #
  # NORMALLY that bound is current HEAD, and a commit outside every window is
  # soundly foreign. Once this session has backgrounded a job it is not, so the
  # bound drops to the WATERMARK — the last HEAD a sweep actually reached — and
  # anything since then gets claimed. No watermark yet (no sweep has completed)
  # → fall back to HEAD; there is nothing below it we could honestly claim.
  PIN="$CURRENT_HEAD"
  if [ -f "$BG_SEEN_FILE" ]; then
    WATERMARK=$(cat "$WATERMARK_FILE" 2>/dev/null)
    [ -n "$WATERMARK" ] && PIN="$WATERMARK"
  fi
  [ -n "$PIN" ] && printf '%s\n' "$PIN" > "$CURSOR_FILE" 2>/dev/null
  exit 0
fi

# --- post: sweep the window --------------------------------------------------
CURSOR=""
[ -f "$CURSOR_FILE" ] && CURSOR=$(cat "$CURSOR_FILE" 2>/dev/null)
# This call's own pin is consumed here: read once, then removed, so an open
# window is exactly a cursor file that still exists.
[ "$CURSOR_FILE" != "$SHARED_CURSOR_FILE" ] && rm -f "$CURSOR_FILE" 2>/dev/null
# Per-call cursor missing but a shared one present → a `pre` that ran without a
# tool_use_id (mixed CLI versions). Its range is WIDER, never narrower, so
# reading it is the over-block direction.
if [ -z "$CURSOR" ] && [ "$CURSOR_FILE" != "$SHARED_CURSOR_FILE" ] && [ -f "$SHARED_CURSOR_FILE" ]; then
  CURSOR=$(cat "$SHARED_CURSOR_FILE" 2>/dev/null)
fi
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
# HEAD did not move during the call → hot path, nothing to append. The
# WATERMARK still advances: "this session has swept up to here" is true of an
# empty range too, and it is exactly the case a backgrounded job produces (the
# tool returns with HEAD unmoved, the job commits afterwards). Without this
# write the watermark would stay absent, `pre` would fall back to HEAD, and the
# backgrounded commit would be missed after all.
if [ "$CURRENT_HEAD" = "$CURSOR" ]; then
  printf '%s\n' "$CURRENT_HEAD" > "$WATERMARK_FILE" 2>/dev/null
  exit 0
fi

# `rev-list CURSOR..HEAD` over a rewritten history (amend/rebase inside the
# window) yields exactly the rewritten commits — which the agent's own rewrite
# authored, so claiming them is correct. No ancestor check is needed: unlike the
# old ledger-tail cursor, an externally pinned per-call cursor has no feedback
# loop, so one orphaned sha cannot poison later calls.
#
# THE EXIT STATUS IS CAPTURED, NOT DISCARDED. When the pinned cursor object no
# longer exists — `git gc --prune=now` / `git reflog expire` after an in-window
# amend, or a .cursor that outlived its objects — rev-list exits 128 and prints
# nothing. Swallowed, that is INDISTINGUISHABLE from "nothing to sweep", and the
# agent's own commit silently never reaches the ledger. Assigning to a variable
# (rather than piping into the loop, where $? would be the LOOP's status) is
# what makes the check real.
REVS=$(git -C "$PROJECT_DIR" rev-list --reverse "$CURSOR..$CURRENT_HEAD" 2>/dev/null)
SWEEP_RC=$?

# Retry against the SessionStart baseline: a wider range, but a live anchor.
# Over-including costs a spurious review demand; under-including silently skips
# one.
if [ "$SWEEP_RC" -ne 0 ]; then
  SHA_BASELINE="$HARNESS_DIR/baselines/${SESSION_ID}.sha"
  RETRY_FROM=""
  [ -f "$SHA_BASELINE" ] && RETRY_FROM=$(cat "$SHA_BASELINE" 2>/dev/null)
  if [ -n "$RETRY_FROM" ]; then
    REVS=$(git -C "$PROJECT_DIR" rev-list --reverse "$RETRY_FROM..$CURRENT_HEAD" 2>/dev/null)
    SWEEP_RC=$?
  fi
fi

# Both anchors dead. Do NOT exit quietly: a sweep we could not complete is
# UNKNOWN attribution, not absence of work — whatever HEAD moved over may well
# be the agent's own. Record it, and hc__resolve_session_base refuses to advance
# the base at all (the same over-block as the rewrite tripwire). Still exit 0:
# this hook must never fail the tool.
if [ "$SWEEP_RC" -ne 0 ]; then
  : > "$SWEEP_FAILED_FILE" 2>/dev/null
  exit 0
fi

# --- committer-date filter: a FAST-FORWARD is not authorship -----------------
# HEAD movement inside a window is read as authorship, but `git pull --ff-only`
# moves HEAD over commits authored ELSEWHERE, EARLIER — and creating a commit is
# indistinguishable from receiving one at the window level, so no window rule can
# separate them. Only a property of the COMMIT itself can. Observed in
# production: a session that authored nothing but ran one `git pull --ff-only`
# ledgered every fast-forwarded upstream commit, the gate reported "5 commits, 5
# authored this session", the coverage demand grew to 18 files of which 15 the
# session never touched, and a pre-existing bug in one of those foreign files
# then blocked a changeset that had nothing to do with it. An over-broad ledger
# is harmful, not merely generous.
#
# So a swept sha is appended only when its COMMITTER date is at or after this
# session's start (baselines/<sid>.started, written by baseline-snapshot.sh).
#
# COMMITTER, NOT AUTHOR date: rebase, amend and cherry-pick rewrite the
# committer date to now while preserving the author date, so the session's own
# rewritten work never trips this — while a fast-forwarded upstream commit keeps
# the committer date it was pushed with.
#
# FAIL-SAFE: no .started file, or content that is not a plain epoch integer → do
# NOT filter, sweep everything exactly as before. At the APPEND layer a missing
# ledger entry is a silent skip and an extra one is only an over-block, so when
# we cannot tell we over-block. Same for a git failure below.
#
# ponytail: ACCEPTED RESIDUAL — a colleague pushing DURING the session produces
# an upstream commit whose committer date is after our start, so a pull still
# sweeps it in. Ceiling: an OVER-block (a spurious review demand for a foreign
# file), never a skipped review. Closing it needs an authorship signal git does
# not have (the harness would have to stamp its own commits at creation time);
# not worth it for an over-block.
STARTED_EPOCH=$(cat "$STARTED_FILE" 2>/dev/null | tr -d '\r\n')
case "$STARTED_EPOCH" in
  ''|*[!0-9]*) STARTED_EPOCH="" ;;
esac
if [ -n "$STARTED_EPOCH" ] && [ -n "$REVS" ]; then
  # ONE git call for the whole range, not one per commit: a `git pull` on a repo
  # 150 commits behind would otherwise fork 150 times inside a PostToolUse hook.
  # shellcheck disable=SC2086  # deliberate word splitting: REVS is a sha list
  DATED=$(git -C "$PROJECT_DIR" show -s --format='%ct %H' $REVS 2>/dev/null)
  if [ $? -eq 0 ] && [ -n "$DATED" ]; then
    KEPT=""
    while IFS=' ' read -r ct sha; do
      [ -z "$sha" ] && continue
      # An unreadable date cannot exonerate a commit → keep it (over-block).
      case "$ct" in
        ''|*[!0-9]*) KEPT="${KEPT:+$KEPT
}$sha"; continue ;;
      esac
      [ "$ct" -ge "$STARTED_EPOCH" ] && KEPT="${KEPT:+$KEPT
}$sha"
    done <<EOF
$DATED
EOF
    REVS="$KEPT"
  fi
fi

# Dedupe against what the ledger already holds — two Bash calls running in
# parallel in one session can both sweep the same commit.
while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    grep -qxF -- "$sha" "$LEDGER" 2>/dev/null && continue
    printf '%s\n' "$sha" >> "$LEDGER" 2>/dev/null
  done <<EOF
$REVS
EOF

# Sweep completed → this session has now accounted for everything up to here.
printf '%s\n' "$CURRENT_HEAD" > "$WATERMARK_FILE" 2>/dev/null

exit 0
