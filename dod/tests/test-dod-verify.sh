#!/bin/bash
#
# Tests for dod-verify-write-result.sh — the verification-result writer.
#
# Covers:
#   1  no contract on file                                  → refused
#   2  results[] length mismatch vs contract requirements[]  → refused
#   3  results[] index set has a gap/dupe/out-of-range        → refused
#   4  matching results[] (pass/fail/skipped)                 → written, shape correct
#   5  dirty tree (uncommitted introduced changes)             → refused
#   6  contract grows (dod-collect appended) between verify runs
#        → old results[] length now mismatches, must be refused until
#          the payload covers the new requirement too
#
# Runs against the source-tree scripts (dod/scripts), resolved relative to
# this test — no install needed. Each case builds an isolated throwaway git
# repo. PASS/FAIL family (ok/bad/eq), matching sibling suites.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"

WRITE="$SCRIPTS/dod-write.sh"
VERIFY_WRITE="$SCRIPTS/dod-verify-write-result.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "== test-dod-verify =="

# make_repo — task-mode fixture repo with a session baseline seeded (so the
# writer's dirty-tree check has a real baseline to classify against).
make_repo() {
  local r; r=$(hc__test_make_repo task)
  mkdir -p "$r/.claude/.harness/task-dod/verified" "$r/.claude/.harness/baselines"
  printf '%s' "$r"
}

seed_baseline() {
  # $1=repo $2=session_id — snapshot HEAD + a clean porcelain as the baseline,
  # mirroring what SessionStart (baseline-snapshot.sh) would have recorded.
  local r="$1" sid="$2"
  git -C "$r" rev-parse HEAD > "$r/.claude/.harness/baselines/${sid}.sha"
  git -C "$r" status --porcelain > "$r/.claude/.harness/baselines/${sid}.dirty"
}

collect() {
  # $1=repo $2=session_id $3=payload-json
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$1" bash "$WRITE" >/dev/null 2>&1
}

dodfile() { printf '%s/.claude/.harness/task-dod/%s.json' "$1" "$2"; }
verifiedfile() { printf '%s/.claude/.harness/task-dod/verified/%s-%s.json' "$1" "$2" "$3"; }

run_verify() {
  # $1=repo $2=session_id $3=payload-json → stdout captured, rc via $?
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$1" bash "$VERIFY_WRITE" "$2"
}

