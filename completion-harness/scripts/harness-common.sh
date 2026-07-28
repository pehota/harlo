#!/bin/bash
#
# Completion Harness — shared identity resolver (sourced library).
#
# Single source of identity-resolution truth. Sourced, never executed.
# No `set -e`; every git call is guarded; on any failure we degrade to SESSION
# mode and never crash the caller.
#
# Public entrypoint: hc_resolve <session_id>
# Sets these shell globals:
#   PROJECT_DIR HARNESS_DIR
#   HC_BRANCH HC_TRUNK HC_MODE HC_TASK_KEY HC_BASE HC_WARN HC_TREE_BASE_FILE
#
# Idempotent: calling repeatedly returns the same pinned base.

# Sanitize a string for use in a filename / key: every char NOT in the safe
# set [A-Za-z0-9_.-] becomes '-'.
hc__sanitize() {
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null
}

# Offline, conservative trunk detection. Prints the trunk name, or nothing
# (empty = UNCONFIDENT). Never consults origin/HEAD (repos may have no remote).
hc__detect_trunk() {
  local cfg="$PROJECT_DIR/.claude/done-config.json"
  local t=""

  if command -v jq >/dev/null 2>&1 && [ -f "$cfg" ]; then
    t=$(jq -r '.trunk // empty' "$cfg" 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "null" ]; then
      printf '%s' "$t"
      return 0
    fi
  fi

  if git -C "$PROJECT_DIR" show-ref --verify -q refs/heads/main 2>/dev/null; then
    printf 'main'
    return 0
  fi
  if git -C "$PROJECT_DIR" show-ref --verify -q refs/heads/master 2>/dev/null; then
    printf 'master'
    return 0
  fi

  # UNCONFIDENT: emit nothing.
  return 0
}

hc_resolve() {
  local session_id="$1"

  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  HARNESS_DIR="$PROJECT_DIR/.claude/.harness"

  # Reset outputs so a repeat call never leaks stale values.
  HC_BRANCH=""
  HC_TRUNK=""
  HC_MODE="session"
  HC_TASK_KEY=""
  HC_BASE=""
  HC_WARN=""
  HC_TREE_BASE_FILE=""

  # Current branch ('' when detached or not a git repo).
  HC_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --short -q HEAD 2>/dev/null)

  # Conservative offline trunk.
  HC_TRUNK=$(hc__detect_trunk)

  # Task mode requires a real branch, a confident trunk, and branch != trunk.
  if [ -n "$HC_BRANCH" ] && [ -n "$HC_TRUNK" ] && [ "$HC_BRANCH" != "$HC_TRUNK" ]; then
    HC_MODE="task"
  else
    HC_MODE="session"
    # Warn only when we fell back BECAUSE of trunk (on trunk, or unconfident).
    if [ -n "$HC_BRANCH" ] && [ -n "$HC_TRUNK" ] && [ "$HC_BRANCH" = "$HC_TRUNK" ]; then
      HC_WARN="on trunk $HC_TRUNK, session fallback"
    elif [ -n "$HC_BRANCH" ] && [ -z "$HC_TRUNK" ]; then
      HC_WARN="unconfident trunk, session fallback"
    fi
  fi

  if [ "$HC_MODE" = "task" ]; then
    HC_TASK_KEY="br-$(hc__sanitize "$HC_BRANCH")"
    hc__resolve_task_base "$session_id"
  else
    HC_TASK_KEY="session-${session_id}"
    hc__resolve_session_base "$session_id"
  fi

  # Resolve the tree-baseline file (the "pre-existing" porcelain set for the
  # classifier). Keyed on the FINAL HC_MODE — hc__resolve_task_base may have
  # degraded task→session (unrelated histories), so set this AFTER it runs.
  #   TASK mode    → tree-base/<HC_TASK_KEY>.dirty  (pinned ONCE at the task's
  #                  fork point, reused across every session on the branch —
  #                  parallel to task-base/<HC_TASK_KEY>.sha). This is what stops
  #                  a later session re-seeding "pre-existing" from live porcelain
  #                  and thereby whitelisting the agent's own uncommitted work.
  #   SESSION mode → baselines/<session_id>.dirty  (per-session is correct — in
  #                  session mode the changeset IS the session; NOT HC_TASK_KEY,
  #                  which is "session-<id>").
  if [ "$HC_MODE" = "task" ]; then
    HC_TREE_BASE_FILE="$HARNESS_DIR/tree-base/$HC_TASK_KEY.dirty"
  else
    HC_TREE_BASE_FILE="$HARNESS_DIR/baselines/${session_id}.dirty"
  fi

  return 0
}

# Pin (or read pinned) merge-base for task mode. Falls back to session mode on
# unrelated histories (empty merge-base), without pinning.
hc__resolve_task_base() {
  local session_id="$1"
  local pin_dir="$HARNESS_DIR/task-base"
  local pin_file="$pin_dir/$HC_TASK_KEY.sha"

  if [ -f "$pin_file" ]; then
    HC_BASE=$(cat "$pin_file" 2>/dev/null)
    return 0
  fi

  local mb=""
  mb=$(git -C "$PROJECT_DIR" merge-base "$HC_TRUNK" HEAD 2>/dev/null)

  if [ -n "$mb" ]; then
    mkdir -p "$pin_dir" 2>/dev/null
    printf '%s\n' "$mb" > "$pin_file" 2>/dev/null
    HC_BASE="$mb"
    return 0
  fi

  # Unrelated histories: no anchor. Degrade to session mode, do NOT pin.
  HC_MODE="session"
  HC_TASK_KEY="session-${session_id}"
  HC_WARN="unrelated histories, session fallback"
  hc__resolve_session_base "$session_id"
  return 0
}

