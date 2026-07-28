#!/bin/bash
#
# check-version.sh <base_sha> <head_sha>
#
# Decides whether plugin.json's declared version is high enough for the changes
# in the range <base_sha>..<head_sha>, given the conventional commits in it.
#
# It computes:
#   level        — highest release level across the range's commits
#   base_version — plugin.json version AT <base_sha> (0.0.0 if the file was
#                  absent there)
#   current_ver  — plugin.json version in the WORKING TREE right now
#   required     — vlib_bump(base_version, level)
#
# Exit codes:
#   0  — adequately bumped (current >= required) or no bump needed
#   3  — UNDER-bumped: current < required (prints the required version)
#   1  — any error (bad args, missing tools, unreadable version, etc.)

set -u
set -o pipefail   # so a `git log | vlib_*` pipeline surfaces a git-log failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
# shellcheck source=version-lib.sh
. "$SCRIPT_DIR/version-lib.sh" || { echo "check-version: cannot source version-lib.sh" >&2; exit 1; }

PLUGIN_PATH="completion-harness/.claude-plugin/plugin.json"

die() { echo "check-version: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: check-version.sh <base_sha> <head_sha>"
BASE="$1"
HEAD="$2"

command -v git >/dev/null 2>&1 || die "git not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"

git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "bad base sha: $BASE"
git rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1 || die "bad head sha: $HEAD"

# --- level from the range's commits -----------------------------------------
# NUL-delimited <subject>\n<body> records, piped STRAIGHT into the lib. We must
# NOT capture the stream in a shell variable first: `$(...)` strips NUL bytes,
# which would collapse all records into one and break multi-commit detection.
LEVEL="$(git log --format='%s%n%b%x00' "$BASE..$HEAD" | vlib_level_from_subjects)" \
  || die "level computation failed"

# --- base version (at BASE) --------------------------------------------------
BASE_JSON="$(git show "$BASE:$PLUGIN_PATH" 2>/dev/null)"
if [ -z "$BASE_JSON" ]; then
  BASE_VER="0.0.0"   # file did not exist at base
else
  BASE_VER="$(printf '%s' "$BASE_JSON" | jq -r '.version' 2>/dev/null)" \
    || die "cannot parse version from plugin.json at $BASE"
  [ "$BASE_VER" != "null" ] && [ -n "$BASE_VER" ] || die "no .version in plugin.json at $BASE"
fi

# --- current version (working tree) -----------------------------------------
[ -f "$PLUGIN_PATH" ] || die "$PLUGIN_PATH not found in working tree"
CUR_VER="$(jq -r '.version' "$PLUGIN_PATH" 2>/dev/null)" \
  || die "cannot parse version from working-tree plugin.json"
[ "$CUR_VER" != "null" ] && [ -n "$CUR_VER" ] || die "no .version in working-tree plugin.json"

# --- required = bump(base, level) -------------------------------------------
REQUIRED="$(vlib_bump "$BASE_VER" "$LEVEL")" || die "vlib_bump failed (base=$BASE_VER level=$LEVEL)"

# Validate current before comparing.
vlib_ge "$CUR_VER" "$REQUIRED"
GE_RC=$?
[ "$GE_RC" -eq 2 ] && die "malformed version in comparison (current=$CUR_VER required=$REQUIRED)"

echo "check-version: level=$LEVEL base_version=$BASE_VER current_version=$CUR_VER required=$REQUIRED"

if [ "$GE_RC" -eq 0 ]; then
  echo "check-version: OK — current ($CUR_VER) >= required ($REQUIRED)"
  exit 0
fi

echo "check-version: UNDER-BUMPED — current ($CUR_VER) < required ($REQUIRED). Bump to $REQUIRED." >&2
exit 3
