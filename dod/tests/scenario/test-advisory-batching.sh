#!/bin/bash
#
# Scenario: /dod:verify raises advisory findings only from the final
# passing round's review, once, as a fix/skip decision the contract waits on.
#
#   (fail) a failing round: only failures and blocking findings are
#          presented; its advisory is neither presented nor asked.
#   (decide) a passing round with advisories: each is presented once and
#          asked as a fix/skip decision with a recommendation; the contract
#          stays open awaiting the user's reply.
#   (after-fix) the user decided (fix a1, skip a2); the re-verify round
#          passes with a new advisory a9: the reviewer is asked for blocking
#          findings only, a9 is not asked as a decision, and the contract
#          closes.
#   (escalate) the gate escalates: the last review's advisory is presented
#          once alongside the unresolved finding, not asked as a decision
#          (nothing records one), and the agent stops.
#
# Usage: bash dod/tests/scenario/test-advisory-batching.sh [DOD_VERIFY_SKILL_PATH]

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/scenario-helpers.sh"
SKILL="${1:-$DIR0/../../skills/dod-verify/SKILL.md}"

SYS=$(mktemp)
trap 'rm -f "$SYS"' EXIT
{
  echo "You are the root (orchestrating) agent in a Claude Code session. An open DoD"
  echo "contract exists and the implementation is back from the subagents. You are"
  echo "now executing this skill:"
  echo
  cat "$SKILL"
} > "$SYS"

REPLY_SHAPE=$(cat <<'EOF'
Reply with ONE JSON object and nothing else:
{
  "presented_findings":  [ {"id": "<finding id>", "file": "<file>", "line": <line>, "summary": "<summary as you show it>"} ],
  "user_decisions":      [ {"finding_id": "<finding id, or null>", "text": "<what you ask the user to decide>", "recommendation": "<fix or skip, or null if you give none>"} ],
  "reviewer_blocking_only": <true if you tell dod-reviewer to report blocking findings only, else false (also false if you spawn none)>,
  "contract_action":     "<the contract after this turn: close | await_decision | keep_open | escalated>"
}
"presented_findings" lists every reviewer finding you show the user this turn.
EOF
)
TO_END="Walk through everything you do from step 5 to the end of this turn. $REPLY_SHAPE"

