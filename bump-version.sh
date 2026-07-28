#!/bin/bash
#
# bump-version.sh [--dry-run] [--tag] [<base> <head>]
#
# Computes the required completion-harness version for a commit range and, by
# default, writes it into plugin.json and commits the bump. Same version math
# as check-version.sh (both source version-lib.sh).
#
# Range:
#   <base> <head>     explicit range if two positional args are given
#   otherwise         origin/main..HEAD (default), falling back to
#                     `git merge-base origin/main HEAD`..HEAD when there is no
#                     usable upstream, and finally to the empty-tree/root when
#                     origin/main is absent.
#
# Modes:
#   --dry-run   print the recommendation only; make NO changes.
#   (default)   write plugin.json (jq, preserving other keys), `git add` it,
#               and commit  `chore(release): bump completion-harness to X.Y.Z`.
#   --tag       additionally `git tag vX.Y.Z` (only in write mode).
#
# If no bump is needed (level none, or plugin.json already >= required),
# prints "no bump required" and exits 0 without committing.
#
# Exit codes: 0 success / no-op; 1 error.

set -u
set -o pipefail   # so a `git log | vlib_*` pipeline surfaces a git-log failure

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
# shellcheck source=version-lib.sh
. "$SCRIPT_DIR/version-lib.sh" || { echo "bump-version: cannot source version-lib.sh" >&2; exit 1; }

PLUGIN_PATH="completion-harness/.claude-plugin/plugin.json"

die() { echo "bump-version: $*" >&2; exit 1; }

DRY_RUN=0
DO_TAG=0
POS=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --tag)     DO_TAG=1 ;;
    -*)        die "unknown flag: $arg" ;;
    *)         POS+=("$arg") ;;
  esac
done

command -v git >/dev/null 2>&1 || die "git not found"
command -v jq  >/dev/null 2>&1 || die "jq not found"

# --- resolve range ----------------------------------------------------------
if [ "${#POS[@]}" -eq 2 ]; then
  BASE="${POS[0]}"
  HEAD="${POS[1]}"
elif [ "${#POS[@]}" -eq 0 ]; then
  HEAD="$(git rev-parse HEAD)" || die "cannot resolve HEAD"
  if git rev-parse --verify origin/main >/dev/null 2>&1; then
    # Prefer merge-base so we only account for commits unique to this branch.
    BASE="$(git merge-base origin/main HEAD 2>/dev/null)" \
      || BASE="$(git rev-parse origin/main)"
  else
    # No origin/main — use the empty tree (root) so the whole history counts.
    BASE="$(git rev-list --max-parents=0 HEAD | tail -1)" \
      || die "cannot find root commit"
  fi
else
  die "usage: bump-version.sh [--dry-run] [--tag] [<base> <head>]"
fi

git rev-parse --verify "$BASE^{commit}" >/dev/null 2>&1 || die "bad base sha: $BASE"
git rev-parse --verify "$HEAD^{commit}" >/dev/null 2>&1 || die "bad head sha: $HEAD"

# --- compute level + versions (mirrors check-version.sh) --------------------
# Pipe git log STRAIGHT into the lib — capturing it in a variable would strip
# the NUL record delimiters ($(...) drops NUL bytes) and collapse all records.
LEVEL="$(git log --format='%s%n%b%x00' "$BASE..$HEAD" | vlib_level_from_subjects)" \
  || die "level computation failed"

BASE_JSON="$(git show "$BASE:$PLUGIN_PATH" 2>/dev/null)"
if [ -z "$BASE_JSON" ]; then
  BASE_VER="0.0.0"
else
  BASE_VER="$(printf '%s' "$BASE_JSON" | jq -r '.version' 2>/dev/null)" \
    || die "cannot parse version at base"
  [ "$BASE_VER" != "null" ] && [ -n "$BASE_VER" ] || die "no .version at base"
fi

[ -f "$PLUGIN_PATH" ] || die "$PLUGIN_PATH not found"
CUR_VER="$(jq -r '.version' "$PLUGIN_PATH" 2>/dev/null)" || die "cannot parse working-tree version"
[ "$CUR_VER" != "null" ] && [ -n "$CUR_VER" ] || die "no .version in working-tree plugin.json"

REQUIRED="$(vlib_bump "$BASE_VER" "$LEVEL")" || die "vlib_bump failed (base=$BASE_VER level=$LEVEL)"

echo "bump-version: range=$BASE..$HEAD level=$LEVEL base_version=$BASE_VER current_version=$CUR_VER required=$REQUIRED"

# --- no-bump short circuits --------------------------------------------------
if [ "$LEVEL" = "none" ]; then
  echo "no bump required (no version-affecting commits in range)"
  exit 0
fi

vlib_ge "$CUR_VER" "$REQUIRED"
GE_RC=$?
[ "$GE_RC" -eq 2 ] && die "malformed version in comparison"
if [ "$GE_RC" -eq 0 ]; then
  echo "no bump required (current $CUR_VER already >= required $REQUIRED)"
  exit 0
fi

# --- dry run -----------------------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  echo "bump-version: [dry-run] would bump $CUR_VER -> $REQUIRED"
  exit 0
fi

# --- apply -------------------------------------------------------------------
TMP="$(mktemp)" || die "mktemp failed"
jq --arg v "$REQUIRED" '.version = $v' "$PLUGIN_PATH" > "$TMP" || { rm -f "$TMP"; die "jq write failed"; }
mv "$TMP" "$PLUGIN_PATH" || die "cannot write $PLUGIN_PATH"

git add "$PLUGIN_PATH" || die "git add failed"
# Pathspec-scoped commit: only the version file, never sweep other staged changes
# (this runs unattended from the pre-push hook).
git commit -m "chore(release): bump completion-harness to $REQUIRED" -- "$PLUGIN_PATH" >/dev/null \
  || die "git commit failed"
echo "bump-version: committed bump to $REQUIRED"

if [ "$DO_TAG" -eq 1 ]; then
  git tag "v$REQUIRED" || die "git tag v$REQUIRED failed"
  echo "bump-version: tagged v$REQUIRED"
fi

exit 0
