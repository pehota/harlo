#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$REPO"
fail(){ echo -e "$1" >&2; exit 1; }

TC=$(hcfg '.commands.typecheck'); LN=$(hcfg '.commands.lint')
TEST=$(hcfg '.commands.test');    TREL=$(hcfg '.commands.test_related')
EXTS=$(hcfg '(.test_file_exts // ["ts","tsx","js","jsx"])|join(",")' 'ts,tsx,js,jsx')

[ -n "$TC" ] && { eval "$TC" >/tmp/h_tc.log 2>&1 || fail "Typecheck failed:\n$(tail -n 40 /tmp/h_tc.log)"; }
[ -n "$LN" ] && { eval "$LN" >/tmp/h_ln.log 2>&1 || fail "Lint failed (also the pattern gate):\n$(tail -n 40 /tmp/h_ln.log)"; }

ran=""
if [ -n "$TREL" ]; then
  pat=$(printf '%s' "$EXTS" | sed 's/,/|/g')
  changed=$(git diff --name-only --diff-filter=ACMR 2>/dev/null | grep -E "\.($pat)\$" || true)
  if [ -n "$changed" ]; then
    # shellcheck disable=SC2086
    eval "$TREL $changed" >/tmp/h_ts.log 2>&1 || fail "Related tests failed:\n$(tail -n 60 /tmp/h_ts.log)"
    ran=1
  fi
fi
[ -z "$ran" ] && [ -n "$TEST" ] && { eval "$TEST" >/tmp/h_ts.log 2>&1 || fail "Tests failed:\n$(tail -n 60 /tmp/h_ts.log)"; }
exit 0
