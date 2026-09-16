#!/bin/bash
#
# dod/lib/result.sh — sole owner of result.json (N6).
#
# Nothing outside this file may `jq` into result.json. diff_hash is the
# gate's trust key: gate.sh reads RESULT_DIFF_HASH and RESULT_BLOCKING_FAIL
# only through this file's functions.
#
# Phase 1 skeleton: check requirements only ("fail" verdict = blocking).
# Judgement verdicts / severity classification land with the reviewer in
# Phase 2 (result__validate_requirements already accepts type "judgement"
# so that phase is additive, not a reshape).

RESULT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dod__has_jq() { command -v jq >/dev/null 2>&1; }

# result__validate_requirements <json_array> — every element type check or
# judgement, never neither.
result__validate_requirements() {
  local reqs="$1"
  dod__has_jq || return 1
  printf '%s' "$reqs" | jq -e '
    all(.[]; .type == "check" or .type == "judgement")
  ' >/dev/null 2>&1
}

# result_write <path> --diff-hash H --baseline-sha SHA --round N
#                      --requirements JSON_ARR
result_write() {
  local path="$1"; shift
  local diff_hash="" baseline_sha="" round="0" requirements="[]"

  while [ $# -gt 0 ]; do
    case "$1" in
      --diff-hash) diff_hash="$2"; shift 2 ;;
      --baseline-sha) baseline_sha="$2"; shift 2 ;;
      --round) round="$2"; shift 2 ;;
      --requirements) requirements="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  dod__has_jq || return 1
  result__validate_requirements "$requirements" || return 1

  case "$round" in ''|*[!0-9]*) round=0 ;; esac

  mkdir -p "$(dirname "$path")" 2>/dev/null

  jq -n \
    --arg diff_hash "$diff_hash" \
    --arg baseline_sha "$baseline_sha" \
    --argjson round "$round" \
    --argjson requirements "$requirements" \
    '{
      diff_hash: $diff_hash,
      baseline_sha: $baseline_sha,
      round: $round,
      requirements: $requirements,
      summary: {
        pass: [$requirements[] | select(.verdict == "pass")] | length,
        blocking_fail: [$requirements[] | select(.verdict == "fail")] | length,
        advisory: [$requirements[] | select(.verdict == "advisory")] | length,
        waived: [$requirements[] | select(.verdict == "waived")] | length,
        na: [$requirements[] | select(.verdict == "n/a")] | length
      }
    }' > "$path" 2>/dev/null
}

# result_read <path> — sets RESULT_* globals. Returns 1 on missing/malformed/
# invalid, without setting stale globals.
result_read() {
  local path="$1"
  RESULT_DIFF_HASH=""
  RESULT_BASELINE_SHA=""
  RESULT_ROUND=""
  RESULT_REQUIREMENTS="[]"
  RESULT_BLOCKING_FAIL=""

  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e '.' "$path" >/dev/null 2>&1 || return 1

  local reqs
  reqs=$(jq -c '.requirements // []' "$path" 2>/dev/null)
  result__validate_requirements "$reqs" || return 1

  RESULT_DIFF_HASH=$(jq -r '.diff_hash // ""' "$path" 2>/dev/null)
  RESULT_BASELINE_SHA=$(jq -r '.baseline_sha // ""' "$path" 2>/dev/null)
  RESULT_ROUND=$(jq -r '.round // 0' "$path" 2>/dev/null)
  RESULT_REQUIREMENTS="$reqs"
  RESULT_BLOCKING_FAIL=$(jq -r '.summary.blocking_fail // 0' "$path" 2>/dev/null)
  return 0
}
