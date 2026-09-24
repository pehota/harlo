#!/bin/bash
#
# Scenario: /dod:define is driven by "how will we know it works?".
#
#   (a) settled task, skill-text change: records works_when, every
#       requirement states what it `proves`, and the scenario test is NOT
#       marked N/A — agent-instruction text is observable behavior.
#   (b) ambiguous task ("rework" — to what end?), nothing discussed yet:
#       clarifies with the user first, writes no contract.
#   (c) the same ambiguous task, already settled in the conversation: does
#       not re-ask, proceeds to works_when + requirements.
#   (a)+(c) also: dod-context-collector is spawned first — once the task is
#       clear, before works_when — its verdict is relayed above the table,
#       and contract_write carries it as --brief. (b) spawns nothing.
#
# Usage: bash dod/tests/scenario/test-define-scenario.sh [DOD_DEFINE_SKILL_PATH]

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/scenario-helpers.sh"
SKILL="${1:-$DIR0/../../skills/dod-define/SKILL.md}"

SYS=$(mktemp)
trap 'rm -f "$SYS"' EXIT
{
  echo "You are an agent in a Claude Code session, executing this skill:"
  echo
  cat "$SKILL"
} > "$SYS"

REPO_FACTS=$(cat <<'EOF'
Repo facts (you have no tools in this exercise — describe, don't execute):
- git repo, jq installed, HEAD is abc123. It is the `dod` Claude Code plugin:
  bash hook scripts (dod/scripts/, dod/lib/) plus skill prompts
  (dod/skills/*/SKILL.md) and an agent prompt (dod/agents/dod-reviewer.md).
- Test command: `bash run-tests.sh` (the user confirmed it). No lint, no build.
- No e2e stack exists.
- docs/design-v2.md describes the define/verify flows and the Stop gate.
- Available subagent types: dod-reviewer, dod-context-collector. If you spawn
  dod-context-collector, assume its final message is
  {"applicable":true,"path":".dod/main/brief.md"}. The task key is "main".
EOF
)

REPLY_SHAPE=$(cat <<'EOF'
Describe what you send the user in this turn, and — if you show a
confirmation table — the contract_write call you would make once the user
answers "yes" to it (assume that yes; step 6's wait is honoured by the
table). "clarifying_questions" holds any questions you ask before showing a
table ([] if none). If you stop at questions, confirmation_table and
contract_write are null; if you show a table, contract_write is required.
"actions_in_order" lists everything you do this turn, in order, one short
entry each (e.g. "ask clarifying questions", "spawn <agent type>", "write
works_when", "show confirmation table", "contract_write"). "spawned_agents"
lists every subagent you spawn this turn, in order ([] if none). Reply with
ONE JSON object and nothing else:
{
  "actions_in_order": [ "..." ],
  "spawned_agents": [ {"agent": "<subagent type>", "inputs": { "<name>": "<value>" }} ],
  "text_above_table": "<the line(s) you print directly above \"It works when\", or null>",
  "clarifying_questions": [ "..." ],
  "confirmation_table": [ {"verification": "...", "expected_result": "...", "proves": "..."} ] | null,
  "contract_write": { "<flag, e.g. --task>": <value exactly as you would pass it> } | null
}
EOF
)

PROMPT_A="/dod:define Change dod-verify's skill prompt so the root agent no longer relays implementer notes as findings

$REPO_FACTS
- The change edits dod/skills/dod-verify/SKILL.md.

$REPLY_SHAPE"

PROMPT_B="/dod:define rework the Stop gate's block message

$REPO_FACTS

$REPLY_SHAPE"

PROMPT_C="/dod:define rework the Stop gate's block message

Earlier in this conversation:
  user:  The Stop gate's block message is too long: when a check fails it
         re-prints the whole pass table every single turn.
  agent: So you want the block message cut down to one line naming the
         failing requirement ids, e.g. \"DoD: failing: tests, review — fix and
         run /dod:verify\"? Nothing else about when it blocks changes?
  user:  Yes, exactly that. Only the message text in dod/scripts/dod-gate.sh
         changes; blocking behaviour stays as is.

$REPO_FACTS

$REPLY_SHAPE"

# define__reqs — the reply's --requirements as a JSON array ("[]" if absent).
define__reqs() {
  printf '%s' "$1" | jq -c '(.contract_write // {})["--requirements"] // [] | if type == "string" then fromjson else . end' 2>/dev/null || echo '[]'
}

# define__assert_proofs — shared (a)/(c) assert: no questions, works_when
# recorded, every requirement and every table row states what it proves.
define__assert_proofs() {
  local reply="$1" nq works reqs nreq unproved rows blank
  nq=$(printf '%s' "$reply" | jq '.clarifying_questions // [] | length')
  [ "$nq" -eq 0 ] || { echo "asked $nq clarifying question(s) on a settled task"; return 1; }

  works=$(printf '%s' "$reply" | jq -r '(.contract_write // {})["--works-when"] // ""')
  [ -n "$works" ] || { echo "no --works-when in contract_write"; return 1; }

  reqs=$(define__reqs "$reply")
  nreq=$(printf '%s' "$reqs" | jq 'length')
  [ "$nreq" -gt 0 ] || { echo "no requirements"; return 1; }
  unproved=$(printf '%s' "$reqs" | jq -r '[.[] | select((.proves // "") == "") | .id] | join(",")')
  [ -z "$unproved" ] || { echo "requirements without proves: $unproved"; return 1; }

  rows=$(printf '%s' "$reply" | jq '.confirmation_table // [] | length')
  blank=$(printf '%s' "$reply" | jq '[.confirmation_table // [] | .[] | select((.proves // "") == "")] | length')
  [ "$rows" -ge "$nreq" ] || { echo "$rows table rows for $nreq requirements"; return 1; }
  [ "$blank" -eq 0 ] || { echo "$blank table rows with empty proves"; return 1; }
}

# define__assert_collector — (a)/(c): dod-context-collector spawned first,
# before works_when; its verdict shown above the table and passed as --brief.
define__assert_collector() {
  local reply="$1" first ic iw brief
  first=$(printf '%s' "$reply" | jq -r '.spawned_agents[0].agent // ""')
  [ "$first" = "dod-context-collector" ] || { echo "first spawned agent '$first', want dod-context-collector"; return 1; }
  ic=$(printf '%s' "$reply" | jq '[.actions_in_order // [] | to_entries[] | select(.value | test("context.collector"; "i")) | .key] | first // -1')
  iw=$(printf '%s' "$reply" | jq '[.actions_in_order // [] | to_entries[] | select((.value | test("works.when"; "i")) and (.value | test("context.collector"; "i") | not)) | .key] | first // -1')
  [ "$ic" -ge 0 ] || { echo "collector spawn not in actions_in_order"; return 1; }
  [ "$iw" -ge 0 ] && [ "$ic" -lt "$iw" ] || { echo "collector spawned at action $ic, works_when at $iw — want before"; return 1; }
  brief=$(printf '%s' "$reply" | jq -c '(.contract_write // {})["--brief"] // empty | if type == "string" then fromjson else . end' 2>/dev/null)
  [ "$(printf '%s' "$brief" | jq -r '.path // ""' 2>/dev/null)" = ".dod/main/brief.md" ] || { echo "contract_write --brief is '$brief', want the collector's verdict"; return 1; }
  printf '%s' "$reply" | jq -r '.text_above_table // ""' | grep -q '\.dod/main/brief\.md' || { echo "brief path not shown above the table"; return 1; }
}

assert_settled_skill_change() {
  local reply reqs sc_app sc_cmd
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }
  define__assert_proofs "$reply" || return 1
  define__assert_collector "$reply" || return 1

  reqs=$(define__reqs "$reply")
  sc_app=$(printf '%s' "$reqs" | jq -r '.[] | select(.id == "scenario") | .applicable')
  sc_cmd=$(printf '%s' "$reqs" | jq -r '.[] | select(.id == "scenario") | .cmd // ""')
  [ "$sc_app" = "true" ] || { echo "scenario applicable=$sc_app, want true"; return 1; }
  [ -n "$sc_cmd" ] || { echo "scenario has no cmd"; return 1; }
}

assert_ambiguous_clarifies() {
  local reply nq cw
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }
  nq=$(printf '%s' "$reply" | jq '.clarifying_questions // [] | length')
  cw=$(printf '%s' "$reply" | jq -r '.contract_write // empty | tostring')
  [ "$nq" -gt 0 ] || { echo "no clarifying questions on an ambiguous task"; return 1; }
  [ -z "$cw" ] || { echo "wrote a contract before clarifying"; return 1; }
  [ "$(printf '%s' "$reply" | jq '.spawned_agents // [] | length')" -eq 0 ] || { echo "spawned a subagent on an unclear task"; return 1; }
}

assert_settled_ambiguous() {
  local reply
  reply=$(cat)
  printf '%s' "$reply" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }
  define__assert_proofs "$reply" || return 1
  define__assert_collector "$reply"
}

fail=0
echo "== scenario (a): settled skill-text task -> works_when, proofs, scenario applies ($SKILL) =="
scenario_run assert_settled_skill_change "$SYS" "$PROMPT_A" || fail=1
echo "== scenario (b): ambiguous task -> clarify, no contract ($SKILL) =="
scenario_run assert_ambiguous_clarifies "$SYS" "$PROMPT_B" || fail=1
echo "== scenario (c): ambiguous task already settled -> no re-ask, proceeds ($SKILL) =="
scenario_run assert_settled_ambiguous "$SYS" "$PROMPT_C" || fail=1
exit $fail
