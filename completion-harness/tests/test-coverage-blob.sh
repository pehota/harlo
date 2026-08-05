#!/bin/bash
#
# BEHAVIOURAL test — blob-keyed review coverage (hc_review_coverage_gap) and the
# widened review-log keep-set (hc_live_review_shas). Phase 5 (GitHub issue #1).
#
# Coverage is now per-file by BLOB across ALL logs in the task's chain: a changed
# file is covered iff its CURRENT blob (content at HEAD) was attested by SOME
# chain-log (a `<sha>.json` whose sha is a task-side ancestor of HEAD). A
# follow-up commit only re-attests the files whose blob it changed; untouched
# files carry forward. Deleted files fall back to path attestation.
#
# Sources the source-tree harness-common.sh; builds throwaway git repos in the
# style of test-abi.sh's new_task_repo. No install / no set -e.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
HC_COMMON="$SCRIPTS/harness-common.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-coverage-blob =="

if [ ! -f "$HC_COMMON" ]; then
  bad "harness-common.sh missing at $HC_COMMON"
  echo; echo "test-coverage-blob: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot build review-log fixtures"
  echo; echo "test-coverage-blob: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

# shellcheck source=/dev/null
. "$HC_COMMON" 2>/dev/null

CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# mk_repo — a fresh repo on trunk `main` with base.txt committed. Returns via $REPO.
mk_repo() {
  REPO=$(mktemp -d 2>/dev/null); CLEANUP+=("$REPO")
  git -C "$REPO" init -q -b main 2>/dev/null
  git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
  git -C "$REPO" config user.name  "Test" >/dev/null 2>&1
  printf '.claude/\n' > "$REPO/.gitignore"
  mkdir -p "$REPO/.claude"
  printf '{"trunk":"main"}\n' > "$REPO/.claude/done-config.json"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm init >/dev/null 2>&1
  printf 'base\n' > "$REPO/base.txt"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm base >/dev/null 2>&1
  RLDIR="$REPO/.claude/.harness/review-log"
  mkdir -p "$RLDIR"
}

commit() { # commit <repo> <msg> — return new HEAD sha via stdout
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -qm "$2" >/dev/null 2>&1
  git -C "$1" rev-parse HEAD 2>/dev/null
}

# write_log <repo> <sha> <reviewed_sha> <path...> — write review-log/<sha>.json
write_log() {
  local repo="$1" sha="$2" rsha="$3"; shift 3
  local arr; arr=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[]}\n' \
    "$rsha" "$arr" > "$repo/.claude/.harness/review-log/$sha.json"
}

# ===========================================================================
# 1. NEW COMMIT ON TOP — c1 attested at R1; c2 touches only b.txt attested at R2.
#    a.txt/c1's blob is unchanged → carries forward → gap EMPTY.
# ===========================================================================
mk_repo
BASE=$(git -C "$REPO" rev-parse HEAD)          # trunk tip = task base
git -C "$REPO" checkout -q -b feat/x
printf 'a1\n' > "$REPO/a.txt"
R1=$(commit "$REPO" c1)                          # commit 1 adds a.txt
printf 'b1\n' > "$REPO/b.txt"
R2=$(commit "$REPO" c2)                          # commit 2 adds b.txt only
write_log "$REPO" "$R1" "$R1" "a.txt"            # chain-log at R1 attests a.txt
write_log "$REPO" "$R2" "$R2" "b.txt"            # chain-log at R2 attests b.txt
GAP=$(hc_review_coverage_gap "$RLDIR/$R2.json" "$BASE" "$R2" "$REPO")
if [ -z "$GAP" ]; then
  ok "new-commit-on-top: a.txt carried forward from R1, gap EMPTY"
else
  bad "new-commit-on-top: expected empty gap, got [$GAP]"
fi