# ---------------------------------------------------------------------------
# Case 1 — no contract on file: refused.
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_baseline "$R" c1
OUT=$(run_verify "$R" c1 '{"results":[]}' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && ok "case 1: no task-dod contract on file → refused" \
  || bad "case 1: no contract → refused" "rc=$RC"

# ---------------------------------------------------------------------------
# Case 2 — results[] length mismatch vs contract requirements[]: refused.
# ---------------------------------------------------------------------------
R=$(make_repo)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
seed_baseline "$R" c2
collect "$R" c2 '{"__session_id":"c2","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"req one","origin":"prompt","added_at":"t"},{"text":"req two","origin":"prompt","added_at":"t"}]}'
OUT=$(run_verify "$R" c2 '{"results":[{"requirement_index":0,"status":"pass","evidence":"ok"}]}' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && ok "case 2: results[] shorter than requirements[] → refused" \
  || bad "case 2: length mismatch → refused" "rc=$RC out=$OUT"
printf '%s' "$OUT" | grep -q "entries but the current contract has" \
  && ok "case 2: refusal names the mismatch" \
  || bad "case 2: refusal names the mismatch" "$OUT"

# ---------------------------------------------------------------------------
# Case 3 — index set has a gap/dupe/out-of-range: refused.
# ---------------------------------------------------------------------------
R=$(make_repo)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
seed_baseline "$R" c3
collect "$R" c3 '{"__session_id":"c3","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"req one","origin":"prompt","added_at":"t"},{"text":"req two","origin":"prompt","added_at":"t"}]}'
# duplicate index 0, missing index 1
OUT=$(run_verify "$R" c3 '{"results":[{"requirement_index":0,"status":"pass","evidence":"a"},{"requirement_index":0,"status":"pass","evidence":"b"}]}' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && ok "case 3: duplicate/missing requirement_index → refused" \
  || bad "case 3: bad index set → refused" "rc=$RC out=$OUT"
# out-of-range index
OUT=$(run_verify "$R" c3 '{"results":[{"requirement_index":0,"status":"pass","evidence":"a"},{"requirement_index":5,"status":"pass","evidence":"b"}]}' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && ok "case 3: out-of-range requirement_index → refused" \
  || bad "case 3: out-of-range index → refused" "rc=$RC out=$OUT"

# ---------------------------------------------------------------------------
# Case 4 — matching results[] (pass/fail/skipped): written, shape correct.
# ---------------------------------------------------------------------------
R=$(make_repo)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
seed_baseline "$R" c4
collect "$R" c4 '{"__session_id":"c4","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"req one","origin":"prompt","added_at":"t"},{"text":"req two","origin":"prompt","added_at":"t"},{"text":"req three","origin":"prompt","added_at":"t"}]}'
OUT=$(run_verify "$R" c4 '{"results":[{"requirement_index":0,"status":"pass","evidence":"ran npm test, exit 0"},{"requirement_index":1,"status":"fail","evidence":"lint exit 1"},{"requirement_index":2,"status":"skipped","evidence":"escalation type=environment step=app_startup captured_error=no docker"}]}')
RC=$?
[ "$RC" -eq 0 ] && ok "case 4: matching results[] → accepted" \
  || bad "case 4: matching results → accepted" "rc=$RC out=$OUT"
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
F=$(verifiedfile "$R" br-feature-x "$HEAD_SHA")
[ -f "$F" ] && ok "case 4: verified result written at task_key-HEAD_SHA.json" \
  || bad "case 4: verified result file exists" "$F"
eq "case 4: task_key recorded" "br-feature-x" "$(jq -r '.task_key' "$F")"
eq "case 4: verified_sha == HEAD" "$HEAD_SHA" "$(jq -r '.verified_sha' "$F")"
eq "case 4: 3 results recorded" "3" "$(jq '.results | length' "$F")"
eq "case 4: result 0 status" "pass" "$(jq -r '.results[0].status' "$F")"
eq "case 4: result 1 status" "fail" "$(jq -r '.results[1].status' "$F")"
eq "case 4: result 2 status" "skipped" "$(jq -r '.results[2].status' "$F")"
printf '%s' "$(jq -r '.results[2].evidence' "$F")" | grep -q "escalation" \
  && ok "case 4: skipped result carries full escalation detail in evidence" \
  || bad "case 4: escalation detail in evidence" "$(jq -r '.results[2].evidence' "$F")"

# ---------------------------------------------------------------------------
# Case 5 — dirty tree (uncommitted introduced changes): refused.
# ---------------------------------------------------------------------------
R=$(make_repo)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
seed_baseline "$R" c5
collect "$R" c5 '{"__session_id":"c5","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"req one","origin":"prompt","added_at":"t"}]}'
echo "uncommitted" > "$R/uncommitted.py"
OUT=$(run_verify "$R" c5 '{"results":[{"requirement_index":0,"status":"pass","evidence":"ok"}]}' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && ok "case 5: dirty tree with introduced changes → refused" \
  || bad "case 5: dirty tree → refused" "rc=$RC out=$OUT"
printf '%s' "$OUT" | grep -q "dirty" \
  && ok "case 5: refusal mentions the dirty tree" \
  || bad "case 5: refusal mentions dirty tree" "$OUT"

# ---------------------------------------------------------------------------
# Case 6 — contract grows mid-task (dod-collect appended): old results[]
# length now mismatches and must be refused until the payload covers the
# new requirement too.
# ---------------------------------------------------------------------------
R=$(make_repo)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
seed_baseline "$R" c6
collect "$R" c6 '{"__session_id":"c6","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"req one","origin":"prompt","added_at":"t1"}]}'
# a result matching the ORIGINAL 1-requirement contract would succeed here...
# ...but before writing it, the contract grows (simulating dod-collect
# re-invoked mid-task with a new requirement).
collect "$R" c6 '{"__session_id":"c6","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"req one","origin":"prompt","added_at":"t1"},{"text":"req two, added later","origin":"follow-up","added_at":"t2"}]}'
OUT=$(run_verify "$R" c6 '{"results":[{"requirement_index":0,"status":"pass","evidence":"ok"}]}' 2>&1)
RC=$?
[ "$RC" -ne 0 ] && ok "case 6: stale 1-entry payload vs grown 2-requirement contract → refused" \
  || bad "case 6: stale payload after contract growth → refused" "rc=$RC out=$OUT"
OUT=$(run_verify "$R" c6 '{"results":[{"requirement_index":0,"status":"pass","evidence":"ok"},{"requirement_index":1,"status":"pass","evidence":"also ok"}]}')
RC=$?
[ "$RC" -eq 0 ] && ok "case 6: payload covering the grown contract → accepted" \
  || bad "case 6: payload covering grown contract → accepted" "rc=$RC out=$OUT"

echo
echo "test-dod-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
