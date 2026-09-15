#!/bin/bash
#
# Tests for the task-DoD plugin.
#
# Collection (dod-collect skill, dod-write.sh) and verification (dod-gate.sh
# Stop hook, dod-stub-done.sh) are separate concerns; there is no automatic
# nudge hook — collection is agent-invoked via the dod-collect skill, not
# hook-driven. This suite covers:
#   1  no collected DoD                                    → Stop quiet
#   2  DoD present, no verification result                 → Stop blocks
#   3  DoD present + passing verification result           → Stop allows, archives
#   4  DoD present + verification result with a failure     → Stop blocks
#   5  DoD present + malformed verification result          → Stop blocks
#   6  delete/soften an existing DoD entry                  → writer rejects
#   7  append a new entry mid-task                          → accepted, origin recorded
#   8  verified + archived, then a NEW DoD collected         → fresh cycle works
#   9  non-git / detached HEAD / mid-rebase                  → no-op, never blocks
#
# THE GATE IS CLAIM-DRIVEN. dod-gate.sh is SILENT until the agent claims it is
# finished by running dod-complete-task.sh, which arms
# task-dod/claim-<task_key>. Every case below that expects a BLOCK or an
# ARCHIVE therefore arms the latch first, via arm_claim() — which shells out to
# the REAL dod-complete-task.sh rather than hand-writing the latch file, so a
# keying mismatch between the writer and the gate fails the suite instead of
# hiding in it.
#
# Runs against the source-tree scripts (dod/scripts), resolved relative to
# this test — no install needed. Each case builds an isolated throwaway git
# repo with CLAUDE_PROJECT_DIR / CLAUDE_PLUGIN_ROOT pointed at it. PASS/FAIL
# family (ok/bad/eq), matching sibling suites.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
DOD="$ROOT/scripts"

WRITE="$DOD/dod-write.sh"
GATE="$DOD/dod-gate.sh"
STUB="$DOD/dod-stub-done.sh"
CLAIM="$DOD/dod-complete-task.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "== test-dod =="

# is_block <stdout> → 0 if the stdout is a block decision.
is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# make_repo [mode] — a fixture repo with the task-dod state dir pre-created.
# mode "task" → feature branch (task mode, key br-feature-x).
make_repo() {
  local r; r=$(hc__test_make_repo "$1")
  mkdir -p "$r/.claude/.harness/task-dod/archive" "$r/.claude/.harness/task-dod/verified"
  printf '%s' "$r"
}

# run_gate <repo> <session_id> — pipe a Stop hook payload, echo stdout.
run_gate() {
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null
}

# run_gate_active <repo> <session_id> — same, but stop_hook_active:true (the
# agent is mid-response to a prior block).
run_gate_active() {
  printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":true}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null
}

dodfile() { printf '%s/.claude/.harness/task-dod/%s.json' "$1" "$2"; }

