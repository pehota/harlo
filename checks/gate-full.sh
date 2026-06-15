#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO"
fail(){ echo -e "$1" >&2; exit 1; }

TC=$(hcfg '.commands.typecheck'); LN=$(hcfg '.commands.lint')
TEST=$(hcfg '.commands.test');    PC=$(hcfg '.commands.pattern_check')
MUT=$(hcfg '.commands.mutation')

[ -n "$TC" ]   && { eval "$TC"   >/tmp/g_tc.log  2>&1 || fail "typecheck:\n$(tail -n 40 /tmp/g_tc.log)"; }
[ -n "$LN" ]   && { eval "$LN"   >/tmp/g_ln.log  2>&1 || fail "lint:\n$(tail -n 40 /tmp/g_ln.log)"; }
[ -n "$TEST" ] && { eval "$TEST" >/tmp/g_ts.log  2>&1 || fail "tests:\n$(tail -n 60 /tmp/g_ts.log)"; }
[ -n "$PC" ]   && { eval "$PC"   >/tmp/g_pat.log 2>&1 || fail "patterns:\n$(cat /tmp/g_pat.log)"; }

# Mutation testing is slow, so it runs only when the loop asks for the FINAL gate
# (HARNESS_RUN_MUTATION=1), never on every interactive Stop. Its log is surfaced in the PR
# as a review map: surviving mutants = behavior the tests don't actually constrain.
if [ -n "$MUT" ] && [ "${HARNESS_RUN_MUTATION:-0}" = "1" ]; then
  mkdir -p "$REPO/.claude/state"
  eval "$MUT" >"$REPO/.claude/state/mutation.log" 2>&1 \
    || fail "mutation below threshold:\n$(tail -n 40 "$REPO/.claude/state/mutation.log")"
fi

if [ -f tasks.json ]; then
  open=$(jq -r '[.tasks[]|select(.status!="completed" and .status!="blocked")]|length' tasks.json 2>/dev/null || echo 0)
  [ "$open" -gt 0 ] && fail "incomplete: $(jq -r '[.tasks[]|select(.status!="completed" and .status!="blocked")|.id]|join(", ")' tasks.json)"
fi
exit 0
