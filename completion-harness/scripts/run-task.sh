#!/bin/bash
#
# Completion Harness — headless task execution.
#
#   run-task.sh "<task description>" [branch-name]
#
# Provisions a worktree (new-worktree.sh), runs `claude -p "<task>"` inside it
# unattended, then independently verifies the harness's own Definition-of-Done
# gate actually fired — never trusting the model's own claim of completion.
# Writes a full report to the MAIN checkout so it survives even if the
# worktree is later removed. Never merges, never pushes, never opens a PR.
#
# TECHNICAL CONTAINMENT, not prompt instructions the model could ignore under
# pressure:
#   - worktree isolation (new-worktree.sh; the same mechanism task mode
#     already relies on for a stable changeset anchor).
#   - a no-push `git` shim placed first on PATH for the CHILD `claude`
#     process ONLY — every subcommand passes through to the real git except
#     `push`, which is refused. The shimmed PATH never leaks into this
#     script's own execution after the child exits.
#   - `--strict-mcp-config --mcp-config '{"mcpServers":{}}'` on the child
#     invocation, so it starts with ZERO MCP servers regardless of what is
#     registered ambient on the machine (user-level marketplace entries —
#     Atlassian, Figma, Gmail, Chrome DevTools, etc.). Nobody is watching a
#     headless run to notice one of those get invoked or interfere. This is
#     an empty allowlist by design, not a configurable one — no per-task MCP
#     needs exist yet, and adding a config surface for a need that does not
#     exist is exactly the kind of speculative flexibility this harness
#     avoids elsewhere.
#   - `--plugin-dir "$PLUGIN_DIR"` (an absolute path resolved from
#     completion-harness/, one level above this script) on the same child
#     invocation, loading THIS repo's own plugin bundle explicitly. Locking
#     out ambient MCP servers/plugins must not also lock out the harness's
#     own /done skill and SessionStart/Stop/PreToolUse hooks — the entire
#     headless design depends on the model being able to invoke /done and on
#     those hooks firing regardless of whatever plugin registration exists
#     (or doesn't) ambient on the machine. Same reasoning as the MCP
#     isolation above: an explicit, reproducible allowlist of exactly one
#     entry, not dependence on ambient global state.
#
# `--permission-mode bypassPermissions` is a deliberate, flagged tradeoff:
# without it, any tool-approval prompt hangs forever with nobody to answer
# it, defeating headless operation entirely. The actual safety boundary is
# worktree isolation + the no-push shim above, not the permission mode.
#
# Verification reuses the Stop gate's OWN shared predicates
# (hc_tree_status, hc_verification_state, hc_done_state_blocked) rather than
# re-implementing sha/tree-clean/blocking-findings comparison from scratch —
# a second implementation of "is this done-state green and fresh?" is exactly
# the writer/gate divergence this codebase has already been bitten by twice.
#
# Exit code: 0 iff the computed verdict is PASSED, non-zero otherwise — so
# scripting/CI around this can branch on exit code without a notification
# channel.

set -u

TASK_DESC="${1:-}"
BRANCH_ARG="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared helpers early (before the first die() call below) so hc_die
# is available. Sourcing has no dependency on anything checked in this
# script — it only sets HC_CONTRACTS_DIR and a few path constants.
# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

# Verify sourcing succeeded BEFORE die() is defined or called anywhere below.
# die() delegates to hc_die, which does not exist if sourcing failed — without
# set -e, a bare `|| die ...` in that state would 127-and-continue instead of
# exiting, silently skipping every check that follows. This one check stays a
# literal (not die) for the same reason.
#
# Checks hc_done_state_blocked specifically — the LAST function this script
# calls (harness-common.sh:1917 of ~2100), not an early one like
# hc__detect_trunk. A `source` that dies partway through a syntax error still
# defines every function textually before the break, so an early check proves
# nothing about functions defined later in the file. This script's own verdict
# logic depends on hc_resolve/hc_tree_status/hc_done_state_blocked, all
# defined well after hc__detect_trunk — a truncated source there would let
# every call site's `2>/dev/null` swallow a 127 and silently compute
# VERDICT=PASSED with none of the actual DoD checks having run.
type hc_done_state_blocked >/dev/null 2>&1 \
  || { printf 'run-task: harness-common.sh could not be fully sourced (needed for DoD verification)\n' >&2; exit 1; }

HC_DIE_PREFIX="run-task"
die()  { hc_die "$1"; }
say()  { printf '%s\n' "$1"; }
warn() { printf '%s\n' "$1" >&2; }

[ -n "$TASK_DESC" ] || die 'usage: run-task.sh "<task description>" [branch-name]'

