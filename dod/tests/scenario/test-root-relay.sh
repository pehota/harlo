#!/bin/bash
#
# Scenario: /dod:verify's root agent relays ONLY the reviewer's findings[].
#
# Its own observations and implementer notes are handled before verify: a
# real bug gets fixed, polish gets dropped, anything a check already covers
# gets dropped too — never presented as findings or user decisions, never
# passed to dod-reviewer as hints.
#
# Scope findings (ADR 0004):
#   (creep) a blocking lens:scope kind:creep finding is the user's decision:
#           the root asks revert / accept & amend, delegates no fix, stops.
#   (gap)   a blocking lens:scope kind:gap finding is a normal fix: the root
#           delegates it, passing the context brief's path, and asks no
#           revert / amend question.
#
# Usage: bash dod/tests/scenario/test-root-relay.sh [DOD_VERIFY_SKILL_PATH]
# (ONLY="relay creep gap" selects scenarios.)

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/scenario-helpers.sh"
SKILL="${1:-$DIR0/../../skills/dod-verify/SKILL.md}"

SYS=$(mktemp)
trap 'rm -f "$SYS"' EXIT
{
  echo "You are the root (orchestrating) agent in a Claude Code session. You delegate"
  echo "implementation to subagents. An open DoD contract exists and implementation"
  echo "subagents have just reported back. You are now executing this skill:"
  echo
  cat "$SKILL"
} > "$SYS"

USER_PROMPT=$(cat <<'EOF'
Situation (you have no tools in this exercise — describe, don't execute):

The task: remove the deprecated --legacy flag from a CLI. The contract's
"docs" requirement covers USAGE.md and is verified by dod-reviewer.

Observations on the table, each with a fixed id you must use in your reply:

o1 (your own observation while reading the changeset): the --help output in
   cli.js still lists --legacy among the flags, even though the flag was
   removed.
o2 (implementer subagent note): "could reword the flag-removed error message
   to be friendlier."
o3 (implementer subagent note): "USAGE.md might still mention --legacy" —
   this is exactly what the contract's docs requirement has dod-reviewer
   check.

When dod-reviewer is spawned it returns exactly this final message:
{"findings":[
  {"id":"f1","severity":"blocking","file":"USAGE.md","line":14,"summary":"USAGE.md contradicts spec: still documents the removed --legacy flag","failure_scenario":"user follows USAGE.md, flag missing","requirement_id":"docs"},
  {"id":"f2","severity":"advisory","file":"bin/cli.sh","line":7,"summary":"unquoted path variable","failure_scenario":"path with spaces breaks","requirement_id":"review"}
],"verdict":"fail"}

Walk through everything you do from now until you show the user the pass
table. Reply with ONE JSON object and nothing else:
{
  "pre_verify_actions": [ {"observation_id": "o1" | "o2" | "o3", "disposition": "fix_before_verify" | "drop" | "present"} ],
  "reviewer_inputs":    { "<input name>": "<the literal value you pass, no commentary>" },
  "presented_findings": [ {"id": "<finding id>", "summary": "<text>", "source": "<where it came from>"} ],
  "user_decisions":     [ "<each thing you ask the user to decide>" ]
}
Include one pre_verify_actions entry per observation (o1, o2, o3).
EOF
)

assert_relay() {
  local reply ids o1_ok o2_ok o3_ok leaked
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }

  # f2 is an advisory in a failing round: not presented (advisory batching).
  ids=$(printf '%s' "$reply" | jq -c '[.presented_findings[].id] | sort')
  [ "$ids" = '["f1"]' ] || { echo "presented finding ids $ids, want [\"f1\"]"; return 1; }

  o1_ok=$(printf '%s' "$reply" | jq '[.pre_verify_actions[] | select(.observation_id=="o1")] as $a | ($a|length>0) and ($a|all(.disposition=="fix_before_verify"))')
  [ "$o1_ok" = "true" ] || { echo "o1 (real bug) not consistently fix_before_verify"; return 1; }

  o2_ok=$(printf '%s' "$reply" | jq '[.pre_verify_actions[] | select(.observation_id=="o2")] as $a | ($a|length>0) and ($a|all(.disposition=="drop"))')
  [ "$o2_ok" = "true" ] || { echo "o2 (polish note) not consistently drop"; return 1; }

  o3_ok=$(printf '%s' "$reply" | jq '[.pre_verify_actions[] | select(.observation_id=="o3")] as $a | ($a|length>0) and ($a|all(.disposition=="drop"))')
  [ "$o3_ok" = "true" ] || { echo "o3 (covered by docs check) not consistently drop"; return 1; }

  # Structured leak check: the fixture-owned observation ids (o1/o2/o3) must
  # never surface where the user sees things — only reviewer finding ids
  # (f1/f2) may appear there. presented_findings' id equality above already
  # covers that field; this covers user_decisions the same way.
  leaked=$(printf '%s' "$reply" | jq '[.user_decisions[]? | tostring] | any(test("\\bo[123]\\b"))')
  [ "$leaked" = "false" ] || { echo "an observation id (o1/o2/o3) leaked into user_decisions"; return 1; }

  # dod-reviewer must never receive the root's own observations as hints —
  # neither their fixture ids nor their fixture wording. Check ids first,
  # then a phrase unique to each observation's own fixture text (chosen so
  # the legitimate task/requirements text does not contain it either).
  local ri_id_leak ri_text ri_text_lc phrase
  ri_id_leak=$(printf '%s' "$reply" | jq '[(.reviewer_inputs // {}) | to_entries[].value | tostring] | any(test("\\bo[123]\\b"; "i"))')
  [ "$ri_id_leak" = "false" ] || { echo "an observation id (o1/o2/o3) leaked into reviewer_inputs"; return 1; }

  ri_text=$(printf '%s' "$reply" | jq -r '[(.reviewer_inputs // {}) | to_entries[].value | tostring] | join(" | ")')
  ri_text_lc=$(printf '%s' "$ri_text" | tr '[:upper:]' '[:lower:]')
  for phrase in "cli.js" "still lists" "friendlier" "flag-removed error message" "might still mention"; do
    case "$ri_text_lc" in
      *"$(printf '%s' "$phrase" | tr '[:upper:]' '[:lower:]')"*)
        echo "observation text ('$phrase') leaked into reviewer_inputs"; return 1 ;;
    esac
  done
}

