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
#   - a `scenario` requirement always exists, same rule and same exemption,
#     enforced by contract__validate_scenario. Distinct decision from e2e
#     (behavior-change signal, not runner-availability signal) — see
#     dod-define/SKILL.md step 4.
#   - a `docs` requirement always exists: either `applicable:true` with a
#     non-empty `doc_paths` array (which doc(s) must be updated), or
#     `applicable:false` with a non-empty `reason`. Never a `cmd` — unlike
#     e2e/scenario, docs is not machine-run; `doc_paths` is what dod-reviewer
#     checks against. Exempted from the base check-shape rule the same way
#     e2e/scenario are (it never carries real `cmd`/`expect_exit`, even when
#     applicable), enforced by contract__validate_docs. See
#     dod-define/SKILL.md step 4 and dod/base-dod.md.
#   - a top-level `works_when` always exists on write: a non-empty string,
#     the one-sentence answer to "how will we know it works?" that every
#     requirement is a proof of. Enforced by contract_write only — see
#     contract_read for why a legacy contract without one is still readable.
#   - every requirement carries a non-empty `proves` string on write: which
#     part of `works_when` it proves (dod-define step 4). Enforced by
#     contract__validate_proves from contract_write only — a legacy contract
#     carrying the old advisory `rationale` instead still reads.

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
      ((.id == "e2e" or .id == "scenario") and .type == "check" and .applicable == false)
      or (.id == "docs" and .type == "check")
      or (.type == "check" and (.cmd != null) and (.expect_exit != null))
      or (.type == "judgement")
    )
  ' >/dev/null 2>&1 || return 1
  contract__validate_e2e "$reqs" || return 1
  contract__validate_scenario "$reqs" || return 1
  contract__validate_docs "$reqs"
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

# contract__validate_scenario <json_array> — a "scenario" requirement must
# exist, same rule as e2e: applicable:true with a cmd, or applicable:false
# with a non-empty reason. Never absent, never applicable with no cmd,
# never inapplicable with no reason.
contract__validate_scenario() {
  local reqs="$1"
  dod__has_jq || return 1
  printf '%s' "$reqs" | jq -e '
    (map(select(.id == "scenario")) | length) == 1
    and (map(select(.id == "scenario"))[0] as $sc |
      ($sc.applicable == true and $sc.cmd != null)
      or ($sc.applicable == false and (($sc.reason // "") | length) > 0)
    )
  ' >/dev/null 2>&1
}

# contract__validate_docs <json_array> — a "docs" requirement must exist,
# either applicable:true with a non-empty doc_paths array, or
# applicable:false with a non-empty reason. Never absent, never applicable
# with an empty/missing doc_paths, never inapplicable with no reason.
contract__validate_docs() {
  local reqs="$1"
  dod__has_jq || return 1
  printf '%s' "$reqs" | jq -e '
    (map(select(.id == "docs")) | length) == 1
    and (map(select(.id == "docs"))[0] as $d |
      ($d.applicable == true and (($d.doc_paths // []) | length) > 0)
      or ($d.applicable == false and (($d.reason // "") | length) > 0)
    )
  ' >/dev/null 2>&1
}

# contract__validate_proves <json_array> — every requirement has a
# non-empty `proves` string.
contract__validate_proves() {
  local reqs="$1"
  dod__has_jq || return 1
  printf '%s' "$reqs" | jq -e 'all(.[]; ((.proves // "") | type == "string" and length > 0))' >/dev/null 2>&1
}

# contract_write <path> --task-key K --task T --task-source S --session-id ID
#                        --works-when W --baseline-sha SHA [--dirty-files JSON_ARR]
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
  local task_key="" task="" task_source="" session_id="" works_when="" baseline_sha=""
  local dirty_files="[]" requirements="[]" waivers="[]"

  while [ $# -gt 0 ]; do
    case "$1" in
      --task-key) task_key="$2"; shift 2 ;;
      --task) task="$2"; shift 2 ;;
      --task-source) task_source="$2"; shift 2 ;;
      --session-id) session_id="$2"; shift 2 ;;
      --works-when) works_when="$2"; shift 2 ;;
      --baseline-sha) baseline_sha="$2"; shift 2 ;;
      --dirty-files) dirty_files="$2"; shift 2 ;;
      --requirements) requirements="$2"; shift 2 ;;
      --waivers) waivers="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  dod__has_jq || return 1
  [ -n "$works_when" ] || return 1
  contract__validate_requirements "$requirements" || return 1
  contract__validate_proves "$requirements" || return 1

  mkdir -p "$(dirname "$path")" 2>/dev/null

  jq -n \
    --arg task_key "$task_key" \
    --arg task "$task" \
    --arg task_source "$task_source" \
    --arg session_id "$session_id" \
    --arg works_when "$works_when" \
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
      works_when: $works_when,
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
# A contract written before `works_when`/`proves` existed reads back with
# CONTRACT_WORKS_WHEN="" (and its requirements as-is) rather than being
# rejected — same back-compat stance as the scenario/docs synthesis below.
contract_read() {
  local path="$1"
  CONTRACT_TASK_KEY=""
  CONTRACT_STATUS=""
  CONTRACT_TASK=""
  CONTRACT_TASK_SOURCE=""
  CONTRACT_SESSION_ID=""
  CONTRACT_WORKS_WHEN=""
  CONTRACT_BASELINE_SHA=""
  CONTRACT_REQUIREMENTS="[]"
  CONTRACT_WAIVERS="[]"

  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e '.' "$path" >/dev/null 2>&1 || return 1

  local reqs
  reqs=$(jq -c '.requirements // []' "$path" 2>/dev/null)

  # Back-compat: a contract written before `scenario` became a required
  # requirement (this plugin version) has no such entry. Synthesize an
  # implicit applicable:false on read rather than rejecting the whole
  # contract — contract_write already enforces scenario on every NEW
  # write, this only tolerates contracts that predate that enforcement.
  if ! printf '%s' "$reqs" | jq -e 'any(.[]; .id == "scenario")' >/dev/null 2>&1; then
    reqs=$(printf '%s' "$reqs" | jq -c '. + [{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"legacy-contract","applicable":false,"reason":"contract predates the scenario requirement"}]')
  fi

  # Back-compat: a contract written before `docs` became a required
  # requirement (this plugin version) has no such entry. Synthesize an
  # implicit applicable:false on read, same rationale as scenario above.
  if ! printf '%s' "$reqs" | jq -e 'any(.[]; .id == "docs")' >/dev/null 2>&1; then
    reqs=$(printf '%s' "$reqs" | jq -c '. + [{"id":"docs","type":"check","source":"legacy-contract","applicable":false,"reason":"contract predates the docs requirement"}]')
  fi

  contract__validate_requirements "$reqs" || return 1

  CONTRACT_TASK_KEY=$(jq -r '.task_key // ""' "$path" 2>/dev/null)
  CONTRACT_STATUS=$(jq -r '.status // ""' "$path" 2>/dev/null)
  CONTRACT_TASK=$(jq -r '.task // ""' "$path" 2>/dev/null)
  CONTRACT_TASK_SOURCE=$(jq -r '.task_source // ""' "$path" 2>/dev/null)
  CONTRACT_SESSION_ID=$(jq -r '.session_id // ""' "$path" 2>/dev/null)
  CONTRACT_WORKS_WHEN=$(jq -r '.works_when // ""' "$path" 2>/dev/null)
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