hc_has_jq || die "jq is required"
command -v claude >/dev/null 2>&1 || die "claude is required on PATH"
command -v timeout >/dev/null 2>&1 || die "timeout is required on PATH (coreutils; gtimeout on macOS via Homebrew, aliased/linked to timeout)"

# --- main checkout -----------------------------------------------------------
MAIN_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
TOPLEVEL=$(git -C "$MAIN_DIR" rev-parse --show-toplevel 2>/dev/null)
[ -n "$TOPLEVEL" ] || die "not a git repository: $MAIN_DIR"
MAIN_DIR="$TOPLEVEL"

# --- derive the branch name --------------------------------------------------
# task/<sanitized slug of the first ~40 chars>, unless one was given. Uses the
# SAME hc__sanitize new-worktree.sh/auto-branch.sh use — never a second
# sanitizer — so this stays predictable alongside branches made by hand.
if [ -n "$BRANCH_ARG" ]; then
  BRANCH="$BRANCH_ARG"
else
  SLUG=$(printf '%s' "$TASK_DESC" | cut -c1-40)
  SLUG=$(hc__sanitize "$SLUG")
  # Cosmetic only: collapse runs of '-' and trim the ends, so a description
  # starting/ending with punctuation does not yield "task/-foo-" or "task/--".
  SLUG=$(printf '%s' "$SLUG" | LC_ALL=C sed 's/-\{2,\}/-/g; s/^-*//; s/-*$//')
  [ -n "$SLUG" ] || SLUG="task"
  BRANCH="task/${SLUG}"
fi

# --- worktree path: EXACTLY new-worktree.sh's own default formula -----------
# new-worktree.sh derives ${HC_WORKTREE_ROOT:-$PROJECT_DIR/.worktrees}/$(hc__sanitize
# "$BRANCH") internally whenever it is not given an explicit path. We always
# pass one explicitly (new-worktree.sh's stdout is prose-only, no
# machine-readable path line), so this MUST replicate that formula exactly —
# any drift would make the passed-in path diverge from what the script would
# have picked on its own.
WT_ROOT="${HC_WORKTREE_ROOT:-$MAIN_DIR/.worktrees}"
WT_PATH="$WT_ROOT/$(hc__sanitize "$BRANCH")"

TASK_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(hc__sanitize "$BRANCH")"
MAIN_HARNESS_DIR="$(hc__harness_dir "$MAIN_DIR")"
REPORT_DIR="$MAIN_HARNESS_DIR/headless-tasks/$TASK_ID"
INDEX="$MAIN_HARNESS_DIR/headless-tasks/index.jsonl"
TRANSCRIPT="$REPORT_DIR/transcript.log"
REPORT="$REPORT_DIR/report.json"
mkdir -p "$REPORT_DIR" || die "cannot create report dir: $REPORT_DIR"

# --- config: headless_max_turns / headless_timeout_minutes ------------------
# Read from the MAIN checkout's config — the worktree does not exist yet, and
# a fresh worktree may not even carry done-config.json if it is gitignored.
MAX_TURNS=$(hc_cfg headless_max_turns "60" "$MAIN_DIR")
{ [ -n "$MAX_TURNS" ] && [ "$MAX_TURNS" != "null" ]; } || MAX_TURNS=60
TIMEOUT_MIN=$(hc_cfg headless_timeout_minutes "45" "$MAIN_DIR")
{ [ -n "$TIMEOUT_MIN" ] && [ "$TIMEOUT_MIN" != "null" ]; } || TIMEOUT_MIN=45

say "task:      $TASK_DESC"
say "branch:    $BRANCH"
say "worktree:  $WT_PATH"
say "task id:   $TASK_ID"
say "max-turns: $MAX_TURNS   timeout: ${TIMEOUT_MIN}m"
say ""

# ===========================================================================
# 1. provision the worktree.
# ===========================================================================
if ! CLAUDE_PROJECT_DIR="$MAIN_DIR" bash "$SCRIPT_DIR/new-worktree.sh" "$BRANCH" "$WT_PATH"; then
  die "new-worktree.sh failed to provision $WT_PATH for branch $BRANCH"
fi

# ===========================================================================
# 2. pin the tree baseline INSIDE the new worktree.
# ===========================================================================
# Same call shape confirmed to work standalone: a synthetic hook payload on
# stdin, CLAUDE_PROJECT_DIR pointed at the worktree. This also lazily pins
# the task-base fork point (hc_resolve, called internally by
# baseline-snapshot.sh), which the verdict computation below reads back.
printf '{"session_id":"%s","source":"startup"}' "$TASK_ID" \
  | CLAUDE_PROJECT_DIR="$WT_PATH" bash "$SCRIPT_DIR/baseline-snapshot.sh" >/dev/null 2>&1