PROMPT_FAIL=$(cat <<'EOF'
Situation (you have no tools in this exercise — describe, don't execute):

The task: add a --dry-run flag to a backup script. Contract baseline_sha is
base01. No decisions are recorded in .dod/<task>/state.json. Steps 1-4 are
done: the diff hash is h1; the "tests" check (`bash test.sh`) FAILED (exit 1)
and passes at baseline (new failure).

When dod-reviewer is spawned this round it returns exactly this final message:
{"findings":[
  {"id":"b1","severity":"blocking","file":"backup.sh","line":42,"summary":"--dry-run still deletes the oldest archive","failure_scenario":"user runs --dry-run, loses a backup","requirement_id":"review"},
  {"id":"a3","severity":"advisory","file":"README.md","line":7,"summary":"flag list is not alphabetical","failure_scenario":"none, cosmetic","requirement_id":"review"}
],"verdict":"fail"}

EOF
)
PROMPT_FAIL="$PROMPT_FAIL
$TO_END"

PROMPT_DECIDE=$(cat <<'EOF'
Situation (you have no tools in this exercise — describe, don't execute):

The task: add a --dry-run flag to a backup script. Contract baseline_sha is
base01. No decisions are recorded in .dod/<task>/state.json. Steps 1-4 are
done: the diff hash is h2; the "tests" check (`bash test.sh`) PASSED (exit 0).

When dod-reviewer is spawned this round it returns exactly this final message:
{"findings":[
  {"id":"a1","severity":"advisory","file":"backup.sh","line":10,"summary":"log prefix differs from the rest of the script","failure_scenario":"none, cosmetic","requirement_id":"review"},
  {"id":"a2","severity":"advisory","file":"lib/paths.sh","line":20,"summary":"helper name `mkp` is vague","failure_scenario":"none, readability","requirement_id":"review"}
],"verdict":"pass"}

EOF
)
PROMPT_DECIDE="$PROMPT_DECIDE
$TO_END"

PROMPT_AFTER_FIX=$(cat <<'EOF'
Situation (you have no tools in this exercise — describe, don't execute):

The task: add a --dry-run flag to a backup script. Contract baseline_sha is
base01. The previous /dod:verify passed every requirement and its review
raised two advisories, a1 and a2; you asked the user to decide fix or skip
for each. The user replied "fix a1, skip a2". You recorded that, and
.dod/<task>/state.json now holds:
"decisions":[{"id":"a1","decision":"fix"},{"id":"a2","decision":"skip"}]
Your subagent fixed a1, and you are now running /dod:verify again.

Steps 1-4 are done: the diff hash is h4; the "tests" check (`bash test.sh`)
PASSED (exit 0).

When dod-reviewer is spawned this round it returns exactly this final message:
{"findings":[
  {"id":"a9","severity":"advisory","file":"backup.sh","line":55,"summary":"usage text wraps past 80 columns","failure_scenario":"none, cosmetic","requirement_id":"review"}
],"verdict":"pass"}

EOF
)
PROMPT_AFTER_FIX="$PROMPT_AFTER_FIX
$TO_END"

PROMPT_ESCALATE=$(cat <<'EOF'
Situation (you have no tools in this exercise — describe, don't execute):

The task: add a --dry-run flag to a backup script. Contract baseline_sha is
base01. Last turn you ran /dod:verify (all steps 1-8), showed its pass table,
and stopped. The Stop hook then blocked with this reason:

DOD GATE — BUDGET EXHAUSTED after 2 round(s). verification still failing. Report the unresolved findings and the advisories of the last review to the user, then stop. Do not attempt another fix.

The current .dod/<task>/result.json (written by that /dod:verify) is:
{"diff_hash":"h2","baseline_sha":"base01","round":2,
 "requirements":[
  {"id":"tests","type":"check","verdict":"pass","cmd":"bash test.sh","exit":0},
  {"id":"review","type":"judgement","verdict":"fail","findings":[
    {"id":"b1","severity":"blocking","file":"backup.sh","line":42,"summary":"--dry-run still deletes the oldest archive","requirement_id":"review"},
    {"id":"a1","severity":"advisory","file":"backup.sh","line":10,"summary":"log prefix differs from the rest of the script","requirement_id":"review"}]}],
 "summary":{"pass":1,"blocking_fail":1,"advisory":0,"waived":0,"na":0}}

EOF
)
PROMPT_ESCALATE="$PROMPT_ESCALATE
Describe what you show the user in this turn. $REPLY_SHAPE"

# batching__json — reject a non-JSON reply up front.
batching__json() {
  printf '%s' "$1" | jq -e . >/dev/null 2>&1 || { echo "reply is not JSON"; return 1; }
}

# batching__field <reply> <jq filter> <want> <label>
batching__field() {
  local got
  got=$(printf '%s' "$1" | jq -c "$2")
  [ "$got" = "$3" ] || { echo "$4 $got, want $3"; return 1; }
}

assert_failing_round() {
  local reply
  reply=$(cat)
  batching__json "$reply" || return 1
  batching__field "$reply" '[.presented_findings[]?.id] | sort' '["b1"]' "presented finding ids" || return 1
  batching__field "$reply" '[.user_decisions[]?.finding_id | select(. != null)]' '[]' "findings asked as decisions" || return 1
  batching__field "$reply" '.contract_action' '"keep_open"' "contract_action" || return 1
}

assert_decision_round() {
  local reply
  reply=$(cat)
  batching__json "$reply" || return 1
  # Exact lists, not unique: a finding shown or asked twice must fail.
  batching__field "$reply" '[.presented_findings[]?.id] | sort' '["a1","a2"]' "presented finding ids" || return 1
  batching__field "$reply" '[.user_decisions[]?.finding_id] | sort' '["a1","a2"]' "decision finding ids" || return 1
  batching__field "$reply" '[.user_decisions[].recommendation] | all(. == "fix" or . == "skip")' 'true' "every decision has a fix/skip recommendation:" || return 1
  batching__field "$reply" '.reviewer_blocking_only' 'false' "reviewer_blocking_only" || return 1
  batching__field "$reply" '.contract_action' '"await_decision"' "contract_action" || return 1
}

assert_after_fix_round() {
  local reply
  reply=$(cat)
  batching__json "$reply" || return 1
  batching__field "$reply" '[.user_decisions[]?.finding_id | select(. != null)]' '[]' "findings asked as decisions" || return 1
  batching__field "$reply" '.reviewer_blocking_only' 'true' "reviewer_blocking_only" || return 1
  batching__field "$reply" '.contract_action' '"close"' "contract_action" || return 1
}

assert_escalated_round() {
  local reply
  reply=$(cat)
  batching__json "$reply" || return 1
  batching__field "$reply" '[.presented_findings[]?.id] | sort' '["a1","b1"]' "presented finding ids" || return 1
  batching__field "$reply" '[.user_decisions[]?.finding_id | select(. != null)]' '[]' "findings asked as decisions" || return 1
  batching__field "$reply" '.contract_action' '"escalated"' "contract_action" || return 1
}

fail=0
echo "== scenario (fail): failing round presents no advisory ($SKILL) =="
scenario_run assert_failing_round "$SYS" "$PROMPT_FAIL" || fail=1
echo "== scenario (decide): passing round asks one fix/skip decision and awaits it ($SKILL) =="
scenario_run assert_decision_round "$SYS" "$PROMPT_DECIDE" || fail=1
echo "== scenario (after-fix): post-decision round is blocking-only and closes ($SKILL) =="
scenario_run assert_after_fix_round "$SYS" "$PROMPT_AFTER_FIX" || fail=1
echo "== scenario (escalate): escalated round presents the last review's advisory ($SKILL) =="
scenario_run assert_escalated_round "$SYS" "$PROMPT_ESCALATE" || fail=1
exit $fail
