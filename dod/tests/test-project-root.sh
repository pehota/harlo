#!/bin/bash
#
# Tests for where .dod/ lives: hooks and skills must resolve ONE directory,
# <git top-level>/.dod, whichever subdir the session was launched from or
# the Bash tool's cwd sits in.
#
# Regression (dogfood, Oct 1): hooks keyed on CLAUDE_PROJECT_DIR (the repo
# root) while skills keyed on $PWD (<root>/ship, where the agent had cd'd).
# /dod:define wrote ship/.dod/main/contract.json, /dod:verify wrote its
# result + claim there too, and the gate — reading <root>/.dod — never saw
# any of it. CLAUDE_PROJECT_DIR is not in the Bash tool env, so the skills
# resolve the root themselves (dod_repo_root "$PWD"), and the hooks
# normalise CLAUDE_PROJECT_DIR the same way.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/result.sh"
. "$DIR0/../lib/state.sh"
. "$DIR0/../lib/gitref.sh"

GATE="$DIR0/../hooks/gate.sh"
TRACK="$DIR0/../hooks/track.sh"
PROMPT="$DIR0/../hooks/prompt.sh"
DEFINE_SKILL="$DIR0/../skills/dod-define/SKILL.md"
VERIFY_SKILL="$DIR0/../skills/dod-verify/SKILL.md"
export CLAUDE_PLUGIN_ROOT="$DIR0/.."

echo "== project root (.dod location) =="

NA_BRIEF='{"applicable":false,"reason":"test fixture"}'
REQS='[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol","proves":"test fixture"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"test fixture","applicable":false,"reason":"test fixture"}]'

REPO=$(dod__test_make_repo)
mkdir -p "$REPO/ship"
echo "v1" > "$REPO/ship/x.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m ship
ROOT=$(cd "$REPO" && pwd -P)
SUB="$ROOT/ship"

# --- skill side: cwd = subdir, no CLAUDE_PROJECT_DIR (Bash tool env) --------
dod__test_skill_line "$DEFINE_SKILL" 'REPO=$(dod_repo_root "$PWD")'; L_REPO="$SKILL_LINE"
dod__test_skill_line "$DEFINE_SKILL" 'TASK_KEY=$(dod_task_key "$REPO")'; L_KEY="$SKILL_LINE"
dod__test_skill_line "$DEFINE_SKILL" 'contract_write "$REPO/.dod/$TASK_KEY/contract.json"'; L_CW="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" 'REPO=$(dod_repo_root "$PWD")'
dod__test_skill_line "$VERIFY_SKILL" 'TASK_KEY=$(dod_task_key "$REPO")'
dod__test_skill_line "$VERIFY_SKILL" 'contract_read "$REPO/.dod/$TASK_KEY/contract.json"'; L_CR="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" 'RFILE="$REPO/.dod/$TASK_KEY/result.json"'; L_RF="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-claim.sh" "$REPO" "$TASK_KEY"'; L_CLAIM="$SKILL_LINE"

SKILL_OUT=$(
  cd "$SUB" || exit 1
  unset CLAUDE_PROJECT_DIR
  eval "$L_REPO"; eval "$L_KEY"
  eval "$L_CW"' --task-key "$TASK_KEY" --task t --task-source argument --session-id s --works-when w --baseline-sha "$(git rev-parse HEAD)" --brief "$NA_BRIEF" --requirements "$REQS"'
  eval "$L_CR"
  eval "$L_RF"
  eval "$L_CLAIM"
  printf '%s|%s|%s|%s' "$REPO" "$TASK_KEY" "$CONTRACT_STATUS" "$RFILE"
)
eq "skill: REPO resolves to the git top-level from a subdir" "$ROOT" "${SKILL_OUT%%|*}"
eq "skill: contract readable back at <root>/.dod" "open" "$(printf '%s' "$SKILL_OUT" | cut -d'|' -f3)"
eq "skill: result path is under <root>/.dod" "$ROOT/.dod/main/result.json" "${SKILL_OUT##*|}"
[ -f "$ROOT/.dod/main/contract.json" ] && ok "skill: contract written to <root>/.dod" || bad "skill: contract written to <root>/.dod" "missing"
state_read "$ROOT/.dod/main/state.json"
eq "skill: claim armed the latch under <root>/.dod" "true" "$STATE_LATCHED"