# Session-mode base: read the SessionStart baseline if present, else empty.
hc__resolve_session_base() {
  local session_id="$1"
  local base_file="$HARNESS_DIR/baselines/${session_id}.sha"
  if [ -f "$base_file" ]; then
    HC_BASE=$(cat "$base_file" 2>/dev/null)
  else
    HC_BASE=""
  fi
  return 0
}

# ---------------------------------------------------------------------------
# hc_tree_status <session_id>
#
# Baseline-relative working-tree classifier. THE single shared predicate used by
# the Stop gate (done-gate.sh Step 6), the /done writer (done-write-state.sh),
# and the preflight (done-preflight.sh) — none reimplements it.
#
# Classifies each current `git status --porcelain` line relative to the pinned
# tree baseline recorded at SessionStart. The baseline PATH comes from
# HC_TREE_BASE_FILE (set by hc_resolve), NOT a hardcoded session-keyed path:
#   TASK mode    → $HARNESS_DIR/tree-base/<HC_TASK_KEY>.dirty  (pinned once at
#                  the task fork; shared across all sessions on the branch).
#   SESSION mode → $HARNESS_DIR/baselines/<session_id>.dirty  (per session).
# Requires hc_resolve to have run first (it sets HC_TREE_BASE_FILE). If
# HC_TREE_BASE_FILE is empty (resolver not run), the baseline is treated as
# MISSING → empty set → everything blocks (safe direction). The session_id
# param is retained for signature stability but is vestigial in task mode (the
# path no longer derives from it).
#
# Sets shell globals (both newline-separated, empty if none):
#   HC_TREE_BLOCKERS — entries introduced THIS session (the changeset's own
#                      uncommitted work) → must block.
#   HC_TREE_WARNINGS — entries already present at baseline → pre-existing.
#                      Computed for classification/tests, but NOT surfaced in any
#                      message (pre-existing dirt is irrelevant to the task).
#
# Membership is by EXACT whole-line equality (robust to paths with spaces —
# the porcelain formatting is identical on both sides, so no field splitting).
#
# untracked_policy (done-config.json, default "baseline"):
#   "baseline" — a current line is a BLOCKER iff it is NOT in the baseline set;
#                lines present at baseline are WARNINGS. Applies to both tracked-
#                modified and untracked lines.
#   "strict"   — every untracked ("??") line is a BLOCKER regardless of baseline
#                (restores old strictness). Tracked-modified lines stay
#                baseline-relative in both modes.
#
# A MISSING baseline .dirty file is treated as the EMPTY baseline set (strict
# direction): every current change is "introduced" → blocks. Never silently
# passes. Requires PROJECT_DIR/HARNESS_DIR set (hc_resolve, or set by caller).
#
# Returns 0 always; callers test `[ -n "$HC_TREE_BLOCKERS" ]`.
hc_tree_status() {
  local session_id="$1"

  # Reset outputs so a repeat call never leaks stale values.
  HC_TREE_BLOCKERS=""
  HC_TREE_WARNINGS=""

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local hdir="${HARNESS_DIR:-$proj/.claude/.harness}"

  # Current tree state (guarded).
  local current
  current=$(git -C "$proj" status --porcelain 2>/dev/null)
  [ -z "$current" ] && return 0

  # Baseline path is the resolver-pinned HC_TREE_BASE_FILE (task- or session-
  # scoped). Empty (resolver not run) → treated as missing → strict direction.
  local baseline_file="${HC_TREE_BASE_FILE:-}"

  # untracked_policy override (default "baseline").
  local policy="baseline"
  local cfg="$proj/.claude/done-config.json"
  if command -v jq >/dev/null 2>&1 && [ -f "$cfg" ]; then
    local p
    p=$(jq -r '.untracked_policy // "baseline"' "$cfg" 2>/dev/null)
    [ -n "$p" ] && [ "$p" != "null" ] && policy="$p"
  fi

  local line in_baseline is_untracked
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    # First two chars are the porcelain status; "??" == untracked.
    is_untracked=0
    case "$line" in
      '??'*) is_untracked=1 ;;
    esac

    # strict policy: any untracked line blocks regardless of baseline.
    if [ "$policy" = "strict" ] && [ "$is_untracked" -eq 1 ]; then
      HC_TREE_BLOCKERS="${HC_TREE_BLOCKERS:+$HC_TREE_BLOCKERS
}$line"
      continue
    fi

    # Baseline-relative: present at baseline → warning; else → blocker.
    in_baseline=0
    if [ -f "$baseline_file" ] && grep -Fxq -- "$line" "$baseline_file" 2>/dev/null; then
      in_baseline=1
    fi

    if [ "$in_baseline" -eq 1 ]; then
      HC_TREE_WARNINGS="${HC_TREE_WARNINGS:+$HC_TREE_WARNINGS
}$line"
    else
      HC_TREE_BLOCKERS="${HC_TREE_BLOCKERS:+$HC_TREE_BLOCKERS
}$line"
    fi
  done <<EOF
$current
EOF

  return 0
}

# hc_tree_remediation — build the exact remediation text from the globals set by
# the most recent hc_tree_status call. Names ONLY the blocking (introduced)
# files. Pre-existing (warned-only) entries are intentionally NOT surfaced —
# they are irrelevant to the task. Prints to stdout.
hc_tree_remediation() {
  local msg=""
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    msg="commit or stash these changes you introduced: $(printf '%s' "$HC_TREE_BLOCKERS" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')"
  fi
  printf '%s' "$msg"
}
