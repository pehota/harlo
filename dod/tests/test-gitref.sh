#!/bin/bash
#
# Tests for dod/lib/gitref.sh: dod_task_key, dod_diff_hash, dod_is_ancestor.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/gitref.sh"

echo "== gitref.sh =="

# --- dod_task_key -----------------------------------------------------------
REPO=$(dod__test_make_repo task)
KEY=$(dod_task_key "$REPO")
eq "task_key sanitises feature/x" "feature-x" "$KEY"

REPO2=$(dod__test_make_repo)
KEY2=$(dod_task_key "$REPO2")
eq "task_key on trunk" "main" "$KEY2"

# sanitisation is idempotent / happens once, at the resolver
REPO3=$(dod__test_make_repo)
git -C "$REPO3" checkout -q -b 'weird@branch#name'
KEY3=$(dod_task_key "$REPO3")
case "$KEY3" in
  *[!A-Za-z0-9_.-]*) bad "task_key sanitises unsafe chars" "$KEY3" ;;
  *) ok "task_key sanitises unsafe chars" ;;
esac

# --- dod_diff_hash -----------------------------------------------------------
REPO4=$(dod__test_make_repo)
H1=$(dod_diff_hash "$REPO4")
H2=$(dod_diff_hash "$REPO4")
eq "diff_hash stable for identical tree" "$H1" "$H2"

echo "changed" >> "$REPO4/root.txt"
H3=$(dod_diff_hash "$REPO4")
if [ "$H1" != "$H3" ]; then
  ok "diff_hash changes when a tracked file is touched"
else
  bad "diff_hash changes when a tracked file is touched" "$H3"
fi

echo "new" > "$REPO4/untracked.txt"
H4=$(dod_diff_hash "$REPO4")
if [ "$H3" != "$H4" ]; then
  ok "diff_hash changes when an untracked file is added"
else
  bad "diff_hash changes when an untracked file is added" "$H4"
fi

# --- dod_is_ancestor ---------------------------------------------------------
REPO5=$(dod__test_make_repo)
ROOT_SHA=$(git -C "$REPO5" rev-parse HEAD)
echo "more" >> "$REPO5/root.txt"
git -C "$REPO5" commit -q -am "more"
HEAD_SHA=$(git -C "$REPO5" rev-parse HEAD)

if dod_is_ancestor "$REPO5" "$ROOT_SHA" "$HEAD_SHA"; then
  ok "is_ancestor true for root -> head"
else
  bad "is_ancestor true for root -> head" "false"
fi

if dod_is_ancestor "$REPO5" "$HEAD_SHA" "$ROOT_SHA"; then
  bad "is_ancestor false for head -> root" "true"
else
  ok "is_ancestor false for head -> root"
fi

if dod_is_ancestor "$REPO5" "deadbeef0000000000000000000000000000dead" "$HEAD_SHA"; then
  bad "is_ancestor false for unknown sha" "true"
else
  ok "is_ancestor false for unknown sha"
fi

echo
echo "gitref.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
