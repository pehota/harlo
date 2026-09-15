#!/bin/bash
#
# task-DoD plugin — the DECISION LOG. Sourced helper, one function: dod_log.
#
# WHY THIS EXISTS. Every hook in this plugin has terminal paths that produce no
# output at all — the gate's early exits (no jq, non-git, detached HEAD,
# mid-merge, no claim latch) and the reminder's quiet paths. Those paths are the
# majority of real invocations and, until now, were completely unobservable:
# when a session reported "the gate never fired", there was no way to tell
# whether it fired and allowed, or never ran, or bailed at line 48. This log
# records the decision taken at EVERY terminal path so that question is
# answerable from the filesystem.
#
# It replaces the TaskCompleted audit trail (dod-task-log.sh), which was
# attached to an event that does not mean "a task was completed" in the sense
# this plugin gates on, and which produced zero records in a real session that
# used subagents.
#
# THE ONE INVARIANT: dod_log MUST NEVER BREAK ITS CALLER.
#   * It always returns 0. Every failure path is silent.
#   * It NEVER writes to stdout. The gate's stdout IS a protocol — an empty
#     stdout means allow and a single JSON object means block; one stray byte
#     from logging would corrupt a gate decision. Nothing here prints to stdout,
#     and the append is redirected to the log file explicitly.
#   * stderr is used only for a genuinely unloggable record, and even then the
#     return is still 0.
#   * No jq -> no logging, silently. jq is the only way to escape a free-text
#     detail safely, and a hand-rolled escape that emits a broken line into an
#     append-only file is worse than no line.
#
# SHAPE: append-only JSONL, ONE object per line, never rewritten. One file per
# UTC day ("dod-log/<YYYY-MM-DD>.jsonl") so it self-partitions. No rotation and
# no reaping — deliberately out of scope; a day file is small and a human can
# delete the directory.
#
# No `set -e`, no EXIT trap; every date/git/jq/mkdir call guarded.

# dod_log <hook> <decision> [detail]
#
#   hook      the hook event name ("Stop", "UserPromptSubmit", "SessionStart")
#   decision  what was actually decided — "silent" / "silent:<why>" /
#             "block:<category>" / "allow" / "remind" / "quiet" / "seed"
#   detail    short free text; optional
#
# Task key, HC_MODE and HEAD are read from the caller's scope / the repo, so a
# caller that has not resolved identity yet still produces a usable record
# (with those fields empty) rather than no record at all.
dod_log() {
  local hook="$1" decision="$2" detail="${3:-}"
  local proj dir day ts sha line

  command -v jq >/dev/null 2>&1 || return 0

  proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  dir="${HARNESS_DIR:-}"
  [ -n "$dir" ] || dir="$proj/.claude/.harness"
  dir="$dir/dod-log"

  day=$(date -u +%Y-%m-%d 2>/dev/null)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  [ -n "$day" ] || return 0
  sha=$(git -C "$proj" rev-parse --short HEAD 2>/dev/null)

  mkdir -p "$dir" 2>/dev/null || return 0

  line=$(jq -nc \
    --arg ts "$ts" \
    --arg hook "$hook" \
    --arg decision "$decision" \
    --arg task_key "${TASK_KEY:-${HC_TASK_KEY:-}}" \
    --arg mode "${HC_MODE:-}" \
    --arg head "$sha" \
    --arg detail "$detail" \
    '{ts:$ts,hook:$hook,decision:$decision,task_key:$task_key,mode:$mode,head:$head,detail:$detail}' \
    2>/dev/null)
  [ -n "$line" ] || return 0

  # stderr is redirected BEFORE the append, so a failing redirection (read-only
  # state dir) is swallowed by /dev/null rather than reported by the shell —
  # redirections are applied left to right.
  printf '%s\n' "$line" 2>/dev/null >> "$dir/${day}.jsonl" \
    || printf 'dod-log: record dropped (%s)\n' "$decision" >&2 2>/dev/null

  return 0
}
