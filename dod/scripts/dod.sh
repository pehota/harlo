#!/bin/bash
#
# dod/scripts/dod.sh — the dod skills' single entry CLI.
#
# Usage: dod.sh <verb> [args]   (run from anywhere inside the repo)
#
# Every skill Bash step is ONE call to this script: `bash "<plugin
# root>/scripts/dod.sh" <verb> …`. Each Bash tool call is a fresh shell, so
# nothing is carried between calls — the script resolves REPO (the git
# top-level of $PWD, dod_repo_root) and TASK_KEY (dod_task_key) itself, and
# derives every .dod/ path, the diff hash and the round from them. One fixed
# command shape is also what lets hooks/approve.sh auto-approve it without a
# permission prompt (ADR 0005).
#
# Delegates to lib/*.sh only (N6): it never jq's into contract.json,
# result.json or state.json — the owning lib reads/writes them. It never
# evals or executes its arguments; they are passed to lib functions as data.
#
# Verbs:
#   brief-path                    absolute path of this task's context brief
#   contract-write <flags…>       contract_write flags; path and --task-key are
#                                 computed, --baseline-sha defaults to HEAD,
#                                 --session-id to $CLAUDE_CODE_SESSION_ID
#   contract-read                 contract + state (+ latest result) as JSON
#   state-set <idle|verifying>
#   diff-hash                     diff hash against the contract baseline
#   cache-get <cmd>               cached verdict (pass|fail), or "miss"
#   cache-set <cmd> <pass|fail>
#   baseline-worktree             path of the baseline worktree (created lazily)
#   changed-standards             JSON array of changed standards files
#   result-write --requirements <json>
#   record-decisions <json>       record fix/skip per advisory id, then claim
#   claim                         arm the claim latch (dod-claim.sh)
#
# Errors: message on stderr, exit 1. Unknown verb: usage on stderr, exit 2.

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPT_ROOT/lib/gitref.sh"
. "$SCRIPT_ROOT/lib/contract.sh"
. "$SCRIPT_ROOT/lib/result.sh"
. "$SCRIPT_ROOT/lib/state.sh"

usage() {
  cat >&2 <<'EOF'
usage: dod.sh <verb> [args]
verbs: brief-path | contract-write <flags…> | contract-read | state-set <idle|verifying>
       diff-hash | cache-get <cmd> | cache-set <cmd> <pass|fail> | baseline-worktree
       changed-standards | result-write --requirements <json>
       record-decisions <json> | claim
EOF
  exit 2
}

die() { printf 'dod: %s\n' "$1" >&2; exit 1; }

VERB="${1:-}"
[ $# -gt 0 ] && shift
case "$VERB" in
  brief-path|contract-write|contract-read|state-set|diff-hash|cache-get|cache-set|\
  baseline-worktree|changed-standards|result-write|record-decisions|claim) : ;;
  *) usage ;;
esac

command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
REPO=$(dod_repo_root "$PWD")
TASK_KEY=$(dod_task_key "$REPO") \
  || die "no task key: $REPO is not a git repo or HEAD is detached (dod keys tasks by branch)"
DOD_DIR="$REPO/.dod/$TASK_KEY"
CONTRACT_FILE="$DOD_DIR/contract.json"
RESULT_FILE="$DOD_DIR/result.json"
STATE_FILE="$DOD_DIR/state.json"

# load_contract — contract_read, or a clear error naming where it looked.
load_contract() {
  contract_read "$CONTRACT_FILE" \
    || die "no contract for task '$TASK_KEY' at $CONTRACT_FILE — run /dod:define first"
}