# --- hooks: CLAUDE_PROJECT_DIR = a subdir (session launched in ship/) -------
OUT=$(cd "$SUB" && CLAUDE_PROJECT_DIR="$SUB" bash "$TRACK" <<JSON
{"session_id":"sid-1","cwd":"$SUB","prompt_id":"p9","tool_name":"Edit","tool_input":{"file_path":"$SUB/x.txt"}}
JSON
)
eq "track (subdir project dir): no nudge, sees the root contract" "" "$OUT"
if state_has_edit_for_prompt "$ROOT/.dod/main/state.json" "p9"; then
  ok "track (subdir project dir): edit logged to <root>/.dod state"
else
  bad "track (subdir project dir): edit logged to <root>/.dod state" "not logged"
fi

OUT=$(cd "$SUB" && CLAUDE_PROJECT_DIR="$SUB" bash "$PROMPT" <<JSON
{"session_id":"sid-1","cwd":"$SUB"}
JSON
)
eq "prompt (subdir project dir): no 'no DoD open' nudge, sees the root contract" "" "$OUT"

OUT=$(cd "$SUB" && CLAUDE_PROJECT_DIR="$SUB" bash "$GATE" <<JSON
{"session_id":"sid-1","cwd":"$SUB","prompt_id":"p9","stop_hook_active":false}
JSON
)
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "gate (subdir project dir): gates the root contract (no result yet -> block)"
else
  bad "gate (subdir project dir): gates the root contract (no result yet -> block)" "$OUT"
fi

# --- hooks: no CLAUDE_PROJECT_DIR, cwd = subdir ($PWD fallback) -------------
OUT=$(cd "$SUB" && env -u CLAUDE_PROJECT_DIR bash "$GATE" <<JSON
{"session_id":"sid-1","cwd":"$SUB","prompt_id":"p9","stop_hook_active":false}
JSON
)
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  ok "gate (\$PWD fallback in a subdir): gates the root contract"
else
  bad "gate (\$PWD fallback in a subdir): gates the root contract" "$OUT"
fi

# --- track: a write to the root .dod from a subdir launch is bookkeeping ----
OUT=$(cd "$SUB" && CLAUDE_PROJECT_DIR="$SUB" bash "$TRACK" <<JSON
{"session_id":"sid-1","cwd":"$SUB","prompt_id":"p10","tool_name":"Write","tool_input":{"file_path":"$ROOT/.dod/main/result.json"}}
JSON
)
if state_has_edit_for_prompt "$ROOT/.dod/main/state.json" "p10"; then
  bad "track: a write under <root>/.dod is never logged as an edit" "logged"
else
  ok "track: a write under <root>/.dod is never logged as an edit"
fi

# --- dod-claim.sh normalises a subdir repo arg itself -------------------------
# A caller passing <root>/ship would arm the latch in ship/.dod/, which the
# gate (reading <root>/.dod) never sees.
state_disarm_latch "$ROOT/.dod/main/state.json"
bash "$DIR0/../scripts/dod-claim.sh" "$SUB" "main" >/dev/null 2>&1
state_read "$ROOT/.dod/main/state.json"
eq "dod-claim.sh: subdir arg arms the latch under <root>/.dod" "true" "$STATE_LATCHED"

if [ ! -e "$SUB/.dod" ]; then
  ok "nothing written under <subdir>/.dod"
else
  bad "nothing written under <subdir>/.dod" "$(find "$SUB/.dod" 2>/dev/null | head -5 | tr '\n' ' ')"
fi

echo
echo "project-root: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