# ===========================================================================
# 2. ONE-FILE FIX — c2 CHANGES a.txt's blob but R2 does NOT list a.txt.
#    a.txt's current blob is attested by NO chain-log → gap == {a.txt}.
# ===========================================================================
mk_repo
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/y
printf 'a1\n' > "$REPO/a.txt"
R1=$(commit "$REPO" c1)
write_log "$REPO" "$R1" "$R1" "a.txt"            # attests a.txt at its R1 blob
printf 'a2-CHANGED\n' > "$REPO/a.txt"            # c2 changes a.txt's content
printf 'b1\n' > "$REPO/b.txt"
R2=$(commit "$REPO" c2)
write_log "$REPO" "$R2" "$R2" "b.txt"            # R2 attests only b.txt
GAP=$(hc_review_coverage_gap "$RLDIR/$R2.json" "$BASE" "$R2" "$REPO")
if [ "$GAP" = "a.txt" ]; then
  ok "one-file-fix: changed-blob a.txt not re-attested → gap == {a.txt}"
else
  bad "one-file-fix: expected gap {a.txt}, got [$GAP]"
fi

# ===========================================================================
# 3. REBASE / IDENTICAL-TREE — attest at R1; make an identical-tree commit R2.
#    a) old reviewed_sha (R1) still REACHABLE → a.txt blob matches → gap EMPTY.
#    b) DOCUMENTED DEVIATION: if R1 were gc'd/pruned (unreachable), rev-parse
#       R1:a.txt would fail → a.txt falls to the gap (fail-toward-block). We
#       simulate the pruned case with a bogus reviewed_sha that cannot resolve.
# ===========================================================================
mk_repo
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/z
printf 'a1\n' > "$REPO/a.txt"
R1=$(commit "$REPO" c1)
# amend-in-place to a new sha but IDENTICAL tree (same a.txt blob).
git -C "$REPO" commit -q --amend -m c1-reworded >/dev/null 2>&1
R2=$(git -C "$REPO" rev-parse HEAD)
# 3a) R1 is still reachable as a dangling commit (not yet gc'd); attest at R1.
write_log "$REPO" "$R2" "$R1" "a.txt"
GAP=$(hc_review_coverage_gap "$RLDIR/$R2.json" "$BASE" "$R2" "$REPO")
# The chain includes R2.json (R2 is task-side ancestor of R2). Its reviewed_sha
# R1 still resolves (dangling but reachable-by-sha) and a.txt's blob is
# identical → covered.
if [ -z "$GAP" ]; then
  ok "rebase/identical-tree: reachable old reviewed_sha, identical blob → gap EMPTY"
else
  bad "rebase/identical-tree: expected empty gap with reachable R1, got [$GAP]"
fi
# 3b) pruned-sha simulation: reviewed_sha that does NOT resolve → attested blob
# empty → a.txt not covered → gap {a.txt}. This is the documented deviation
# (a rebase that gc's old commits forces re-review).
write_log "$REPO" "$R2" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "a.txt"
GAP=$(hc_review_coverage_gap "$RLDIR/$R2.json" "$BASE" "$R2" "$REPO")
if [ "$GAP" = "a.txt" ]; then
  ok "rebase/pruned-sha: unresolvable reviewed_sha → gap {a.txt} (documented fail-toward-block)"
else
  bad "rebase/pruned-sha: expected gap {a.txt}, got [$GAP]"
fi

# ===========================================================================
# 4. DELETED FILE — head deletes d.txt.
#    a) chain-log LISTS d.txt (path attestation) → covered → gap EMPTY.
#    b) NO chain-log lists d.txt → gap contains d.txt.
# ===========================================================================
mk_repo
# d.txt must exist AT BASE so its deletion shows up in git diff BASE..head.
printf 'd1\n' > "$REPO/d.txt"
commit "$REPO" adds-d-at-base >/dev/null
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/del
git -C "$REPO" rm -q d.txt >/dev/null 2>&1
R2=$(commit "$REPO" deletes-d)                   # d.txt deleted at head
# 4a) chain-log at R2 lists d.txt → path-attested (no blob at head).
write_log "$REPO" "$R2" "$R2" "d.txt"
GAP=$(hc_review_coverage_gap "$RLDIR/$R2.json" "$BASE" "$R2" "$REPO")
if [ -z "$GAP" ]; then
  ok "deleted-file: chain-log lists d.txt → path-attested → gap EMPTY"
else
  bad "deleted-file(listed): expected empty gap, got [$GAP]"
