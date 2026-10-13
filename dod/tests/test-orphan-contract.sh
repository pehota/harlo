#!/bin/bash
#
# Scenario: the Oct 1 dogfood orphan, end to end, through the REAL hooks and
# the skill-side commands the SKILL.md files actually tell the agent to run
# (each one asserted verbatim in its SKILL.md before it is eval'd).
#
# Setup as it happened: session launched at the repo root
# (CLAUDE_PROJECT_DIR=<root>), the agent's Bash tool cd'd into <root>/ship.
# Three bugs compounded:
#   C. the diff hash from ship/ hashed every file as MISSING (content-blind);
#   A. the skills wrote contract/result/claim under ship/.dod while the hooks
#      read <root>/.dod, so the gate never saw them;
#   B. a claim latched in one session kept gating every later session, even
#      one with zero edits.
#
# Part 1: the happy path from a subdir must close the contract ("passed")
#         and leave exactly one .dod, at the root.
# Part 2: a latched open contract claimed by session X (then killed) must not
#         block session Y's edit-free Stop.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/contract.sh"
. "$DIR0/../lib/result.sh"
. "$DIR0/../lib/state.sh"
. "$DIR0/../lib/gitref.sh"

GATE="$DIR0/../hooks/gate.sh"
TRACK="$DIR0/../hooks/track.sh"
DEFINE_SKILL="$DIR0/../skills/dod-define/SKILL.md"
VERIFY_SKILL="$DIR0/../skills/dod-verify/SKILL.md"
export CLAUDE_PLUGIN_ROOT="$DIR0/.."

echo "== scenario: orphan contract (subdir cwd, cross-session latch) =="

NA_BRIEF='{"applicable":false,"reason":"scenario fixture"}'
REQS='[{"id":"tests","type":"check","cmd":"true","expect_exit":0,"source":"protocol","proves":"scenario"},{"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"scenario","applicable":false,"reason":"scenario"},{"id":"scenario","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"scenario","applicable":false,"reason":"scenario"},{"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"protocol","proves":"scenario","applicable":false,"reason":"scenario"}]'
PASS_REQS='[{"id":"tests","type":"check","verdict":"pass","cmd":"true","exit":0},{"id":"review","type":"judgement","verdict":"pass","findings":[]}]'

# --- the skill commands, each asserted verbatim in its SKILL.md --------------
# Each is one dod.sh call; every call below runs in its own fresh shell, as
# the Bash tool does — nothing carried between calls.
CLI_LINE='bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod.sh"'
dod__test_skill_line "$DEFINE_SKILL" "$CLI_LINE contract-write"; D_CW="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" "$CLI_LINE contract-read"; V_CR="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" "$CLI_LINE result-write --requirements"; V_RW="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" "$CLI_LINE state-set idle"; V_IDLE="$SKILL_LINE"
dod__test_skill_line "$VERIFY_SKILL" "$CLI_LINE claim"; V_CLAIM="$SKILL_LINE"

# run_skill <cwd> <session> <line> — one Bash tool call: cwd as given, no
# CLAUDE_PROJECT_DIR, the session's CLAUDE_CODE_SESSION_ID.
run_skill() {
  (
    cd "$1" || exit 1
    unset CLAUDE_PROJECT_DIR
    export CLAUDE_CODE_SESSION_ID="$2"
    eval "$3"
  ) >/dev/null
}

# skill_define <cwd> <session> — /dod:define step 8 from the Bash tool:
# cwd as given, no CLAUDE_PROJECT_DIR, the session's CLAUDE_CODE_SESSION_ID.
skill_define() {
  run_skill "$1" "$2" "$D_CW"' --task "scenario task" --task-source argument --works-when "It works when the gate closes" --brief "$NA_BRIEF" --requirements "$REQS"'
}

# skill_verify <cwd> <session> — /dod:verify steps 1, 6, 7 with every
# requirement passing: read, write result (the CLI hashes the diff and
# computes the round), mark idle, claim.
skill_verify() {
  run_skill "$1" "$2" "$V_CR"
  run_skill "$1" "$2" "$V_RW"' "$PASS_REQS"'
  run_skill "$1" "$2" "$V_IDLE"
  run_skill "$1" "$2" "$V_CLAIM"
}

# skill_claim <cwd> <session> — dod-verify step 7 alone.
skill_claim() {
  run_skill "$1" "$2" "$V_CLAIM"
}

# hook_track <root> <cwd> <session> <prompt_id> <file> — PostToolUse Edit.
hook_track() {
  ( cd "$2" && CLAUDE_PROJECT_DIR="$1" bash "$TRACK" ) <<JSON
{"session_id":"$3","cwd":"$2","prompt_id":"$4","tool_name":"Edit","tool_input":{"file_path":"$5"}}
JSON
}

