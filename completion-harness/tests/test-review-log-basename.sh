#!/bin/bash
#
# BEHAVIOURAL test — review-log basenames must be raw object ids.
#
# hc_review_coverage_gap builds the chain by feeding every `review-log/*.json`
# basename to git as a rev. A SYMBOLIC basename (HEAD.json, main.json,
# 'HEAD@{0}.json') is an attestation that can never expire: `merge-base
# --is-ancestor HEAD <head>` is true, and the blob check then resolves
# `rev-parse HEAD:<path>` — the CURRENT blob — so the log validates itself.
# Realistic vector: a legitimate <HEAD>.json attesting nothing, plus a stray
# HEAD.json attesting the changed paths → empty gap → coverage passes.
#
# Sources the source-tree harness-common.sh and drives the real gate; builds
# throwaway git repos in the style of test-coverage-blob.sh. No install, no set -e.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
HC_COMMON="$SCRIPTS/harness-common.sh"
GATE="$SCRIPTS/done-gate.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-review-log-basename =="

if [ ! -f "$HC_COMMON" ]; then
  bad "harness-common.sh missing at $HC_COMMON"
  echo; echo "test-review-log-basename: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot build review-log fixtures"
  echo; echo "test-review-log-basename: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

# shellcheck source=/dev/null
. "$HC_COMMON" 2>/dev/null

CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

# is_block <stdout> → 0 if the gate stdout is a block decision.
is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# mk_repo [object_format] — fresh repo on trunk `main` with base.txt committed.
# Sets REPO, RLDIR. The object format decides whether shas are 40 or 64 hex.
mk_repo() {
  local fmt="${1:-sha1}"
  REPO=$(hc__test_mktemp_d); CLEANUP+=("$REPO")
  git -C "$REPO" init -q -b main --object-format="$fmt" 2>/dev/null
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

# write_log <repo> <basename> <reviewed_sha> <path...> — review-log/<basename>.json
write_log() {
  local repo="$1" name="$2" rsha="$3"; shift 3
  local arr; arr=$(printf '%s\n' "$@" | jq -R . | jq -s .)
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[]}\n' \
    "$rsha" "$arr" > "$repo/.claude/.harness/review-log/$name.json"
}

# write_empty_log <repo> <basename> <reviewed_sha> — attests NO files.
write_empty_log() {
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":[]}\n' \
    "$3" > "$1/.claude/.harness/review-log/$2.json"
}

# ===========================================================================
# 1. THE HOLE — a legitimate <HEAD>.json attesting NOTHING plus a stray
#    HEAD.json attesting both changed files. The stray log must be IGNORED, so
#    both files stay in the gap.
# ===========================================================================
mk_repo
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q -b feat/x
printf 'a1\n' > "$REPO/a.js"
printf 'b1\n' > "$REPO/b.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm work >/dev/null 2>&1
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

write_empty_log "$REPO" "$HEAD_SHA" "$HEAD_SHA"
write_log "$REPO" "HEAD" "$HEAD_SHA" a.js b.js

GAP=$(hc_review_coverage_gap "$RLDIR/$HEAD_SHA.json" "$BASE" "$HEAD_SHA" "$REPO")
if printf '%s' "$GAP" | grep -q 'a.js' && printf '%s' "$GAP" | grep -q 'b.js'; then
  ok "stray HEAD.json is IGNORED — both changed files remain in the gap"
else
  bad "stray HEAD.json granted coverage (gap='$GAP', expected a.js + b.js)"
fi

# ===========================================================================
# 1b. Same vector through the REAL gate: it must BLOCK on the uncovered files.
# ===========================================================================
SID=basename-hole
mkdir -p "$REPO/.claude/.harness/baselines" "$REPO/.claude/.harness/done-state"
printf '%s\n' "$BASE" > "$REPO/.claude/.harness/baselines/$SID.sha"
git -C "$REPO" status --porcelain > "$REPO/.claude/.harness/baselines/$SID.dirty"
printf '{"contract_version":1,"session_id":"%s","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[],"escalation":null}\n' \
  "$SID" "$HEAD_SHA" > "$REPO/.claude/.harness/done-state/br-feat-x.json"