fi
# 4b) no chain-log lists d.txt → gap contains d.txt.
write_log "$REPO" "$R2" "$R2" "other.txt"
GAP=$(hc_review_coverage_gap "$RLDIR/$R2.json" "$BASE" "$R2" "$REPO")
if printf '%s\n' "$GAP" | grep -Fxq "d.txt"; then
  ok "deleted-file: no chain-log lists d.txt → gap contains d.txt"
else
  bad "deleted-file(unlisted): expected d.txt in gap, got [$GAP]"
fi

# ===========================================================================
# 5. FAIL-TOWARD-BLOCK — bogus head sha / malformed chain log with a non-empty
#    changeset must yield a NON-EMPTY gap (never SKIP / empty).
# ===========================================================================
mk_repo
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/bad
printf 'a1\n' > "$REPO/a.txt"
R1=$(commit "$REPO" c1)
# 5a) malformed log in the chain (files_reviewed not an array) → nothing attested.
printf '{"reviewed_sha":"%s","files_reviewed":"NOT-AN-ARRAY"}\n' "$R1" > "$RLDIR/$R1.json"
GAP=$(hc_review_coverage_gap "$RLDIR/$R1.json" "$BASE" "$R1" "$REPO")
if [ -n "$GAP" ] && [ "$GAP" != "SKIP" ]; then
  ok "fail-toward-block: malformed chain log → non-empty gap (not SKIP/empty)"
else
  bad "fail-toward-block(malformed): expected non-empty gap, got [$GAP]"
fi

# ===========================================================================
# 6. SKIP on empty base.
# ===========================================================================
write_log "$REPO" "$R1" "$R1" "a.txt"
OUT=$(hc_review_coverage_gap "$RLDIR/$R1.json" "" "$R1" "$REPO")
if [ "$OUT" = "SKIP" ]; then
  ok "empty base → SKIP"
else
  bad "empty base: expected SKIP, got [$OUT]"
fi

# ===========================================================================
# 7. hc_live_review_shas — widened keep-set.
#    a) 3-commit base..tip on a LIVE branch, each with a log → all 3 kept.
#    b) unconfident trunk → falls back to tips + HEAD (never nothing).
# ===========================================================================
mk_repo
TRUNK_TIP=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/chain
printf 'x1\n' > "$REPO/x.txt"; C1=$(commit "$REPO" x1)
printf 'x2\n' > "$REPO/x.txt"; C2=$(commit "$REPO" x2)
printf 'x3\n' > "$REPO/x.txt"; C3=$(commit "$REPO" x3)
# Pin the task-base for feat/chain (task-base/br-feat-chain.sha).
mkdir -p "$REPO/.claude/.harness/task-base"
printf '%s\n' "$TRUNK_TIP" > "$REPO/.claude/.harness/task-base/br-feat-chain.sha"
# Run hc_live_review_shas from the branch HEAD (C3).
SHAS=$(hc_live_review_shas "$REPO")
if printf '%s\n' "$SHAS" | grep -Fxq "$C1" \
   && printf '%s\n' "$SHAS" | grep -Fxq "$C2" \
   && printf '%s\n' "$SHAS" | grep -Fxq "$C3"; then
  ok "hc_live_review_shas: 3-commit live chain → all intermediate shas kept"
else
  bad "hc_live_review_shas: chain commits missing from keep-set: [$SHAS]"
fi

# b) unconfident trunk (branch develop, no main/master, no config trunk) → the
#    widening skips, but HEAD + tips are still emitted.
R2REPO=$(mktemp -d); CLEANUP+=("$R2REPO")
git -C "$R2REPO" init -q -b develop
git -C "$R2REPO" config user.email t@t; git -C "$R2REPO" config user.name t
printf 'a\n' > "$R2REPO/a.txt"; git -C "$R2REPO" add -A; git -C "$R2REPO" commit -qm c1 >/dev/null 2>&1
DHEAD=$(git -C "$R2REPO" rev-parse HEAD)
SHAS=$(hc_live_review_shas "$R2REPO")
if printf '%s\n' "$SHAS" | grep -Fxq "$DHEAD"; then
  ok "hc_live_review_shas: unconfident trunk → falls back to tips+HEAD (never nothing)"
else
  bad "hc_live_review_shas: unconfident-trunk fallback dropped HEAD: [$SHAS]"
fi

echo
echo "test-coverage-blob: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
