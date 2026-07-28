#!/bin/bash
#
# test-version.sh — pure unit tests for version-lib.sh (no git needed).
# Sources the lib and asserts level parsing, 0.x/standard bump math, vlib_ge
# ordering, and malformed-version rejection. Exits non-zero on any failure.

set -u
cd "$(dirname "$0")" || exit 1
. ./version-lib.sh || { echo "cannot source version-lib.sh" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

# Assert vlib_level_from_subjects over a set of records.
# Args: <expected> <desc> <rec1> [rec2...]  — each rec is a full record
# (subject on line 1, optional body lines after \n). Records are NUL-joined.
assert_level() {
  local expected="$1" desc="$2"; shift 2
  local stream="" r
  for r in "$@"; do
    stream+="$r"$'\0'
  done
  local got
  got="$(printf '%s' "$stream" | vlib_level_from_subjects)"
  if [ "$got" = "$expected" ]; then ok "$desc (=$got)"; else bad "$desc: expected $expected got $got"; fi
}

assert_bump() {
  local cur="$1" level="$2" expected="$3"
  local got
  got="$(vlib_bump "$cur" "$level")"
  if [ "$got" = "$expected" ]; then ok "bump($cur,$level)=$got"; else bad "bump($cur,$level): expected $expected got $got"; fi
}

# ---- level parsing ---------------------------------------------------------
assert_level none "docs: x -> none" "docs: x"
assert_level fix  "fix: y -> fix"   "fix: y"
assert_level feat "feat: z -> feat" "feat: z"
assert_level breaking "feat!: z -> breaking" "feat!: z"
assert_level breaking "BREAKING CHANGE body -> breaking" $'feat: add thing\n\nBREAKING CHANGE: drops old api'
assert_level feat "mixed [feat, fix] -> feat" "feat: a" "fix: b"
assert_level breaking "mixed [feat!, feat] -> breaking" "feat!: a" "feat: b"
assert_level feat "scoped feat(x): -> feat" "feat(x): scoped"
# extra guards
assert_level fix  "scoped fix(api): -> fix"  "fix(api): scoped"
assert_level fix  "perf: -> fix-level"       "perf: faster"
assert_level breaking "scoped bang fix(x)!: -> breaking" "fix(x)!: boom"
assert_level none "chore/refactor/test -> none" "chore: c" "refactor: r" "test: t"
# `git log --format='%s%n%b%x00'` puts a newline BETWEEN entries, so records
# after the first arrive with a leading newline; the lib must strip one so the
# subject is still the first content line. Mirror that here.
assert_level feat "git-log-style leading-newline records" $'\nfeat: a' $'\nfix: b'
assert_level breaking "leading-newline record w/ bang" $'\nfeat!: a' $'\ndocs: b'

# ---- vlib_bump 0.x ---------------------------------------------------------
assert_bump 0.1.0 none     0.1.0
assert_bump 0.1.0 fix      0.1.1
assert_bump 0.1.0 feat     0.1.1
assert_bump 0.1.0 breaking 0.2.0

# ---- vlib_bump >= 1.0 ------------------------------------------------------
assert_bump 1.2.3 fix      1.2.4
assert_bump 1.2.3 feat     1.3.0
assert_bump 1.2.3 breaking 2.0.0

# ---- vlib_ge ---------------------------------------------------------------
vlib_ge 0.2.0 0.1.9 && ok "ge 0.2.0>=0.1.9 true" || bad "ge 0.2.0>=0.1.9 should be true"
vlib_ge 0.1.0 0.1.0 && ok "ge 0.1.0>=0.1.0 true" || bad "ge 0.1.0>=0.1.0 should be true"
vlib_ge 0.1.0 0.2.0 && bad "ge 0.1.0>=0.2.0 should be false" || ok "ge 0.1.0>=0.2.0 false"
vlib_ge 1.0.0 0.9.9 && ok "ge 1.0.0>=0.9.9 true" || bad "ge 1.0.0>=0.9.9 should be true"

# ---- malformed version rejection -------------------------------------------
if vlib_bump "1.2" feat >/dev/null 2>&1; then bad "bump malformed '1.2' should fail"; else ok "bump malformed '1.2' fails"; fi
if vlib_bump "x.y.z" feat >/dev/null 2>&1; then bad "bump malformed 'x.y.z' should fail"; else ok "bump malformed 'x.y.z' fails"; fi
vlib_ge "1.2" "1.0.0" >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "ge malformed 'a' -> rc 2" || bad "ge malformed 'a' should rc 2"
vlib_ge "1.0.0" "bad" >/dev/null 2>&1; [ "$?" -eq 2 ] && ok "ge malformed 'b' -> rc 2" || bad "ge malformed 'b' should rc 2"
if vlib_bump "1.2.3" nonsense >/dev/null 2>&1; then bad "bump unknown level should fail"; else ok "bump unknown level fails"; fi

echo
echo "test-version: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