OUT=$(printf '{"session_id":"%s","stop_hook_active":false}' "$SID" | CLAUDE_PROJECT_DIR="$REPO" bash "$GATE" 2>/dev/null)
if is_block "$OUT"; then
  ok "gate BLOCKs — the stray HEAD.json cannot satisfy coverage"
else
  bad "gate ALLOWed with only a stray HEAD.json covering the changeset. out=$OUT"
fi

# ===========================================================================
# 1c. Other symbolic basenames git would happily resolve are rejected too.
# ===========================================================================
rm -f "$RLDIR/HEAD.json"
write_log "$REPO" "main" "$HEAD_SHA" a.js b.js
write_log "$REPO" 'HEAD@{0}' "$HEAD_SHA" a.js b.js
GAP=$(hc_review_coverage_gap "$RLDIR/$HEAD_SHA.json" "$BASE" "$HEAD_SHA" "$REPO")
if printf '%s' "$GAP" | grep -q 'a.js' && printf '%s' "$GAP" | grep -q 'b.js'; then
  ok "stray main.json / 'HEAD@{0}.json' are IGNORED — gap unchanged"
else
  bad "a symbolic-ref basename granted coverage (gap='$GAP')"
fi
rm -f "$RLDIR/main.json" "$RLDIR/HEAD@{0}.json"

# ===========================================================================
# 2. NOT OVER-FILTERED (sha1, 40 hex) — a NORMAL <HEAD>.json log attesting the
#    changed files still grants full coverage.
# ===========================================================================
write_log "$REPO" "$HEAD_SHA" "$HEAD_SHA" a.js b.js
GAP=$(hc_review_coverage_gap "$RLDIR/$HEAD_SHA.json" "$BASE" "$HEAD_SHA" "$REPO")
if [ ${#HEAD_SHA} -eq 40 ] && [ -z "$GAP" ]; then
  ok "40-hex log still grants coverage (gap empty) — filter is not over-broad"
else
  bad "40-hex log lost its coverage (len=${#HEAD_SHA} gap='$GAP')"
fi

# ===========================================================================
# 2b. NOT OVER-FILTERED (sha256, 64 hex) — same assertion in a sha256 repo, so
#     the 64 arm of the length filter is exercised against REAL git shas.
#     Skipped (reported) if this git cannot create sha256 repos.
# ===========================================================================
if git init --object-format=sha256 -q "$(mktemp -d)/probe" >/dev/null 2>&1; then
  mk_repo sha256
  BASE=$(git -C "$REPO" rev-parse HEAD)
  git -C "$REPO" checkout -q -b feat/y
  printf 'a1\n' > "$REPO/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm work >/dev/null 2>&1
  HEAD256=$(git -C "$REPO" rev-parse HEAD)
  write_log "$REPO" "$HEAD256" "$HEAD256" a.js
  GAP=$(hc_review_coverage_gap "$RLDIR/$HEAD256.json" "$BASE" "$HEAD256" "$REPO")
  if [ ${#HEAD256} -eq 64 ] && [ -z "$GAP" ]; then
    ok "64-hex (sha256) log still grants coverage — both length arms accepted"
  else
    bad "64-hex log lost its coverage (len=${#HEAD256} gap='$GAP')"
  fi
  write_log "$REPO" "HEAD" "$HEAD256" a.js
  rm -f "$RLDIR/$HEAD256.json"
  write_empty_log "$REPO" "$HEAD256" "$HEAD256"
  GAP=$(hc_review_coverage_gap "$RLDIR/$HEAD256.json" "$BASE" "$HEAD256" "$REPO")
  if printf '%s' "$GAP" | grep -q 'a.js'; then
    ok "sha256 repo: stray HEAD.json is IGNORED too"
  else
    bad "sha256 repo: stray HEAD.json granted coverage (gap='$GAP')"
  fi
else
  echo "  SKIP: git cannot create sha256 repos here — 64-hex arm not exercised"
fi

echo
echo "test-review-log-basename: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
