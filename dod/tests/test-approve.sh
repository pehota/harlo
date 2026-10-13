#!/bin/bash
#
# Tests for dod/hooks/approve.sh — PreToolUse auto-approval of dod's own
# CLI (ADR 0005). Allow = exactly the permissionDecision "allow" JSON on
# stdout, exit 0. Fall-through = EMPTY stdout, exit 0 (normal permission
# handling) — never a deny, never a non-zero exit.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"

HOOK="$DIR0/../hooks/approve.sh"
ROOT="$(cd "$DIR0/.." && pwd)"
CLI="$ROOT/scripts/dod.sh"

echo "== approve.sh =="

# run_raw <stdin> — runs the hook on a raw payload; sets OUT and RC.
run_raw() {
  OUT=$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)
  RC=$?
}

# run_cmd <command> [tool_name] — runs the hook on a Bash tool payload.
run_cmd() {
  run_raw "$(jq -n --arg c "$1" --arg t "${2:-Bash}" \
    '{session_id:"s",hook_event_name:"PreToolUse",tool_name:$t,tool_input:{command:$c}}')"
}

allows() {
  run_cmd "$2" "${3:-Bash}"
  if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -c '.hookSpecificOutput' 2>/dev/null)" \
      = '{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"dod: own CLI"}' ]; then
    ok "allow: $1"
  else
    bad "allow: $1" "rc=$RC out=$OUT"
  fi
}

falls_through() {
  run_cmd "$2" "${3:-Bash}"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "fall through: $1"
  else
    bad "fall through: $1" "rc=$RC out=$OUT"
  fi
}

# --- allow ----------------------------------------------------------------------
allows "double-quoted root"            "bash \"$CLI\" contract-read"
allows "single-quoted root"            "bash '$CLI' contract-read"
allows "bare root"                     "bash $CLI contract-read"
for verb in brief-path contract-write contract-read state-set diff-hash cache-get cache-set \
            baseline-worktree changed-standards result-write record-decisions claim; do
  allows "verb $verb" "bash \"$CLI\" $verb"
done
allows "plain args"                    "bash \"$CLI\" state-set verifying"
allows "JSON in single quotes with ; | \$ ( ) & < > \` \\ * ? [ ] { } ~ # and newlines" \
  "bash \"$CLI\" result-write --requirements '[{\"id\":\"review\",\"summary\":\"a; b | c \$(d) && e < f > \`g\` \\\\ * ? [x] {y} ~ #z\",
\"n\":1}]'"
allows "double-quoted arg, no \$ \` \\"   "bash \"$CLI\" cache-get \"npm test; | (x) & y\""
allows "contract-write with mixed quoting" \
  "bash \"$CLI\" contract-write --task \"fix the gate\" --task-source argument --works-when 'It works when it works' --brief '{\"applicable\":false,\"reason\":\"r\"}' --requirements '[]'"
allows "empty single-quoted arg"       "bash \"$CLI\" cache-get ''"
allows "physical root"                 "bash \"$(cd "$ROOT" && pwd -P)/scripts/dod.sh\" claim"

# --- fall through: shell metacharacters outside quotes --------------------------
falls_through ";"                      "bash \"$CLI\" claim; rm -rf ~"
falls_through "&&"                     "bash \"$CLI\" claim && rm -rf x"
falls_through "||"                     "bash \"$CLI\" claim || rm -rf x"
falls_through "|"                      "bash \"$CLI\" contract-read | sh"
falls_through "&"                      "bash \"$CLI\" claim & rm x"
falls_through ">"                      "bash \"$CLI\" contract-read > /etc/x"
falls_through "<"                      "bash \"$CLI\" claim < /etc/passwd"
falls_through "\$( )"                  "bash \"$CLI\" cache-get \$(rm -rf x)"
falls_through "backtick"               "bash \"$CLI\" cache-get \`rm -rf x\`"
falls_through "newline"                "bash \"$CLI\" claim
rm -rf x"
falls_through "trailing newline"       "bash \"$CLI\" claim
"
falls_through "CR"                     "bash \"$CLI\" claim$(printf '\r')rm x"
falls_through "backslash"              "bash \"$CLI\" cache-get a\\;b"
falls_through "glob *"                 "bash \"$CLI\" cache-get *"
falls_through "brace"                  "bash \"$CLI\" cache-get {a,b}"
falls_through "tilde"                  "bash \"$CLI\" cache-get ~"
falls_through "comment #"              "bash \"$CLI\" claim #x"
falls_through "\$VAR"                  "bash \"$CLI\" cache-get \$HOME"
falls_through "\$ inside double quotes" "bash \"$CLI\" cache-get \"\$HOME\""
falls_through "backtick inside double quotes" "bash \"$CLI\" cache-get \"\`id\`\""
falls_through "backslash inside double quotes" "bash \"$CLI\" cache-get \"a\\\"b\""
falls_through "newline inside double quotes" "bash \"$CLI\" cache-get \"a
b\""
falls_through "unbalanced single quote" "bash \"$CLI\" cache-get 'abc"
falls_through "unbalanced double quote" "bash \"$CLI\" cache-get \"abc"
falls_through "quote closes then ;"    "bash \"$CLI\" cache-get 'a'; rm x"