# arm_claim <repo> <session_id> — run the REAL claim script, which arms
# task-dod/claim-<task_key>. Deliberately NOT a hand-written latch file: the
# point is to exercise the writer's own task-key derivation against the gate's.
arm_claim() { CLAUDE_PROJECT_DIR="$1" bash "$CLAIM" "$2" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Case 1 — no collected DoD: Stop quiet, regardless of what changed.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
OUT=$(run_gate "$R" c1)
[ -z "$OUT" ] && ok "case 1: no collected DoD → Stop quiet (allow), even with product changes" \
  || bad "case 1: no collected DoD → Stop quiet" "$OUT"

# ---------------------------------------------------------------------------
# Case 2 — DoD present, no verification result: Stop blocks.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf '{"__session_id":"c2","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
arm_claim "$R" c2
OUT=$(run_gate "$R" c2)
is_block "$OUT" && ok "case 2: DoD present, no verification result → Stop blocks" \
  || bad "case 2: DoD present, no verification result → Stop blocks" "$OUT"
printf '%s' "$OUT" | jq -e '.reason | test("no verification result")' >/dev/null 2>&1 \
  && ok "case 2: block reason names the missing verification" \
  || bad "case 2: block reason names the missing verification" "$OUT"

# ---------------------------------------------------------------------------
# Case 3 — DoD present + passing verification result: Stop allows, archives.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf '{"__session_id":"c3","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" c3 >/dev/null 2>&1
arm_claim "$R" c3
OUT=$(run_gate "$R" c3)
[ -z "$OUT" ] && ok "case 3: DoD present + passing verification → Stop allows (empty stdout)" \
  || bad "case 3: DoD present + passing verification → Stop allows" "$OUT"
[ -f "$R/.claude/.harness/task-dod/archive/$(git -C "$R" rev-parse HEAD).json" ] \
  && ok "case 3: live DoD archived at HEAD_SHA on allow" \
  || bad "case 3: live DoD archived at HEAD_SHA"
[ ! -f "$(dodfile "$R" br-feature-x)" ] \
  && ok "case 3: no live DoD file remains after archiving" \
  || bad "case 3: live DoD removed after archiving"

# ---------------------------------------------------------------------------
# Case 4 — DoD present + verification result with a failure: Stop blocks.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf '{"__session_id":"c4","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
mkdir -p "$R/.claude/.harness/task-dod/verified"
printf '{"task_key":"br-feature-x","verified_sha":"%s","checked_at":"t","results":[{"requirement_index":0,"status":"fail","evidence":"broke"}]}' "$HEAD_SHA" \
  > "$R/.claude/.harness/task-dod/verified/br-feature-x-${HEAD_SHA}.json"
arm_claim "$R" c4
OUT=$(run_gate "$R" c4)
is_block "$OUT" && ok "case 4: verification result with a failing requirement → Stop blocks" \
  || bad "case 4: verification result with a failure → Stop blocks" "$OUT"
printf '%s' "$OUT" | jq -e '.reason | test("failing requirement")' >/dev/null 2>&1 \
  && ok "case 4: block reason names the failing requirement(s)" \
  || bad "case 4: block reason names the failing requirement(s)" "$OUT"
[ -f "$(dodfile "$R" br-feature-x)" ] \
  && ok "case 4: live DoD NOT archived while a failure exists" \
  || bad "case 4: live DoD should remain unarchived on failure"

# ---------------------------------------------------------------------------
# Case 5 — DoD present + malformed verification result: Stop blocks.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf '{"__session_id":"c5","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
mkdir -p "$R/.claude/.harness/task-dod/verified"
printf 'not json' > "$R/.claude/.harness/task-dod/verified/br-feature-x-${HEAD_SHA}.json"
arm_claim "$R" c5
OUT=$(run_gate "$R" c5)
is_block "$OUT" && ok "case 5: malformed verification result → Stop blocks" \
  || bad "case 5: malformed verification result → Stop blocks" "$OUT"

# ---------------------------------------------------------------------------
# Case 6 — delete/soften an existing DoD entry: writer rejects.
# ---------------------------------------------------------------------------
R=$(make_repo task)
BASE='{"__session_id":"c6","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"medium","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"},{"text":"REQ TWO","origin":"prompt","added_at":"t"}]}'
printf '%s' "$BASE" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
# drop REQ TWO
DROP='{"__session_id":"c6","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"medium","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"}]}'
printf '%s' "$DROP" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok "case 6: dropping an existing requirement → writer rejects (rc=$RC)" \
  || bad "case 6: dropping an existing requirement → rejected" "rc=$RC"
# soften (reword) REQ TWO
SOFT='{"__session_id":"c6","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"medium","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"},{"text":"req two, ish","origin":"prompt","added_at":"t"}]}'
printf '%s' "$SOFT" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "case 6: rewording an existing requirement → writer rejects" \
  || bad "case 6: rewording an existing requirement → rejected"
# immutable blast_radius
BR='{"__session_id":"c6","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"},{"text":"REQ TWO","origin":"prompt","added_at":"t"}]}'
printf '%s' "$BR" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "case 6: changing blast_radius after first write → writer rejects" \
  || bad "case 6: changing blast_radius → rejected"
# original file untouched
eq "case 6: file still holds both original requirements" "REQ ONE
REQ TWO" "$(jq -r '.requirements[].text' "$(dodfile "$R" br-feature-x)")"

# ---------------------------------------------------------------------------
# Case 7 — append a new entry mid-task: accepted, origin recorded.
# ---------------------------------------------------------------------------
R=$(make_repo task)
B7='{"__session_id":"c7","created_at":"2026-02-02T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"first","origin":"prompt","added_at":"t1"}]}'
printf '%s' "$B7" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
ADD='{"__session_id":"c7","created_at":"2026-02-02T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"first","origin":"prompt","added_at":"t1"},{"text":"second, clarified later","origin":"follow-up","added_at":"t2"}]}'
printf '%s' "$ADD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
RC=$?
F=$(dodfile "$R" br-feature-x)
[ "$RC" -eq 0 ] && ok "case 7: appending a new requirement mid-task → accepted" \
  || bad "case 7: appending a new requirement → accepted" "rc=$RC"
eq "case 7: both requirements now on file, in order" "first
second, clarified later" "$(jq -r '.requirements[].text' "$F")"
eq "case 7: new entry records origin=follow-up" "follow-up" \
  "$(jq -r '.requirements[1].origin' "$F")"
# idempotent re-write of the same payload is a no-op accept (dedup by text)
printf '%s' "$ADD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
eq "case 7: re-writing the same payload → still exactly 2 (dedup by text)" "2" \
  "$(jq '.requirements | length' "$F")"

# ---------------------------------------------------------------------------
# Case 8 — verified + archived, then a NEW DoD collected: fresh cycle works.
# No automatic re-trigger exists anymore (collection is agent-invoked), so
# this only asserts the archive-then-recollect mechanics still work cleanly.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "v1" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat1 >/dev/null
printf '{"__session_id":"c8","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"task one","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" c8 >/dev/null 2>&1
SHA1=$(git -C "$R" rev-parse HEAD)
arm_claim "$R" c8
OUT=$(run_gate "$R" c8)
[ -z "$OUT" ] && ok "case 8: first task → Stop allows" || bad "case 8: first task allows" "$OUT"
[ -f "$R/.claude/.harness/task-dod/archive/$SHA1.json" ] \
  && ok "case 8: task one archived at its verified sha" \
  || bad "case 8: task one archived at verified sha"
[ ! -f "$(dodfile "$R" br-feature-x)" ] \
  && ok "case 8: no live DoD after archiving" \
  || bad "case 8: live DoD removed after archiving"
# a NEW product mutation with no new DoD collected AND no completion claim →
# Stop stays quiet. Two reasons now compound: the plugin never infers "should
# have collected" from the changeset, and the covered path above disarmed the
# latch, so the gate is back to its silent default. Deliberately NOT re-armed
# here — "unclaimed work in progress is silent" is the case under test.
echo "v2 more" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat2 >/dev/null
OUT=$(run_gate "$R" c8)
[ -z "$OUT" ] && ok "case 8: new product mutation, no DoD collected → Stop stays quiet" \
  || bad "case 8: new product mutation, no DoD collected → Stop stays quiet" "$OUT"
# now collect + verify the second task
printf '{"__session_id":"c8","created_at":"2026-03-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r2"},"requirements":[{"text":"task two","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
arm_claim "$R" c8
OUT=$(run_gate "$R" c8)
is_block "$OUT" && ok "case 8: second DoD collected, not yet verified → Stop blocks" \
  || bad "case 8: second DoD collected, not yet verified → Stop blocks" "$OUT"
CLAUDE_PROJECT_DIR="$R" bash "$STUB" c8 >/dev/null 2>&1
SHA2=$(git -C "$R" rev-parse HEAD)
OUT=$(run_gate "$R" c8)
[ -z "$OUT" ] && ok "case 8: second task verified → Stop allows" \
  || bad "case 8: second task verified → Stop allows" "$OUT"
[ -f "$R/.claude/.harness/task-dod/archive/$SHA2.json" ] \
  && ok "case 8: task two archived at its own sha" \
  || bad "case 8: task two archived at its own sha"

# ---------------------------------------------------------------------------
# Case 9 — non-git dir / detached HEAD / mid-rebase: no-op, never blocks.
# ---------------------------------------------------------------------------
# (a) non-git dir
ND=$(hc__test_mktemp_d); CLEANUP_DIRS="$CLEANUP_DIRS $ND"
mkdir -p "$ND"; echo "x" > "$ND/f.py"
OUT=$(run_gate "$ND" c9a)
[ -z "$OUT" ] && ok "case 9a: non-git dir → Stop no-op (allow)" \
  || bad "case 9a: non-git dir → no-op" "$OUT"
# (b) detached HEAD
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
git -C "$R" checkout -q --detach HEAD
OUT=$(run_gate "$R" c9b)
[ -z "$OUT" ] && ok "case 9b: detached HEAD → Stop no-op (allow)" \
  || bad "case 9b: detached HEAD → no-op" "$OUT"
# (c) mid-rebase (fake the rebase-merge dir)
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
GD=$(git -C "$R" rev-parse --git-dir); case "$GD" in /*) : ;; *) GD="$R/$GD" ;; esac
mkdir -p "$GD/rebase-merge"
OUT=$(run_gate "$R" c9c)
rmdir "$GD/rebase-merge" 2>/dev/null
[ -z "$OUT" ] && ok "case 9c: mid-rebase → Stop no-op (allow)" \
  || bad "case 9c: mid-rebase → no-op" "$OUT"

# ---------------------------------------------------------------------------
# Regression (review finding 2) — the stop_hook_active brake is category-scoped.
# A block on a DIFFERENT category must still fire while stop_hook_active:true;
# only the SAME repeated category releases.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf '{"__session_id":"c10","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
# The brake only has anything to brake once the gate is engaged at all, so the
# claim latch is armed for the whole sequence. A BLOCK never disarms it (only
# the covered path and a new user turn do), so one arm covers all three turns.
arm_claim "$R" c10
# turn 1: DoD present, no verification → block, category "dod-no-verify" recorded
run_gate "$R" c10 >/dev/null
# turn 2, stop_hook_active: same "dod-no-verify" demand → released (not trapped)
OUT=$(run_gate_active "$R" c10)
[ -z "$OUT" ] && ok "reg-2: repeated same-category block under stop_hook_active → released" \
  || bad "reg-2: repeated same-category block released" "$OUT"
# now write a failing verification result; turn 3, stop_hook_active: category
# flips to "dod-verify-failed" → MUST still block (a blanket brake would have
# swallowed this).
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
mkdir -p "$R/.claude/.harness/task-dod/verified"
printf '{"task_key":"br-feature-x","verified_sha":"%s","checked_at":"t","results":[{"requirement_index":0,"status":"fail","evidence":"broke"}]}' "$HEAD_SHA" \
  > "$R/.claude/.harness/task-dod/verified/br-feature-x-${HEAD_SHA}.json"
OUT=$(run_gate_active "$R" c10)
is_block "$OUT" && ok "reg-2: new-category block still fires under stop_hook_active" \
  || bad "reg-2: new-category block still fires under stop_hook_active" "$OUT"

echo
echo "test-dod: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
