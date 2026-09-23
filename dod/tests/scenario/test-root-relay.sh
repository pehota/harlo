#!/bin/bash
#
# Scenario: /dod:verify's root agent relays ONLY the reviewer's findings[].
#
# Its own observations and implementer notes are handled before verify: a
# real bug gets fixed, polish gets dropped — never presented as findings or
# user decisions, never passed to dod-reviewer as hints.
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

The task: remove the "Cleanup" option from the CLI's exit menu.

Notes returned by the implementer subagent:
- "could mention Ctrl-D in the prompt"
- "README line 32 looks stale"

Your own observation while reading the changeset: farewell() still tells the
user to "choose Cleanup", but that option was removed.

When dod-reviewer is spawned it returns exactly this final message:
{"findings":[
  {"id":"f1","severity":"blocking","file":"README.md","line":10,"summary":"README contradicts spec: still documents the removed Cleanup option","failure_scenario":"user follows README, option missing","requirement_id":"docs"},
  {"id":"f2","severity":"advisory","file":"bin/run.sh","line":4,"summary":"unquoted path variable","failure_scenario":"path with spaces breaks","requirement_id":"review"}
],"verdict":"fail"}

Walk through everything you do from now until you show the user the pass
table. Reply with ONE JSON object and nothing else:
{
  "pre_verify_actions": [ {"item": "<what>", "action": "<what you do with it>", "disposition": "fix_before_verify" | "drop" | "present"} ],
  "reviewer_inputs":    { "<input name>": "<the literal value you pass, no commentary>" },
  "presented_findings": [ {"id": "<finding id or null>", "summary": "<text>", "source": "<where it came from>"} ],
  "user_decisions":     [ "<each thing you ask the user to decide>" ]
}
EOF
)

assert_relay() {
  local reply ids leaked farewell_disp other_disps
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }

  ids=$(printf '%s' "$reply" | jq -c '[.presented_findings[].id] | sort')
  [ "$ids" = '["f1","f2"]' ] || { echo "presented finding ids $ids, want [\"f1\",\"f2\"]"; return 1; }

  leaked=$(printf '%s' "$reply" | jq -r '[.presented_findings, .user_decisions, .reviewer_inputs] | tostring' \
    | grep -ioE 'ctrl-?d|line 32|farewell|choose cleanup' | head -1)
  [ -z "$leaked" ] || { echo "observation leaked to findings/decisions/reviewer: '$leaked'"; return 1; }

  farewell_disp=$(printf '%s' "$reply" | jq -r '.pre_verify_actions[] | select(.item | test("farewell";"i")) | .disposition')
  [ "$farewell_disp" = "fix_before_verify" ] || { echo "farewell() disposition '$farewell_disp', want fix_before_verify"; return 1; }

  other_disps=$(printf '%s' "$reply" | jq -r '.pre_verify_actions[] | select(.item | test("ctrl-?d|line 32";"i")) | .disposition')
  [ -z "$(printf '%s\n' "$other_disps" | grep -ix present)" ] || { echo "Ctrl-D/README-32 note presented instead of dropped"; return 1; }
}

echo "== scenario: root relays only reviewer findings ($SKILL) =="
scenario_run assert_relay "$SYS" "$USER_PROMPT"