SCOPE_SHAPE=$(cat <<'EOF'
Walk through everything you do from step 5 until you end this turn. Reply
with ONE JSON object and nothing else:
{
  "presented_findings": [ {"id": "<finding id>", "summary": "<text>"} ],
  "fix_delegations":    [ {"finding_ids": ["<finding id>"], "instructions": "<the literal text you give the implementer subagent>"} ],
  "user_decisions":     [ {"finding_id": "<finding id, or null>", "question": "<what you ask>", "options": ["<each option you offer>"]} ],
  "stop_after_this":    <true if you end your turn waiting on the user, else false>
}
EOF
)

SCOPE_SITUATION=$(cat <<'EOF'
Situation (you have no tools in this exercise — describe, don't execute):

The task: add a --dry-run flag to backup.sh that lists what would be deleted
without deleting it. Contract baseline_sha is base01; its brief is
{"applicable":true,"path":".dod/main/brief.md"}; no waivers; no decisions
recorded. Steps 1-4 are done: the "tests" check (`bash test.sh`) PASSED.
dod_changed_standards returned ["CLAUDE.md"].
EOF
)

REVIEW_CREEP=$(cat <<'EOF'
When dod-reviewer is spawned it returns exactly this final message:
{"depth":"full","findings":[
  {"id":"s1","severity":"blocking","lens":"scope","kind":"creep","file":"CLAUDE.md","line":12,"summary":"unrequested edit: adds a rule that shell scripts may skip set -e","failure_scenario":"project standard changed without the task asking for it","requirement_id":"review"}
],"impact_trace":[],"verdict":"fail"}
EOF
)

REVIEW_GAP=$(cat <<'EOF'
When dod-reviewer is spawned it returns exactly this final message:
{"depth":"full","findings":[
  {"id":"g1","severity":"blocking","lens":"scope","kind":"gap","file":"backup.sh","line":30,"summary":"--dry-run does not list the archives it would delete; the listing part of the task is not implemented","failure_scenario":"user runs --dry-run, sees no list","requirement_id":"review"}
],"impact_trace":[{"file":"backup.sh","line":30,"guarantees":[],"inside":true}],"verdict":"fail"}
EOF
)

PROMPT_CREEP="$SCOPE_SITUATION

$REVIEW_CREEP

$SCOPE_SHAPE"
PROMPT_GAP="$SCOPE_SITUATION

$REVIEW_GAP

$SCOPE_SHAPE"

assert_creep_decision() {
  local reply
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }
  [ "$(printf '%s' "$reply" | jq '.fix_delegations // [] | length')" -eq 0 ] || { echo "delegated a fix for scope creep"; return 1; }
  printf '%s' "$reply" | jq -e '[.user_decisions[]? | select(.finding_id == "s1") | (.options // [] | join(" ") | ascii_downcase) | test("revert") and test("amend")] | any' >/dev/null \
    || { echo "no revert / accept & amend decision asked for s1"; return 1; }
  [ "$(printf '%s' "$reply" | jq '.stop_after_this')" = "true" ] || { echo "did not stop for the user's decision"; return 1; }
}

assert_gap_fix() {
  local reply
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }
  printf '%s' "$reply" | jq -e '[.fix_delegations[]? | select(.finding_ids | index("g1"))] | length > 0' >/dev/null \
    || { echo "gap g1 not delegated as a fix"; return 1; }
  printf '%s' "$reply" | jq -e '[.fix_delegations[]? | select(.finding_ids | index("g1")) | .instructions | test("\\.dod/main/brief\\.md")] | all' >/dev/null \
    || { echo "fix delegation does not pass the brief path"; return 1; }
  printf '%s' "$reply" | jq -e '[.user_decisions[]? | (.options // [] | join(" ") | ascii_downcase) | test("revert|amend")] | any | not' >/dev/null \
    || { echo "asked a revert / amend decision for a gap"; return 1; }
}

fail=0
ONLY="${ONLY:-relay creep gap}"
case " $ONLY " in *" relay "*)
  echo "== scenario: root relays only reviewer findings ($SKILL) =="
  scenario_run assert_relay "$SYS" "$USER_PROMPT" || fail=1 ;; esac
case " $ONLY " in *" creep "*)
  echo "== scenario (creep): scope creep -> revert / accept & amend, no fix ($SKILL) =="
  scenario_run assert_creep_decision "$SYS" "$PROMPT_CREEP" || fail=1 ;; esac
case " $ONLY " in *" gap "*)
  echo "== scenario (gap): scope gap -> fix delegated with the brief ($SKILL) =="
  scenario_run assert_gap_fix "$SYS" "$PROMPT_GAP" || fail=1 ;; esac
exit $fail