# has_flag <flag> <args…> — 0 if <flag> appears as a flag name in the
# flag/value pairs (values are skipped, so a value equal to <flag> is not a
# match).
has_flag() {
  local flag="$1"; shift
  while [ $# -gt 0 ]; do
    [ "$1" = "$flag" ] && return 0
    shift
    [ $# -gt 0 ] && shift
  done
  return 1
}

cmd_contract_write() {
  local defaults=()
  has_flag --baseline-sha "$@" \
    || defaults+=(--baseline-sha "$(git -C "$REPO" rev-parse HEAD 2>/dev/null)")
  has_flag --session-id "$@" || defaults+=(--session-id "${CLAUDE_CODE_SESSION_ID:-}")
  # --task-key last: computed, never caller-supplied (the last one wins).
  contract_write "$CONTRACT_FILE" "$@" "${defaults[@]}" --task-key "$TASK_KEY" \
    || die "contract rejected (invalid flags or JSON) — nothing written"
  load_contract
  printf 'dod: contract open at %s (baseline %s)\n' "$CONTRACT_FILE" "$CONTRACT_BASELINE_SHA"
}

# cmd_contract_read — what the skills need, built from the libs' read vars.
cmd_contract_read() {
  local result="null"
  load_contract
  state_read "$STATE_FILE"
  if result_read "$RESULT_FILE"; then
    result=$(jq -n \
      --arg diff_hash "$RESULT_DIFF_HASH" \
      --arg baseline_sha "$RESULT_BASELINE_SHA" \
      --arg round "$RESULT_ROUND" \
      --argjson requirements "$RESULT_REQUIREMENTS" \
      --argjson advisory_ids "$RESULT_ADVISORY_IDS" \
      --argjson creep_ids "$RESULT_CREEP_IDS" \
      '{diff_hash: $diff_hash, baseline_sha: $baseline_sha, round: ($round | tonumber? // 0),
        requirements: $requirements, advisory_ids: $advisory_ids, creep_ids: $creep_ids}')
  fi
  jq -n \
    --arg repo "$REPO" \
    --arg task_key "$CONTRACT_TASK_KEY" \
    --arg status "$CONTRACT_STATUS" \
    --arg task "$CONTRACT_TASK" \
    --arg task_source "$CONTRACT_TASK_SOURCE" \
    --arg session_id "$CONTRACT_SESSION_ID" \
    --arg works_when "$CONTRACT_WORKS_WHEN" \
    --arg baseline_sha "$CONTRACT_BASELINE_SHA" \
    --argjson requirements "$CONTRACT_REQUIREMENTS" \
    --argjson waivers "$CONTRACT_WAIVERS" \
    --argjson brief "$CONTRACT_BRIEF" \
    --arg state "$STATE_STATE" \
    --argjson decisions "$STATE_DECISIONS" \
    --arg decided_diff_hash "$STATE_DECIDED_DIFF_HASH" \
    --argjson result "$result" \
    '{repo: $repo, task_key: $task_key, status: $status, task: $task,
      task_source: $task_source, session_id: $session_id, works_when: $works_when,
      baseline_sha: $baseline_sha, requirements: $requirements, waivers: $waivers,
      brief: $brief,
      state: {state: $state, decisions: $decisions, decided_diff_hash: $decided_diff_hash},
      result: $result}'
}

# current_hash — the diff hash against the contract baseline (never HEAD),
# the same dod_diff_hash gate.sh uses.
current_hash() {
  load_contract
  DIFF_HASH=$(dod_diff_hash "$REPO" "$CONTRACT_BASELINE_SHA")
  [ -n "$DIFF_HASH" ] || die "could not hash the diff against baseline $CONTRACT_BASELINE_SHA"
}

cmd_cache_get() {
  local cmd="${1:?usage: dod.sh cache-get <cmd>}"
  current_hash
  state_cache_get "$STATE_FILE" "$DIFF_HASH" "$cmd" || printf 'miss'
  printf '\n'
}

cmd_cache_set() {
  local cmd="${1:?usage: dod.sh cache-set <cmd> <pass|fail>}"
  local verdict="${2:?usage: dod.sh cache-set <cmd> <pass|fail>}"
  case "$verdict" in pass|fail) : ;; *) die "cache-set verdict must be pass or fail, got '$verdict'" ;; esac
  current_hash
  state_cache_set "$STATE_FILE" "$DIFF_HASH" "$cmd" "$verdict" || die "cache write failed"
}

cmd_result_write() {
  [ "${1:-}" = "--requirements" ] || die "usage: dod.sh result-write --requirements <json>"
  local requirements="${2:?usage: dod.sh result-write --requirements <json>}" round
  current_hash
  round=$(result_next_round "$RESULT_FILE" "$CONTRACT_BASELINE_SHA")
  result_write "$RESULT_FILE" \
    --diff-hash "$DIFF_HASH" \
    --baseline-sha "$CONTRACT_BASELINE_SHA" \
    --round "$round" \
    --requirements "$requirements" \
    || die "result rejected (requirements must be a JSON array of check/judgement entries, every finding with an id) — nothing written"
  printf 'dod: result written at %s (round %s, diff_hash %s)\n' "$RESULT_FILE" "$round" "$DIFF_HASH"
}

cmd_claim() {
  bash "$SCRIPT_ROOT/scripts/dod-claim.sh" "$REPO" "$TASK_KEY" || die "could not arm the claim latch"
  printf 'dod: claim latch armed for %s\n' "$TASK_KEY"
}

cmd_record_decisions() {
  local decisions="${1:?usage: dod.sh record-decisions <json>}"
  result_read "$RESULT_FILE" || die "no valid result at $RESULT_FILE — run /dod:verify first"
  state_record_decisions "$STATE_FILE" "$decisions" "$RESULT_DIFF_HASH" "$RESULT_ADVISORY_IDS" \
    || die "decisions rejected: need exactly one fix|skip per advisory id $RESULT_ADVISORY_IDS — nothing recorded"
  printf 'dod: decisions recorded\n'
  cmd_claim
}

case "$VERB" in
  brief-path) printf '%s\n' "$DOD_DIR/brief.md" ;;
  contract-write) cmd_contract_write "$@" ;;
  contract-read) cmd_contract_read ;;
  state-set)
    state_set_state "$STATE_FILE" "${1:?usage: dod.sh state-set <idle|verifying>}" \
      || die "state must be idle or verifying, got '$1'"
    ;;
  diff-hash) current_hash; printf '%s\n' "$DIFF_HASH" ;;
  cache-get) cmd_cache_get "$@" ;;
  cache-set) cmd_cache_set "$@" ;;
  baseline-worktree)
    load_contract
    dod_baseline_worktree "$REPO" "$TASK_KEY" "$CONTRACT_BASELINE_SHA" \
      || die "could not create the baseline worktree at $DOD_DIR/baseline-worktree"
    printf '\n'
    ;;
  changed-standards)
    load_contract
    dod_changed_standards "$REPO" "$CONTRACT_BASELINE_SHA" || die "could not list changed standards"
    ;;
  result-write) cmd_result_write "$@" ;;
  record-decisions) cmd_record_decisions "$@" ;;
  claim) cmd_claim ;;
esac
