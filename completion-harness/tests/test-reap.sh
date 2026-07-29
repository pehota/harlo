#!/bin/bash
#
# Unit test — age-based reap of stale harness state in baseline-snapshot.sh.
#
# baseline-snapshot.sh runs at SessionStart. It must delete files under the
# harness state dir older than 14 days while keeping fresh files (this
# session's just-written baseline, active parallel sessions, recent state).
#
# Scripts under test: the BUNDLE copy (source of truth). The installed copy is
# verified byte-identical to it by the caller's diff check.

BASELINE="$(cd "$(dirname "$0")/../scripts" && pwd)/baseline-snapshot.sh"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

SID="S"

echo "== test-reap (baseline-snapshot age-based cleanup) =="

# --- throwaway repo ---------------------------------------------------------
# NOTE: this suite exercises ONLY the 14-day AGE reap and its task-base/tree-base
# EXCLUSIONS. It deliberately uses an UNCONFIDENT trunk (default branch renamed
# away from main/master, no config trunk) so the SEPARATE terminal reap (which
# reaps a merged/GONE br-* task's state) is SKIPPED for safety and cannot touch
# the stale gone-branch pins this suite seeds. Terminal reap is covered by
# test-cleanup.sh.
REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q -b work
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "test"
printf '.claude/\n' > "$REPO/.gitignore"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial"

HARNESS="$REPO/.claude/.harness"
mkdir -p "$HARNESS/baselines" "$HARNESS/done-state" "$HARNESS/review-log"

# --- seed STALE files (20 days old) -----------------------------------------
STALE_SHA="$HARNESS/baselines/old-sess.sha"
STALE_DONE="$HARNESS/done-state/old-sess.json"
STALE_REVIEW="$HARNESS/review-log/deadbeef.json"
# A stale task-base PIN — must NOT be reaped (a task's base must live as long as
# its branch; reaping it would silently re-pin at a later merge-base).
STALE_PIN="$HARNESS/task-base/br-old-feature.sha"
mkdir -p "$HARNESS/task-base"
# A stale TREE-base pin — must NOT be reaped either. Reaping it would let the
# next SessionStart re-seed the "pre-existing" set from live porcelain and
# whitelist the agent's own uncommitted work (the carryover bug).
STALE_TREE_PIN="$HARNESS/tree-base/br-old-feature.dirty"
mkdir -p "$HARNESS/tree-base"
for f in "$STALE_SHA" "$STALE_DONE" "$STALE_REVIEW" "$STALE_PIN" "$STALE_TREE_PIN"; do
  echo "stale" > "$f"
  touch -d '20 days ago' "$f"
done

# --- seed FRESH file (mtime now) --------------------------------------------
FRESH_DONE="$HARNESS/done-state/recent.json"
echo "fresh" > "$FRESH_DONE"   # mtime = now

# --- run baseline-snapshot.sh -----------------------------------------------
printf '{"session_id":"%s"}' "$SID" | CLAUDE_PROJECT_DIR="$REPO" bash "$BASELINE" >/dev/null 2>&1

# --- assertions -------------------------------------------------------------
# Stale files deleted.
[ ! -e "$STALE_SHA" ]    && ok "stale baselines/old-sess.sha DELETED"    || bad "stale baselines/old-sess.sha still present"
[ ! -e "$STALE_DONE" ]   && ok "stale done-state/old-sess.json DELETED"  || bad "stale done-state/old-sess.json still present"
# review-log/ is EXCLUDED from the 14-day age reap (blob-keyed coverage can make
# an old chain-log load-bearing). deadbeef is a BOGUS sha (no matching commit /
# tip / HEAD) → not in hc_live_review_shas' keep-set → deleted by the review-log
# HYGIENE prune (not by age). Either way it must be gone after SessionStart.
[ ! -e "$STALE_REVIEW" ] && ok "stale review-log/deadbeef.json DELETED (by keep-set, age-exempt)"  || bad "stale review-log/deadbeef.json still present"

# Fresh file kept.
[ -e "$FRESH_DONE" ] && ok "fresh done-state/recent.json KEPT" || bad "fresh done-state/recent.json was deleted"

# Stale task-base PIN kept (excluded from reap).
[ -e "$STALE_PIN" ] && ok "stale task-base pin KEPT (excluded from reap)" || bad "stale task-base pin was reaped — base would re-pin wrong"

# Stale tree-base PIN kept (excluded from reap — prevents re-seed carryover bug).
[ -e "$STALE_TREE_PIN" ] && ok "stale tree-base pin KEPT (excluded from reap)" || bad "stale tree-base pin was reaped — pre-existing set would re-seed"

# Current session's baseline written fresh.
CUR_SHA="$HARNESS/baselines/${SID}.sha"
if [ -f "$CUR_SHA" ]; then
  ok "current session baseline ${SID}.sha written"
else
  bad "current session baseline ${SID}.sha NOT written"
fi

echo
echo "test-reap: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
