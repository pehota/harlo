#!/bin/bash
#
# dod/lib/contract.sh — sole owner of contract.json (N6).
#
# Nothing outside this file may `jq` into contract.json. Schema, reader and
# writer live together so a shape change is one diff, not a drift risk across
# files.
#
# Invariants enforced by contract_validate, contract rejected otherwise:
#   - every requirement is `check` or `judgement`, never neither;
#   - every `check` requirement carries `cmd` and `expect_exit`;
#   - an `e2e` requirement always exists: either `applicable:true` with a
#     `cmd` (a normal check), or `applicable:false` with a non-empty
#     `reason`. Never absent. The base check-shape rule exempts `id:"e2e"`
#     when `applicable:false`, since it deliberately carries
#     `cmd:null`/`expect_exit:null` — contract__validate_e2e enforces its own
#     shape instead.

CONTRACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dod__has_jq() { command -v jq >/dev/null 2>&1; }

# contract__validate_requirements <json_array> — 0 if every element is a
# valid check or judgement requirement AND the e2e-always-present invariant
# holds, 1 otherwise.
contract__validate_requirements() {
  local reqs="$1"
  dod__has_jq || return 1
  printf '%s' "$reqs" | jq -e '
    all(.[];
      (.id == "e2e" and .type == "check" and .applicable == false)
      or (.type == "check" and (.cmd != null) and (.expect_exit != null))
      or (.type == "judgement")
    )
  ' >/dev/null 2>&1 || return 1
  contract__validate_e2e "$reqs"
}

# contract__validate_e2e <json_array> — an "e2e" requirement must exist,
# either applicable:true with a cmd (an ordinary check), or applicable:false
# with a non-empty reason. Never absent, never applicable with no cmd, never
# inapplicable with no reason.
contract__validate_e2e() {
  local reqs="$1"
  dod__has_jq || return 1
  printf '%s' "$reqs" | jq -e '
    (map(select(.id == "e2e")) | length) == 1
    and (map(select(.id == "e2e"))[0] as $e2e |
      ($e2e.applicable == true and $e2e.cmd != null)
      or ($e2e.applicable == false and (($e2e.reason // "") | length) > 0)
    )
  ' >/dev/null 2>&1
}

# contract_write <path> --task-key K --task T --task-source S --session-id ID
#                        --baseline-sha SHA [--dirty-files JSON_ARR]
#                        --requirements JSON_ARR [--waivers JSON_ARR]
# Validates before writing. Returns 1 and writes nothing on failure.
#
# Also resets the sibling state.json (same directory) back to defaults.
# contract_write is the sole entry point for "a task's lifecycle (re)starts" —
# fresh /dod:define or an amend after a pass, both always write status:"open"
# here. Without this reset, state.latched from a PRIOR pass on this task_key
# survives into the new contract: the gate would then treat the very next
# question-only turn (branch 5, no claim/no edits -> release) as already
# latched and demand a claim that was never made this time around. This does
# not violate N6 — contract.sh calls state_write, it never jq's state.json
# itself.
contract_write() {
  local path="$1"; shift
  local task_key="" task="" task_source="" session_id="" baseline_sha=""
  local dirty_files="[]" requirements="[]" waivers="[]"

  while [ $# -gt 0 ]; do
    case "$1" in
      --task-key) task_key="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --task-source) task_source="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      --baseline-sha) baseline_sha="$2"; shift 2 ;;
      --dirty-files) dirty_files="$2"; shift 2 ;;
      --requirements) requirements="$2"; shift 2 ;;
      --waivers) waivers="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  dod__has_jq || return 1
  contract__validate_requirements "$requirements" || return 1

  mkdir -p "$(dirname "$path")" 2>/dev/null

  jq -n \
    --arg task_key "$task_key" \
    --arg task "$task" \
    --arg task_source "$task_source" \
    --arg session_id "$session_id" \
    --arg baseline_sha "$baseline_sha" \
    --argjson dirty_files "$dirty_files" \
    --argjson requirements "$requirements" \
    --argjson waivers "$waivers" \
    '{
      version: 1,
      task_key: $task_key,
      status: "open",
      task: $task,
      task_source: $task_source,
      session_id: $session_id,
      baseline: { sha: $baseline_sha, dirty_files: $dirty_files },
      waivers: $waivers,
      requirements: $requirements
    }' > "$path" 2>/dev/null || return 1

  local state_lib
  state_lib="$(dirname "${BASH_SOURCE[0]}")/state.sh"
  if [ -f "$state_lib" ]; then
    # shellcheck disable=SC1090
    . "$state_lib"
    state_write "$(dirname "$path")/state.json"
  fi
}

# contract_read <path> — sets CONTRACT_* globals. Returns 1 on missing file,
# malformed JSON, or a validation failure, without setting stale globals.
contract_read() {
  local path="$1"
  CONTRACT_TASK_KEY=""
  CONTRACT_STATUS=""
  CONTRACT_TASK=""
  CONTRACT_TASK_SOURCE=""
  CONTRACT_SESSION_ID=""
  CONTRACT_BASELINE_SHA=""
  CONTRACT_REQUIREMENTS="[]"
  CONTRACT_WAIVERS="[]"

  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e '.' "$path" >/dev/null 2>&1 || return 1

  local reqs
  reqs=$(jq -c '.requirements // []' "$path" 2>/dev/null)
  contract__validate_requirements "$reqs" || return 1

  CONTRACT_TASK_KEY=$(jq -r '.task_key // ""' "$path" 2>/dev/null)
  CONTRACT_STATUS=$(jq -r '.status // ""' "$path" 2>/dev/null)
  CONTRACT_TASK=$(jq -r '.task // ""' "$path" 2>/dev/null)
  CONTRACT_TASK_SOURCE=$(jq -r '.task_source // ""' "$path" 2>/dev/null)
  CONTRACT_SESSION_ID=$(jq -r '.session_id // ""' "$path" 2>/dev/null)
  CONTRACT_BASELINE_SHA=$(jq -r '.baseline.sha // ""' "$path" 2>/dev/null)
  CONTRACT_REQUIREMENTS="$reqs"
  CONTRACT_WAIVERS=$(jq -c '.waivers // []' "$path" 2>/dev/null)
  [ -n "$CONTRACT_WAIVERS" ] || CONTRACT_WAIVERS="[]"
  return 0
}

# contract_set_status <path> <status> — the gate's only permitted write.
contract_set_status() {
  local path="$1" status="$2" tmp
  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  tmp="${path}.tmp.$$"
  jq --arg s "$status" '.status = $s' "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}
