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

# ---------------------------------------------------------------------------
# hc_review_blocking <review_log_file> <min_level>
#
# Prints the integer count of BLOCKING findings (severity rank >= min_level
# rank). Single source of truth for severity gating — like hc_tree_status is for
# the tree — sourced identically by done-gate.sh (Step 8) and done-write-state.sh
# so they can never diverge.
#
# - Severity ranks: low=0 medium=1 high=2 critical=3.
# - A finding BLOCKS iff rank(finding.severity) >= rank(min_level).
#     default min_level "high" → high+critical block; medium+low are advisory.
#     min_level "low" → everything blocks (strictest).
# - UNKNOWN or MISSING finding severity ranks as BLOCKING (rank 99) — safe
#   direction: a typo'd/absent severity can never dodge the gate.
# - If min_level is unknown/empty, normalize to "high".
# - If the "findings" key is PRESENT it is authoritative and MUST be an array:
#   count from it (an EMPTY array counts 0 -> allow, reviewer found nothing).
#   A present-but-non-array findings (object/string/number/null) is a malformed
#   or forged log -> jq errors -> "ERR" -> block (the self-reported open_findings
#   is NEVER consulted when findings is present).
# - If the "findings" key is ABSENT, FALL BACK to the log's .open_findings
#   integer (backward compat with old-style logs; missing -> 1 so it blocks).
# - If the log is missing or jq fails, print "ERR" (caller treats != "0" as
#   block). NEVER prints "0" on error — fail toward block.
hc_review_blocking() {
  local log="$1" min_level="$2"

  # jq is required to reason structurally; without it, fail toward block.
  command -v jq >/dev/null 2>&1 || { printf 'ERR'; return 0; }
  [ -f "$log" ] || { printf 'ERR'; return 0; }

  # Normalize an unknown/empty min_level to "high".
  case "$min_level" in
    low|medium|high|critical) ;;
    *) min_level="high" ;;
  esac

  local out
  out=$(jq -r --arg min "$min_level" '
    ({"low":0,"medium":1,"high":2,"critical":3}) as $rank
    | ($rank[$min] // 2) as $threshold
    | if (has("findings")) then
        # findings key PRESENT → it is authoritative. It MUST be an array; a
        # present-but-non-array findings (object/string/number/null) can never
        # dodge the gate by riding the self-reported open_findings — jq errors
        # here, the outer guard prints ERR, the caller blocks. An EMPTY array is
        # a legitimate "reviewer found nothing" → counts 0 → allow.
        if ((.findings | type) == "array") then
          [ .findings[]
            | (($rank[(.severity // "")] // 99)) as $r
            | select($r >= $threshold)
          ] | length
        else
          error("findings present but not an array")
        end
      else
        # findings key ABSENT → old-style log; fall back to the self-reported
        # open_findings integer (missing → 1 → block).
        (.open_findings // 1)
      end
  ' "$log" 2>/dev/null)

  # Guard: any failure (empty / non-numeric) fails toward block.
  case "$out" in
    ''|*[!0-9]*) printf 'ERR' ;;
    *) printf '%s' "$out" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# hc_review_coverage_gap <review_log_file> <base> <head> [proj]
#
# STRUCTURAL coverage check for the review step. Answers: "did the reviewer
# actually attest to having examined every file the changeset touched?" —
# turning "the review covered the whole changeset" from prose hope into a gate
# check. Companion to hc_review_blocking (severity) — same fail-toward-block
# discipline, sourced identically by done-gate.sh (Step 8) and
# done-write-state.sh so they can never diverge.
#
# Prints the newline-separated changeset files NOT attested as reviewed.
#   EMPTY output  → full coverage (PASS).
#   non-empty     → those files changed but were not attested → caller BLOCKS.
#   the token SKIP → coverage cannot be computed (no changeset base) → caller
#                    must NOT block on coverage (no-regression degrade; there was
#                    no coverage check before this feature).
#
# Definitions:
#   changed  = `git -C <proj> diff --name-only <base> <head>` (two-dot range).
#   reviewed = the log's .files_reviewed array (absent or NOT an array → []).
#   gap      = changed \ reviewed  (files changed but not attested).
#
# Guards / fail direction:
#   - <base> empty/unset OR the git diff command fails → print SKIP. Coverage is
#     meaningless without a changeset base; this is the ONLY no-block degrade.
#   - Everything else guarded toward BLOCK: on a jq error, an unreadable log, or
#     any other failure with a non-empty changed set, print the FULL changed set
#     (block) rather than empty (allow).
#   - A missing/non-array files_reviewed with a non-empty changed set → gap = all
#     changed files → non-empty → block. This is what FORCES the attestation:
#     the reviewer must list files_reviewed to pass.
#
# Space-safety: paths may contain spaces, so membership is by EXACT WHOLE-LINE
# equality (`grep -Fxvf <reviewed> <changed>`), never field-splitting — the same
# discipline hc_tree_status uses for porcelain lines.
hc_review_coverage_gap() {
  local log="$1" base="$2" head="$3"
  local proj="${4:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"

  # No changeset base → coverage is not computable. SKIP (no-block degrade).
  [ -z "$base" ] && { printf 'SKIP'; return 0; }

  # Changed set from the two-dot range. A git failure here means we cannot
  # compute a changeset at all → SKIP (parity with the missing-base case: no
  # changeset base we can trust).
  local changed
  if ! changed=$(git -C "$proj" diff --name-only "$base" "$head" 2>/dev/null); then
    printf 'SKIP'
    return 0
  fi

  # Empty changed set → nothing to cover → full coverage trivially (PASS).
  [ -z "$changed" ] && return 0

  # From here a non-empty changeset EXISTS; every remaining failure path prints
  # the full changed set (block), never empty (allow).

  # Reviewed set = .files_reviewed[] when it is an array, else empty. jq missing
  # or a malformed/unreadable log → treat reviewed as empty → gap = all changed
  # → block. We only accept an explicit array; anything else is [] (block).
  local reviewed=""
  if command -v jq >/dev/null 2>&1 && [ -f "$log" ]; then
    reviewed=$(jq -r '
      if (has("files_reviewed") and ((.files_reviewed | type) == "array"))
      then .files_reviewed[]
      else empty end
    ' "$log" 2>/dev/null)
    # jq crash yields empty stdout too — indistinguishable from a genuinely
    # empty array, and both mean "nothing attested" → block. Safe either way.
  fi

  # gap = changed \ reviewed, by exact whole-line equality (space-safe).
  # grep -Fxvf <reviewed> <changed>: print changed lines NOT present verbatim in
  # the reviewed set. Empty reviewed set → grep prints every changed line.
  local gap grc
  if [ -z "$reviewed" ]; then
    gap="$changed"
  else
    gap=$(printf '%s\n' "$changed" | grep -Fxvf <(printf '%s\n' "$reviewed") 2>/dev/null)
    grc=$?
    # grep exits 0 (lines printed) or 1 (no lines = full coverage). Anything
    # >1 is a real error → fail toward block with the full changed set.
    [ "$grc" -gt 1 ] && gap="$changed"
  fi

  printf '%s' "$gap"
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