# ===========================================================================
# 3. the no-push guardrail: a `git` shim first on PATH for the CHILD ONLY.
# ===========================================================================
# Resolve the REAL git via an absolute path BEFORE the child's PATH is
# modified, so the shim's fallback exec never recurses into itself.
REAL_GIT=$(command -v git) || die "git not found on PATH"
SHIM_DIR=$(mktemp -d) && [ -n "$SHIM_DIR" ] && [ -d "$SHIM_DIR" ] \
  || die "mktemp -d failed while building the no-push git shim"
cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
# no-push guardrail for run-task.sh's child claude process. Every subcommand
# passes through to the real git except 'push'/'send-pack', which are refused
# outright — a human reviews and pushes this branch, never the unattended
# session. Scans the WHOLE argument list, not just \$1: 'git -c x=y push' and
# 'git -C . push' put a global option ahead of the subcommand, and a bare \$1
# check misses both — this only needs to catch an unintentional push from a
# confused-not-adversarial run, not survive a model deliberately evading it
# (aliases/plumbing that reimplement push are out of scope for that reason).
for arg in "\$@"; do
  case "\$arg" in
    push|send-pack)
      printf 'git push is disabled under run-task.sh: a human reviews and pushes this branch.\n' >&2
      exit 1
      ;;
  esac
done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$SHIM_DIR/git"
# Cleanup only removes the shim tempdir; PATH itself is scoped to the child's
# subshell below and never touches the rest of this script's own execution.
trap 'rm -rf "$SHIM_DIR" 2>/dev/null' EXIT

# ===========================================================================
# 4. build the prompt.
# ===========================================================================
PROMPT="$TASK_DESC

Operational notes: the working directory and git branch ($BRANCH) are already
set up for this task — do not create a new worktree or branch. Run /done
yourself before considering the work finished; the harness's Definition-of-
Done checklist is the actual completion criterion, not your own judgment.
Never attempt to push or open a pull request — a human reviews this branch
afterward. If you are genuinely blocked, stop and explain rather than
looping."

# ===========================================================================
# 5. invoke claude -p, from inside the worktree, with the shimmed PATH.
# ===========================================================================
# completion-harness/ (this repo's own bundle, one level up from this script)
# is itself a valid plugin root (.claude-plugin/plugin.json, hooks/, skills/
# directly underneath) — resolved to an absolute path the same way SCRIPT_DIR
# is above, never passed to --plugin-dir as a literal "..".
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || die "cannot resolve plugin dir from $SCRIPT_DIR/.."

say "invoking claude -p …"
say ""
START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
(
  cd "$WT_PATH" || exit 127
  PATH="$SHIM_DIR:$PATH" timeout "${TIMEOUT_MIN}m" \
    claude -p "$PROMPT" --permission-mode bypassPermissions --max-turns "$MAX_TURNS" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --plugin-dir "$PLUGIN_DIR"
) > "$TRANSCRIPT" 2>&1
CLAUDE_RC=$?
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

say "claude exited: $CLAUDE_RC"
say ""

# ===========================================================================
# 6. verify independently — never trust the model's own claim of completion.
# ===========================================================================
TASK_KEY="br-$(hc__sanitize "$BRANCH")"
WT_HARNESS_DIR="$WT_PATH/.claude/.harness"
DONE_STATE="$WT_HARNESS_DIR/done-state/$TASK_KEY.json"

HEAD_SHA=$(git -C "$WT_PATH" rev-parse HEAD 2>/dev/null)
HEAD_TREE=$(git -C "$WT_PATH" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)

VERDICT=""
BLOCK_REASON=""

if [ -z "$HEAD_SHA" ]; then
  VERDICT="ERROR"
  BLOCK_REASON="could not resolve worktree HEAD"
elif [ "$CLAUDE_RC" -eq 124 ]; then
  VERDICT="TIMED_OUT"
  BLOCK_REASON="killed by timeout after ${TIMEOUT_MIN}m"
elif [ ! -f "$DONE_STATE" ]; then
  VERDICT="NO_STATE"
  BLOCK_REASON="no done-state at $DONE_STATE (the model never ran /done)"
