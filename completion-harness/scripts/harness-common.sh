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

# Resolve the contracts dir relative to THIS script's own location so callers
# never hardcode it. Works whether this file lives in completion-harness/scripts/
# (sibling completion-harness/contracts/) or .claude/scripts/ (sibling
# .claude/contracts/).
if [ -z "${HC_CONTRACTS_DIR:-}" ]; then
  HC_CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../contracts" 2>/dev/null && pwd)"
fi

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

    # Harness-managed config exemption. done-detect rewrites
    # .claude/done-config.json DURING /done itself (e.g. the contract_version
    # auto-upgrade, or a fingerprint refresh), which would otherwise be
    # classified as introduced work and force a needless commit → new HEAD →
    # full re-review cascade. It is never the changeset's own task work, so it
    # is never a blocker under any policy — recorded as a warning (surfaced,
    # not gated). The porcelain path is everything after the "XY " prefix.
    case "${line:3}" in
      '.claude/done-config.json')
        HC_TREE_WARNINGS="${HC_TREE_WARNINGS:+$HC_TREE_WARNINGS
}$line"
        continue ;;
    esac

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

# ---------------------------------------------------------------------------
# hc_live_task_keys [proj] [trunk] [current_branch]
#
# Prints the KEEP-set of task keys for the terminal reap — one `br-<sanitized>`
# key per local branch that is an IN-PROGRESS task, newline-separated. The pure
# decision logic for "which task state is load-bearing" lives here so it can be
# unit-tested without any deletion (baseline-snapshot.sh does the rm).
#
# A local branch's task state is LIVE (KEEP) iff ALL hold:
#   - the branch is NOT the trunk itself, AND
#   - the branch is NOT merged into trunk
#     (`! git merge-base --is-ancestor <branch> <trunk>`).
# A merged branch's changeset is integrated → its task state is dead → NOT in
# the keep-set → reapable. A branch that is GONE contributes no key at all →
# its stale key is likewise absent from the keep-set → reapable.
#
# SAFETY: if trunk is EMPTY/UNCONFIDENT, integration cannot be judged, so this
# prints NOTHING and the caller MUST skip the terminal reap entirely (never
# guess "merged"). Callers detect skip via the trunk being empty, not via empty
# output (a repo with only a merged trunk also yields empty output but that is a
# confident-trunk state — the caller checks trunk emptiness itself before reap).
#
# Args: [proj] defaults to PROJECT_DIR/CLAUDE_PROJECT_DIR/PWD; [trunk] defaults
# to hc__detect_trunk; [current_branch] should be the branch hc_resolve already
# resolved (HC_BRANCH) — passing it avoids a second, racy `symbolic-ref` here
# (a HEAD that detaches between hc_resolve's pin and this call would otherwise
# drop the just-pinned current-task key from the keep-set). Falls back to a live
# `symbolic-ref` only when the arg is omitted. Guarded; always returns 0.
hc_live_task_keys() {
  local proj="${1:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local trunk="${2:-}"
  local cur_arg="${3-__UNSET__}"
  # Resolve trunk lazily against `proj` if not supplied.
  if [ -z "$trunk" ]; then
    local _saved_proj="$PROJECT_DIR"
    PROJECT_DIR="$proj"
    trunk=$(hc__detect_trunk)
    PROJECT_DIR="$_saved_proj"
  fi
  # Unconfident trunk → cannot judge integration → keep-set is undefined; the
  # caller skips reap. Emit nothing.
  [ -z "$trunk" ] && return 0

  # The CURRENT branch is the active in-progress task — ALWAYS live, regardless
  # of merge status. A freshly-forked branch with no divergent commits yet is an
  # ancestor of trunk (would look "merged"), but its task is just beginning and
  # its state is load-bearing. Reaping it mid-task violates the hard invariant.
  # Prefer the caller-supplied branch (hc_resolve's HC_BRANCH); fall back to a
  # live symbolic-ref only when no arg was passed.
  local cur
  if [ "$cur_arg" = "__UNSET__" ]; then
    cur=$(git -C "$proj" symbolic-ref --short -q HEAD 2>/dev/null)
  else
    cur="$cur_arg"
  fi

  local br
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    [ "$br" = "$trunk" ] && continue
    if [ -n "$cur" ] && [ "$br" = "$cur" ]; then
      printf 'br-%s\n' "$(hc__sanitize "$br")"
      continue
    fi
    # Merged into trunk → integrated → NOT live (skip). Unmerged → live (keep).
    if git -C "$proj" merge-base --is-ancestor "$br" "$trunk" 2>/dev/null; then
      continue
    fi
    printf 'br-%s\n' "$(hc__sanitize "$br")"
  done <<EOF
$(git -C "$proj" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# hc_live_review_shas [proj]
#
# Prints the KEEP-set of review-log SHAs — one per line — for review-log
# hygiene. A `review-log/<sha>.json` is load-bearing ONLY if <sha> is a commit
# the gate might still check: the tip of some local branch, or the current HEAD.
# Everything else is superseded fix-churn and is reapable.
#
# The pure "is this sha a live tip / current HEAD" decision lives here; the
# deletion stays in baseline-snapshot.sh. Guarded; always returns 0.
hc_live_review_shas() {
  local proj="${1:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  # Current HEAD (empty in a non-git / unborn-branch repo).
  git -C "$proj" rev-parse HEAD 2>/dev/null
  # Every local branch tip.
  git -C "$proj" for-each-ref --format='%(objectname)' refs/heads/ 2>/dev/null
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

# ---------------------------------------------------------------------------
# hc_validate <schema_file> <json_file>
#
# Hard-contract validator. Validates a JSON instance against a JSON-Schema
# subset using ONLY jq — no node/ajv/new runtime. This is a SECURITY GATE:
# every ambiguity fails toward `return 1` (reject).
#
# Supported keyword subset (exactly these — NO $ref/oneOf/anyOf/allOf/
# pattern/format): type (string OR array-of-strings union), required (array),
# properties (object name→subschema), items (subschema applied to every array
# element), enum (array of allowed scalars), const (exact required scalar),
# additionalProperties (boolean, default true). Nullable is expressed as a type
# union, e.g. ["string","null"].
#
# Contract: prints "OK" and returns 0 when the instance is valid; prints
# "ERR: <path>: <what>" (the FIRST violation in document order) and returns 1
# on any invalidity or error. Fail-closed: jq missing, unreadable/unparseable
# schema or instance, or a jq runtime error → "ERR: ..." + return 1.
hc_validate() {
  local schema_file="$1" json_file="$2"

  # jq is mandatory — without it we cannot reason about JSON at all → reject.
  command -v jq >/dev/null 2>&1 || { printf 'ERR: jq unavailable\n'; return 1; }

  # Schema and instance must both be present, readable, and parseable JSON.
  [ -f "$schema_file" ] && [ -r "$schema_file" ] || { printf 'ERR: %s: schema missing or unreadable\n' "$schema_file"; return 1; }
  [ -f "$json_file" ]   && [ -r "$json_file" ]   || { printf 'ERR: %s: instance missing or unreadable\n' "$json_file"; return 1; }
  jq . "$schema_file" >/dev/null 2>&1 || { printf 'ERR: %s: schema not valid JSON\n' "$schema_file"; return 1; }
  jq . "$json_file"   >/dev/null 2>&1 || { printf 'ERR: %s: instance not valid JSON\n' "$json_file"; return 1; }

  # Each file must be EXACTLY ONE JSON document. `jq .` over an empty or
  # whitespace-only file reads zero inputs and exits 0 (silent success), which
  # would make the validator body below run over no input and pass — a
  # fail-OPEN hole. `jq -s 'length'` slurps every value into an array; require
  # length 1 so empty/whitespace (0) and concatenated multi-doc (>1) both fail
  # toward reject. Applied to BOTH files: an empty schema arrives via
  # --slurpfile as [] → $schema[0] == null → every check is skipped → OK, the
  # same fail-open. Fail-closed for both.
  [ "$(jq -s 'length' "$schema_file" 2>/dev/null)" = "1" ] || { printf 'ERR: %s: schema is not exactly one JSON document\n' "$schema_file"; return 1; }
  [ "$(jq -s 'length' "$json_file"   2>/dev/null)" = "1" ] || { printf 'ERR: %s: instance is not exactly one JSON document\n' "$json_file"; return 1; }

  # The recursive validator `v($schema; $path)` RETURNS a flat array of
  # "path: why" error strings (empty array = valid), collected depth-first in
  # document order. In bash we take `.[0]` — the FIRST error. Keyword order per
  # node: type → const → enum → (object) required → additionalProperties →
  # properties(recurse) → (array) items(recurse). Every keyword and every
  # recursion is guarded on the INSTANCE's actual type so a union type or an
  # absent keyword never crashes jq (a crash → empty stdout + nonzero rc →
  # handled as fail-closed below). The schema arrives via --slurpfile, which
  # wraps it in a one-element array, so the root schema is `$schema[0]`.
  local errs rc
  errs=$(jq -r --slurpfile schema "$schema_file" '
    # jq type name of the instance mapped to a schema type name. Objects,
    # arrays, strings, booleans and null map straight through; numbers map to
    # "number" (schema "integer" is checked separately below).
    def jtype:
      (. | type) as $t
      | if $t == "number" then "number" else $t end ;

    # Does the instance satisfy a single schema type name $want?
    #  - "integer": instance is a number equal to its own floor (no fractional
    #    part). We use (. == (.|floor)) rather than (. % 1 == 0) because the jq
    #    % operator truncates both operands first, so 3.5 % 1 == 3 % 1 == 0
    #    would wrongly accept 3.5 as an integer.
    #  - "number":  any number.
    #  - anything else: exact jq-type-name match.
    def type_ok($want):
      if $want == "integer" then
        ((. | type) == "number") and (. == (. | floor))
      elif $want == "number" then
        ((. | type) == "number")
      else
        (jtype == $want)
      end ;

    # Recursive validator. Returns [] when valid, else an array of error
    # strings. $schema is the (sub)schema node; $path is a jq-path string used
    # only for human-readable error messages.
    def v($schema; $path):
      # --- type: single string OR array-of-strings union (pass if ANY match).
      ( if ($schema | type) == "object" and ($schema | has("type")) then
            ($schema.type) as $ty
            | ( if ($ty | type) == "array"
                then ( . as $inst
                       | if any($ty[]; . as $w | ($inst | type_ok($w)))
                         then [] else [ ($path + ": expected type " + ($ty|tostring) + ", got " + jtype) ] end )
                else ( . as $inst
                       | if ($inst | type_ok($ty))
                         then [] else [ ($path + ": expected type " + ($ty|tostring) + ", got " + jtype) ] end )
                end )
          else [] end ) as $type_errs

      # --- const: exact equality.
      | ( if ($schema | type) == "object" and ($schema | has("const")) then
            ( if . == $schema.const then []
              else [ ($path + ": expected const " + ($schema.const|tostring)) ] end )
          else [] end ) as $const_errs

      # --- enum: membership.
      | ( if ($schema | type) == "object" and ($schema | has("enum")) then
            ( . as $inst
              | if any($schema.enum[]; . == $inst) then []
                else [ ($path + ": not in enum " + ($schema.enum|tostring)) ] end )
          else [] end ) as $enum_errs

      # --- object keywords (only when the INSTANCE is an object).
      | ( if (. | type) == "object" and ($schema | type) == "object" then
            . as $inst
            # required: each listed name must exist on the instance.
            | ( if ($schema | has("required")) then
                  [ $schema.required[] | . as $rk
                    | select(($inst | has($rk)) | not)
                    | ($path + ": missing required: " + $rk) ]
                else [] end ) as $req_errs
            # additionalProperties==false: no instance key outside properties.
            | ( ($schema.properties // {} | keys) as $allowed
                | if ($schema.additionalProperties == false) then
                    [ $inst | keys[] | select( . as $k | ($allowed | any(. == $k)) | not )
                      | ($path + ": additional property: " + .) ]
                  else [] end ) as $addl_errs
            # properties: recurse into each declared key the instance HAS,
            # in stable key order for determinism.
            | ( [ ($schema.properties // {} | keys[])
                  | . as $k
                  | select($inst | has($k))
                  | ($inst[$k] | v($schema.properties[$k]; $path + "." + $k)) ]
                | add // [] ) as $prop_errs
            | ($req_errs + $addl_errs + $prop_errs)
          else [] end ) as $obj_errs

      # --- array keyword (only when the INSTANCE is an array and items given).
      | ( if (. | type) == "array" and ($schema | type) == "object" and ($schema | has("items")) then
            . as $arr
            | ( [ range(0; ($arr | length)) as $i
                  | ($arr[$i] | v($schema.items; $path + "[" + ($i|tostring) + "]")) ]
                | add // [] )
          else [] end ) as $items_errs

      # Concatenate in the documented order; caller takes the first.
      | ( $type_errs + $const_errs + $enum_errs + $obj_errs + $items_errs ) ;

    v($schema[0]; "$") | .[0] // empty
  ' "$json_file" 2>/dev/null)
  rc=$?

  # A jq runtime error (malformed program/data) → nonzero rc → fail-closed.
  if [ "$rc" -ne 0 ]; then printf 'ERR: validator failure\n'; return 1; fi
  # A non-empty first-error string → invalid.
  if [ -n "$errs" ]; then printf 'ERR: %s\n' "$errs"; return 1; fi
  printf 'OK\n'; return 0
}

# ---------------------------------------------------------------------------
# hc_done_state_blocked <done_state_file> <head_sha> <base> <harness_dir> \
#                       <contracts_dir> <min_level>
#
# The single shared predicate for "is this done-state's recorded outcome (plus
# the live review evidence at HEAD) a GREEN completion, or is something still
# blocking?" — an EXACT faithful extraction of done-gate.sh's Step-8 blocker
# aggregation (the 7-part checklist-outcome gate). Sourced so the gate and any
# other consumer can never diverge from this logic — the same discipline that
# makes hc_tree_status / hc_review_blocking single-source predicates.
#
# It does NOT re-check commit hygiene (SHA==HEAD, clean tree, escalation) — those
# are Steps 4b/5/6/7 upstream of Step 8 and remain the caller's responsibility
# (hc_state composes them). This predicate is ONLY the Step-8 outcome aggregation.
#
# Sets shell global:
#   HC_DONE_BLOCKED_REASON — empty string ("") when NOT blocked (all 7 green);
#     otherwise a short human-readable reason naming the FIRST failing check, in
#     Step-8 document order. Callers test the variable, NOT the return code.
#
# ALWAYS returns 0 (like hc_tree_status) — the verdict is the global, never $?.
#
# Fail direction is INVERTED from the library's usual fail-safe (matching the
# gate's Step 8): a MISSING / null / malformed outcome, an absent review-log, a
# jq crash, or jq itself being unavailable, are ALL treated as NOT green → block.
# A green verdict requires every check to affirmatively pass.
#
# The 7 aggregated blockers, in order (first failure wins):
#   1. tests.exit_code must be exactly "0" (absent → "MISSING" → block).
#   2. lint.exit_code checked ONLY when .lint is present/non-null; if present it
#      must be "0" (a present-but-nonzero blocks; absent lint is not a failure —
#      not every project configures lint).
#   3. review-log file must EXIST at <harness_dir>/review-log/<head_sha>.json —
#      keyed by the LIVE head sha passed in, NOT the task key (absence → block).
#   4. review-log must pass hc_validate against <contracts_dir>/review-log.schema.json.
#   5. hc_review_blocking <review_log> <min_level> must be exactly "0" — "ERR" or
#      any non-zero blocking count → block.
#   6. hc_review_coverage_gap <review_log> <base> <head_sha> <proj> must be empty
#      OR the token "SKIP" — a non-empty non-SKIP result (uncovered files) → block.
#      (SKIP = coverage not computable, a graceful no-regression degrade, NOT a block.)
#   7. task_checks: the count of entries with status != "passed" must be 0.
#
# jq is guarded behind `command -v jq`; if jq is missing we cannot read any
# recorded outcome → degrade fail-toward-block on check 1.
hc_done_state_blocked() {
  local done_state_file="$1" head_sha="$2" base="$3"
  local harness_dir="$4" contracts_dir="$5" min_level="$6"

  # Reset the verdict so a repeat call never leaks a stale reason.
  HC_DONE_BLOCKED_REASON=""

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"

  # jq is mandatory to read any recorded outcome. Without it we cannot verify
  # a single field → fail toward block (mirrors the gate, whose jq-missing top
  # guard would already have exited before Step 8 could pass).
  if ! command -v jq >/dev/null 2>&1; then
    HC_DONE_BLOCKED_REASON="jq unavailable (cannot verify recorded outcomes)"
    return 0
  fi

  # --- 1. tests.exit_code must be exactly "0" (absent → MISSING → block). -----
  local tests_exit
  tests_exit=$(jq -r '.tests.exit_code // "MISSING"' "$done_state_file" 2>/dev/null)
  if [ "$tests_exit" != "0" ]; then
    HC_DONE_BLOCKED_REASON="tests failed (exit ${tests_exit})"
    return 0
  fi

  # --- 2. lint.exit_code — conditional; only when .lint is present/non-null. --
  local lint_exit
  lint_exit=$(jq -r '.lint.exit_code // "MISSING"' "$done_state_file" 2>/dev/null)
  if [ "$lint_exit" != "MISSING" ] && [ "$lint_exit" != "0" ]; then
    HC_DONE_BLOCKED_REASON="lint failed (exit ${lint_exit})"
    return 0
  fi

  # --- 3. review-log file must EXIST at HEAD (keyed by live head sha). --------
  local review_log="$harness_dir/review-log/$head_sha.json"
  if [ ! -f "$review_log" ]; then
    HC_DONE_BLOCKED_REASON="no review-log at HEAD"
    return 0
  fi

  # --- 4. review-log must pass the hard-contract schema. ----------------------
  # A missing schema file → hc_validate nonzero → block (broken install, safe).
  if command -v hc_validate >/dev/null 2>&1 || type hc_validate >/dev/null 2>&1; then
    if ! hc_validate "$contracts_dir/review-log.schema.json" "$review_log" >/dev/null 2>&1; then
      HC_DONE_BLOCKED_REASON="review-log fails schema"
      return 0
    fi
  else
    HC_DONE_BLOCKED_REASON="contract validator unavailable"
    return 0
  fi

  # --- 5. hc_review_blocking must be exactly "0" (ERR / non-zero → block). ----
  local open
  if command -v hc_review_blocking >/dev/null 2>&1 || type hc_review_blocking >/dev/null 2>&1; then
    open=$(hc_review_blocking "$review_log" "$min_level")
  else
    open="ERR"
  fi
  if [ "$open" != "0" ]; then
    HC_DONE_BLOCKED_REASON="${open} blocking review finding(s)"
    return 0
  fi

  # --- 6. hc_review_coverage_gap must be empty OR "SKIP". ---------------------
  # SKIP (no changeset base → not computable) is a graceful degrade, NOT a block.
  local gap
  if command -v hc_review_coverage_gap >/dev/null 2>&1 || type hc_review_coverage_gap >/dev/null 2>&1; then
    gap=$(hc_review_coverage_gap "$review_log" "$base" "$head_sha" "$proj")
  else
    # Library failed to source — fail toward block, never toward an allow.
    gap="LIBUNAVAILABLE"
  fi
  if [ -n "$gap" ] && [ "$gap" != "SKIP" ]; then
    HC_DONE_BLOCKED_REASON="review coverage gap"
    return 0
  fi

  # --- 7. task_checks: count of entries with status != "passed" must be 0. ----
  # An absent task_checks yields length 0 (vacuously green). A jq crash yields ""
  # which is != "0" → block. The FIRST not-passed check names the reason.
  local task_failed
  task_failed=$(jq -r '[.task_checks[]? | select(.status != "passed")] | length' "$done_state_file" 2>/dev/null)
  if [ "$task_failed" != "0" ]; then
    local first_failed
    first_failed=$(jq -r 'first(.task_checks[]? | select(.status != "passed") | .desc) // "?"' "$done_state_file" 2>/dev/null)
    [ -z "$first_failed" ] && first_failed="?"
    HC_DONE_BLOCKED_REASON="task check '${first_failed}' not passed"
    return 0
  fi

  # All 7 green → not blocked (HC_DONE_BLOCKED_REASON stays "").
  return 0
}

# ---------------------------------------------------------------------------
# hc_state <session_id>
#
# The composed state classifier: maps the current changeset+tree+done-state to
# exactly ONE of five operator-facing states, and derives the canonical next
# action. It COMPOSES the existing single-source predicates (hc_resolve,
# hc_tree_status, hc_validate, hc_done_state_blocked) — it invents no new
# semantics; each branch mirrors a decision already made in done-gate.sh so the
# operator-facing state can never drift from what the Stop gate actually enforces.
#
# Sets shell globals:
#   HC_STATE — one of: S0 S1 S2 S4 S5.
#   HC_NEXT  — the canonical next-action string (empty "" for silent states).
#
# The five states and their gate correspondence:
#   S0 idle      — tree clean, no committed work past base. Nothing to gate.
#                  (gate Step 3 quiet-exit.) Silent: HC_NEXT="".
#   S1 working   — introduced tree blockers exist. "Introduced-dirty dominates":
#                  checked FIRST, before any commit/done reasoning, exactly as the
#                  gate would ultimately block on Step 6. HC_NEXT points at finishing
#                  and committing the slice.
#   S2 committed-unverified — committed work past base, tree clean, but the
#                  done-state is MISSING / schema-invalid / stale (verified_sha !=
#                  HEAD). (gate Steps 4/4b/5 block.) HC_NEXT points at running /done.
#   S4 blocked-on-X — a VALID done-state at the current HEAD, no escalation, but
#                  hc_done_state_blocked reports a live blocking outcome. (gate
#                  Step 8 blocks.) HC_NEXT is the specific remedy for that reason.
#   S5 verified  — either a valid done-state at HEAD with an escalation override
#                  (gate Step 7 allow), OR a valid done-state at HEAD whose Step-8
#                  outcomes are all green (gate Step 9 allow). Silent: HC_NEXT="".
#
# Escalation sits ABOVE the blocked predicate (mirroring gate Step 7 running
# before Step 8): when a non-null .escalation is present we go straight to S5
# and do NOT even call hc_done_state_blocked.
#
# Reachability / disjointness: every tree maps to exactly one state. S1 is the
# introduced-dirty guard (dominates). Given a clean tree, S0 vs {S2,S4,S5} splits
# on "committed work past base?". Given committed work, S2 vs {S4,S5} splits on
# "valid done-state at HEAD?". Given a valid done-state at HEAD, S5-via-escalation
# vs {S4,S5-green} splits on "escalation present?", and finally S4 vs S5-green
# splits on hc_done_state_blocked's verdict. No overlap.
#
# --- S4-vs-S2 boundary (verified from done-write-state.sh, DO NOT GUESS) -----
# done-write-state.sh stamps verified_sha=HEAD ONLY on a full-success (or
# escalated) write: with NO escalation it `exit 1`s BEFORE writing whenever
# tests/lint/review/coverage/task_checks are not green (lines 132-217), so a
# FAILED /done attempt with no escalation writes NO done-state at all — leaving
# the prior (stale or absent) done-state whose verified_sha != HEAD. That case
# therefore collapses into S2 (committed-unverified), NOT S4.
#
# Consequence: in the normal /done flow S4 is NOT reachable via a plain failed
# attempt. S4 is reachable ONLY when a done-state that is VALID and stamped at the
# CURRENT HEAD nonetheless has a live blocking outcome — i.e. the recorded outcome
# or the live HEAD-keyed review evidence has diverged from green AT this HEAD.
# Concretely reachable via:
#   (a) the review-log for HEAD is later deleted/absent  → check 3 blocks,
#   (b) an escalated write recorded a red tests.exit_code and the escalation is
#       then removed/nulled (Step 7 no longer short-circuits) → check 1 blocks,
#   (c) a done-state stamped at HEAD recording a failed task_check with an
#       escalation later dropped → check 7 blocks,
#   (d) a coverage gap at HEAD after the review-log's files_reviewed no longer
#       covers the changeset → check 6 blocks.
# All four are states the Stop gate's Step 8 would itself block on at this HEAD —
# hc_state surfaces the same verdict pre-emptively. The fixture test exercises S4
# by writing a valid done-state stamped at HEAD with tests.exit_code=1 and no
# escalation (case (b)'s end-state), and a separate coverage-gap fixture (case (d)).
hc_state() {
  local session_id="$1"

  # Reset outputs so a repeat call never leaks stale values.
  HC_STATE=""
  HC_NEXT=""

  # Compose the identity resolver + tree classifier. hc_resolve sets HC_MODE /
  # HC_BASE / HC_TASK_KEY / HARNESS_DIR / HC_CONTRACTS_DIR; hc_tree_status sets
  # HC_TREE_BLOCKERS relative to the pinned baseline (needs hc_resolve first).
  hc_resolve "$session_id"
  hc_tree_status "$session_id"

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local head_sha
  head_sha=$(git -C "$proj" rev-parse HEAD 2>/dev/null)

  # --- S1 working: introduced-dirty dominates. --------------------------------
  # Uncommitted work THIS session blocks first, before any commit/done reasoning
  # (gate Step 6). Checked before S0 so a dirty tree is never mistaken for idle.
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    HC_STATE="S1"
    HC_NEXT="finish the slice, then commit"
    return 0
  fi

  # Tree is clean from here on.

  # --- S0 idle: no committed work past base. ----------------------------------
  # "Committed work exists" = HEAD has moved past the resolver's anchor (HC_BASE).
  # In task mode HC_BASE is the pinned fork base; in session mode it is the
  # SessionStart baseline sha (empty when SessionStart recorded nothing). We have
  # committed work iff HC_BASE is a real sha AND HEAD != HC_BASE. Otherwise
  # (HEAD == base, OR session-mode with an empty/unrecorded base and thus nothing
  # we can attribute to this changeset) the changeset is empty → idle (gate Step 3
  # quiet-exit). Silent state.
  local committed_work=0
  if [ -n "$HC_BASE" ] && [ -n "$head_sha" ] && [ "$head_sha" != "$HC_BASE" ]; then
    committed_work=1
  fi
  if [ "$committed_work" -eq 0 ]; then
    HC_STATE="S0"
    HC_NEXT=""
    return 0
  fi

  # --- committed work exists, tree clean: locate the done-state. --------------
  local done_state_file="$HARNESS_DIR/done-state/$HC_TASK_KEY.json"

  # S2 committed-unverified: done-state MISSING, schema-invalid, or stale
  # (verified_sha != HEAD). Any of these means the current changeset was never
  # verified at THIS HEAD (gate Steps 4 / 4b / 5). Because done-write-state.sh
  # only stamps verified_sha=HEAD on a successful/escalated write, a failed plain
  # /done attempt lands here (its verified_sha != HEAD), not in S4.
  local verified_sha=""
  local valid_at_head=0
  if [ -f "$done_state_file" ]; then
    if hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$done_state_file" >/dev/null 2>&1; then
      verified_sha=$(jq -r '.verified_sha // ""' "$done_state_file" 2>/dev/null)
      if [ -n "$verified_sha" ] && [ "$verified_sha" = "$head_sha" ]; then
        valid_at_head=1
      fi
    fi
  fi
  if [ "$valid_at_head" -eq 0 ]; then
    HC_STATE="S2"
    HC_NEXT="run /done to verify the changeset (owns the Step-5 review)"
    return 0
  fi

  # --- valid done-state stamped at HEAD. --------------------------------------
  # Escalation sits ABOVE the blocked predicate (gate Step 7 before Step 8): a
  # non-null .escalation short-circuits straight to S5 (verified), WITHOUT calling
  # hc_done_state_blocked. Silent state.
  local escalation
  escalation=$(jq -r '.escalation // "null"' "$done_state_file" 2>/dev/null)
  if [ -n "$escalation" ] && [ "$escalation" != "null" ]; then
    HC_STATE="S5"
    HC_NEXT=""
    return 0
  fi

  # No escalation → the Step-8 outcome aggregation decides S4 vs S5.
  local min_level
  min_level=$(jq -r '.min_review_level // "high"' "$proj/.claude/done-config.json" 2>/dev/null)
  [ -z "$min_level" ] && min_level="high"

  hc_done_state_blocked "$done_state_file" "$head_sha" "$HC_BASE" \
    "$HARNESS_DIR" "$HC_CONTRACTS_DIR" "$min_level"

  if [ -n "$HC_DONE_BLOCKED_REASON" ]; then
    # --- S4 blocked-on-X: derive the specific remedy from the reason. ---------
    HC_STATE="S4"
    case "$HC_DONE_BLOCKED_REASON" in
      tests\ failed*)          HC_NEXT="fix failing tests, re-commit, re-run /done" ;;
      lint\ failed*)           HC_NEXT="fix lint, re-commit, re-run /done" ;;
      "review coverage gap")   HC_NEXT="review the uncovered files, then re-run /done" ;;
      "no review-log at HEAD") HC_NEXT="run an independent code review, then re-run /done" ;;
      *blocking\ review*)      HC_NEXT="address the blocking review findings, then re-run /done" ;;
      task\ check\ *)          HC_NEXT="resolve: ${HC_DONE_BLOCKED_REASON}, then re-run /done" ;;
      *)                       HC_NEXT="resolve: ${HC_DONE_BLOCKED_REASON}, then re-run /done" ;;
    esac
    return 0
  fi

  # --- S5 verified: valid done-state at HEAD, no escalation, all outcomes green.
  # Silent state (gate Step 9 allow).
  HC_STATE="S5"
  HC_NEXT=""
  return 0
}