# --- fall through: not exactly our CLI ------------------------------------------
falls_through "other path"             "bash \"/tmp/scripts/dod.sh\" claim"
falls_through "../ traversal into own path" "bash \"$ROOT/../dod/scripts/dod.sh\" claim"
falls_through "other script in the plugin" "bash \"$ROOT/scripts/dod-claim.sh\" . main"
falls_through "prefix env var"         "FOO=1 bash \"$CLI\" claim"
falls_through "sh instead of bash"     "sh \"$CLI\" claim"
falls_through "leading space"          " bash \"$CLI\" claim"
falls_through "double space"           "bash  \"$CLI\" claim"
falls_through "bash option before path" "bash -x \"$CLI\" claim"
falls_through "unknown verb"           "bash \"$CLI\" frobnicate"
falls_through "verb prefix only"       "bash \"$CLI\" clai"
falls_through "verb with suffix"       "bash \"$CLI\" claimx"
falls_through "no verb"                "bash \"$CLI\""
falls_through "path glued to verb"     "bash \"$CLI\"claim"
falls_through "mismatched path quotes" "bash \"$CLI' claim"
falls_through "eval wrapper"           "eval bash \"$CLI\" claim"
falls_through "non-Bash tool"          "bash \"$CLI\" claim" "Write"

# --- fall through: bad input ---------------------------------------------------
run_raw ""
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } && ok "fall through: empty stdin" || bad "fall through: empty stdin" "rc=$RC out=$OUT"
run_raw "not json {"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } && ok "fall through: invalid JSON" || bad "fall through: invalid JSON" "rc=$RC out=$OUT"
run_raw '{"tool_name":"Bash"}'
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } && ok "fall through: no command" || bad "fall through: no command" "rc=$RC out=$OUT"
run_raw '{"tool_name":"Bash","tool_input":{"command":["bash"]}}'
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } && ok "fall through: non-string command" || bad "fall through: non-string command" "rc=$RC out=$OUT"
run_raw "$(jq -nc --arg c "bash \"$CLI\" claim; rm x" '{tool_name:"Bash",tool_input:{command:"x"}}, {tool_name:"Bash",tool_input:{command:("bash \"" + $c)}}')
$(jq -nc --arg c "bash \"$CLI\" claim" '{tool_name:"Bash",tool_input:{command:$c}}')"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } && ok "fall through: several JSON values on stdin" || bad "fall through: several JSON values on stdin" "rc=$RC out=$OUT"
run_raw "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"bash \\\"$CLI\\\" cache-get 'a\\u0000b'\"}}"
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } && ok "fall through: NUL in the command" || bad "fall through: NUL in the command" "rc=$RC out=$OUT"

# --- large JSON args stay fast (linear match, well inside the 10s timeout) -----
BIG=$(head -c 300000 /dev/zero | tr '\0' 'a')
START=$(date +%s)
allows "300KB single-quoted arg" "bash \"$CLI\" result-write --requirements '[\"$BIG\"]'"
[ $(( $(date +%s) - START )) -le 3 ] && ok "300KB arg decided within 3s" || bad "300KB arg decided within 3s" "$(( $(date +%s) - START ))s"

# --- registered as a PreToolUse Bash hook ---------------------------------------
eq "hooks.json: PreToolUse Bash -> approve.sh" 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve.sh"' \
  "$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[0].command' "$DIR0/../hooks/hooks.json")"

echo
echo "approve: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