else
  # Resolve identity IN THE WORKTREE — the same predicates the Stop gate and
  # finish-worktree.sh use, keyed the same way, reading the same files.
  PROJECT_DIR="$WT_PATH"
  export CLAUDE_PROJECT_DIR="$WT_PATH"
  hc_resolve "$TASK_ID" 2>/dev/null
  HARNESS_DIR="$(hc__harness_dir "$WT_PATH")"

  hc_tree_status "$TASK_ID" 2>/dev/null
  DIRT=$(printf '%s\n%s\n' "${HC_TREE_BLOCKERS:-}" "${HC_TREE_WARNINGS:-}" \
         | hc_filter_harness_own "$WT_PATH")

  VSTATE=$(hc_verification_state "$DONE_STATE" "$HEAD_SHA" "$HEAD_TREE" "$WT_PATH")

  MIN_LEVEL=$(jq -r '.min_review_level // "high"' "$WT_PATH/.claude/done-config.json" 2>/dev/null)
  { [ -n "$MIN_LEVEL" ] && [ "$MIN_LEVEL" != "null" ]; } || MIN_LEVEL="high"
  hc_done_state_blocked "$DONE_STATE" "$HEAD_SHA" "${HC_BASE:-}" \
    "$HARNESS_DIR" "${HC_CONTRACTS_DIR:-}" "$MIN_LEVEL" 2>/dev/null

  if [ -n "$DIRT" ]; then
    VERDICT="BLOCKED"
    BLOCK_REASON="worktree not clean at exit"
  elif [ "$VSTATE" = "stale" ]; then
    VERDICT="BLOCKED"
    BLOCK_REASON="done-state is stale (does not describe worktree HEAD)"
  elif [ -n "${HC_DONE_BLOCKED_REASON:-}" ]; then
    VERDICT="BLOCKED"
    BLOCK_REASON="$HC_DONE_BLOCKED_REASON"
  else
    VERDICT="PASSED"
  fi
fi

# ===========================================================================
# 7. write the report to the MAIN checkout (survives worktree removal).
# ===========================================================================
TASK_BASE="${HC_BASE:-}"
COMMITS="[]"
if [ -n "$TASK_BASE" ]; then
  COMMITS_RAW=$(git -C "$WT_PATH" log --oneline "$TASK_BASE..HEAD" 2>/dev/null)
  if [ -n "$COMMITS_RAW" ]; then
    C=$(printf '%s' "$COMMITS_RAW" | jq -R . 2>/dev/null | jq -sc . 2>/dev/null)
    [ -n "$C" ] && COMMITS="$C"
  fi
fi

TESTS_SUMMARY="null"
if [ -f "$DONE_STATE" ]; then
  T=$(jq -c '.tests // null' "$DONE_STATE" 2>/dev/null)
  [ -n "$T" ] && TESTS_SUMMARY="$T"
fi

REPORT_TMP="$REPORT.tmp.$$"
if jq -n \
  --arg task_id "$TASK_ID" \
  --arg task "$TASK_DESC" \
  --arg branch "$BRANCH" \
  --arg worktree "$WT_PATH" \
  --arg start "$START_TIME" \
  --arg end "$END_TIME" \
  --argjson claude_exit_code "$CLAUDE_RC" \
  --arg verdict "$VERDICT" \
  --arg reason "$BLOCK_REASON" \
  --arg head_sha "${HEAD_SHA:-}" \
  --arg task_base "$TASK_BASE" \
  --argjson tests "$TESTS_SUMMARY" \
  --argjson commits "$COMMITS" \
  --arg transcript "$TRANSCRIPT" \
  '{
    task_id: $task_id,
    task: $task,
    branch: $branch,
    worktree: $worktree,
    start_time: $start,
    end_time: $end,
    claude_exit_code: $claude_exit_code,
    verdict: $verdict,
    block_reason: (if $reason == "" then null else $reason end),
    head_sha: (if $head_sha == "" then null else $head_sha end),
    task_base: (if $task_base == "" then null else $task_base end),
    tests: $tests,
    commits: $commits,
    transcript: $transcript
  }' > "$REPORT_TMP" 2>/dev/null; then
  mv -f "$REPORT_TMP" "$REPORT" 2>/dev/null || warn "could not write $REPORT"
else
  rm -f "$REPORT_TMP" 2>/dev/null
  warn "could not build report.json (jq failed) — see $TRANSCRIPT for the raw transcript"
fi

INDEX_LINE=$(jq -nc \
  --arg task_id "$TASK_ID" \
  --arg branch "$BRANCH" \
  --arg verdict "$VERDICT" \
  --arg ts "$END_TIME" \
  '{task_id:$task_id, branch:$branch, verdict:$verdict, timestamp:$ts}' 2>/dev/null)
if [ -n "$INDEX_LINE" ]; then
  mkdir -p "$(dirname "$INDEX")" 2>/dev/null
  printf '%s\n' "$INDEX_LINE" >> "$INDEX" 2>/dev/null
else
  warn "could not append to $INDEX"
fi

# ===========================================================================
# 8. human-readable summary.
# ===========================================================================
say "verdict:   $VERDICT"
[ -n "$BLOCK_REASON" ] && say "reason:    $BLOCK_REASON"
say "report:    $REPORT"
say "transcript:$TRANSCRIPT"
say ""
say "The worktree and branch are left in place at $WT_PATH for inspection."
say "Nothing was merged, pushed, or turned into a PR."

[ "$VERDICT" = "PASSED" ]