# hook_stop <root> <cwd> <session> <prompt_id> — Stop.
hook_stop() {
  ( cd "$2" && CLAUDE_PROJECT_DIR="$1" bash "$GATE" ) <<JSON
{"session_id":"$3","cwd":"$2","prompt_id":"$4","stop_hook_active":false}
JSON
}

is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

REPO=$(dod__test_make_repo)
mkdir -p "$REPO/ship"
echo "v1" > "$REPO/ship/x.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m ship
ROOT=$(cd "$REPO" && pwd -P)
SUB="$ROOT/ship"

# --- part 1: define -> edit -> verify -> Stop, all from ship/ ---------------
skill_define "$SUB" "sid-X"
[ -f "$ROOT/.dod/main/contract.json" ] && ok "define from ship/: contract at <root>/.dod" \
  || bad "define from ship/: contract at <root>/.dod" "missing"

echo "v2" >> "$SUB/x.txt"
hook_track "$ROOT" "$SUB" "sid-X" "px1" "$SUB/x.txt" >/dev/null

OUT=$(hook_stop "$ROOT" "$SUB" "sid-X" "px1")
if is_block "$OUT"; then
  ok "Stop after an edit, before verify: blocks"
else
  bad "Stop after an edit, before verify: blocks" "$OUT"
fi

skill_verify "$SUB" "sid-X"
OUT=$(hook_stop "$ROOT" "$SUB" "sid-X" "px2")
eq "Stop after verify from ship/: releases" "" "$OUT"
eq "contract status after verify from ship/" "passed" \
  "$(jq -r '.status' "$ROOT/.dod/main/contract.json" 2>/dev/null)"

# content-aware hash from ship/: the same paths with new content must not
# match the stored result.
REPO_C=$(dod__test_make_repo)
mkdir -p "$REPO_C/ship"; echo "v1" > "$REPO_C/ship/x.txt"
git -C "$REPO_C" add -A; git -C "$REPO_C" commit -q -m ship
ROOT_C=$(cd "$REPO_C" && pwd -P)
skill_define "$ROOT_C/ship" "sid-X"
echo "v2" >> "$ROOT_C/ship/x.txt"
hook_track "$ROOT_C" "$ROOT_C/ship" "sid-X" "pc1" "$ROOT_C/ship/x.txt" >/dev/null
skill_verify "$ROOT_C/ship" "sid-X"
echo "v3 — unverified content, same path" >> "$ROOT_C/ship/x.txt"
hook_track "$ROOT_C" "$ROOT_C/ship" "sid-X" "pc2" "$ROOT_C/ship/x.txt" >/dev/null
OUT=$(hook_stop "$ROOT_C" "$ROOT_C/ship" "sid-X" "pc2")
if is_block "$OUT"; then
  ok "Stop after editing verified content (same path): stale result blocks"
else
  bad "Stop after editing verified content (same path): stale result blocks" "$OUT"
fi

# exactly one .dod, at the root
DODS=$(cd "$ROOT" && find . -name .dod -type d | sort | tr '\n' ' ')
eq "only <root>/.dod exists" "./.dod " "$DODS"

# --- part 2: Oct 1 orphan — session X claims and dies, session Y stops ------
git -C "$ROOT" checkout -q -b feature/orphan
skill_define "$SUB" "sid-X"
echo "half-done" >> "$SUB/x.txt"
hook_track "$ROOT" "$SUB" "sid-X" "px3" "$SUB/x.txt" >/dev/null
skill_claim "$SUB" "sid-X"
state_read "$ROOT/.dod/feature-orphan/state.json"
eq "orphan: latch armed by session X" "true" "$STATE_LATCHED"

OUT=$(hook_stop "$ROOT" "$SUB" "sid-Y" "py1")
eq "orphan: session Y, zero edits -> Stop releases" "" "$OUT"
eq "orphan: contract left open (no TTL)" "open" \
  "$(jq -r '.status' "$ROOT/.dod/feature-orphan/contract.json" 2>/dev/null)"

OUT=$(hook_stop "$ROOT" "$SUB" "sid-X" "px4")
if is_block "$OUT"; then
  ok "orphan: session X's own Stop still gates its claim"
else
  bad "orphan: session X's own Stop still gates its claim" "$OUT"
fi

hook_track "$ROOT" "$SUB" "sid-Y" "py2" "$SUB/x.txt" >/dev/null
OUT=$(hook_stop "$ROOT" "$SUB" "sid-Y" "py2")
if is_block "$OUT"; then
  ok "orphan: session Y that edits the task still gets gated"
else
  bad "orphan: session Y that edits the task still gets gated" "$OUT"
fi

echo
echo "orphan-contract: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
