#!/bin/bash
#
# Scenario: /dod:verify's root agent relays ONLY the reviewer's findings[].
#
# Its own observations and implementer notes are handled before verify: a
# real bug gets fixed, polish gets dropped, anything a check already covers
# gets dropped too — never presented as findings or user decisions, never
# passed to dod-reviewer as hints.
#
# Usage: bash dod/tests/scenario/test-root-relay.sh [DOD_VERIFY_SKILL_PATH]

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

  ids=$(printf '%s' "$reply" | jq -c '[.presented_findings[].id] | sort')
  [ "$ids" = '["f1","f2"]' ] || { echo "presented finding ids $ids, want [\"f1\",\"f2\"]"; return 1; }

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

echo "== scenario: root relays only reviewer findings ($SKILL) =="
scenario_run assert_relay "$SYS" "$USER_PROMPT"
