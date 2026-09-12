#!/bin/bash
#
# Tests for the task-DoD plugin.
#
# Covers all twelve situations from the original walking-skeleton's test
# matrix:
#   1  artifact-only changeset (docs/ only)              → no nudge, Stop quiet
#   2  product mutation via Write/Edit tool               → nudge fires
#   3  product mutation via Bash (sed/heredoc)            → nudge fires
#   4  mixed changeset (docs + code)                      → treated as product
#   5  unlisted new directory                             → treated as product (fail-closed)
#   6  product mutation, no task DoD                      → Stop blocks
#   7  task DoD present + stub-done                       → Stop allows
#   8  delete/soften an existing DoD entry                → writer rejects
#   9  append a new entry mid-task                        → accepted, origin recorded
#   10 done-state at HEAD, then a new product mutation    → new DoD required, old archived
#   11 repeated product edits                             → nudge fires once, not per edit
#   12 non-git / detached HEAD / mid-rebase               → no-op, never blocks
#
# Runs against the source-tree scripts (dod/scripts), resolved relative to
# this test — no install needed. Each case builds an isolated throwaway git
# repo with CLAUDE_PROJECT_DIR / CLAUDE_PLUGIN_ROOT pointed at it. PASS/FAIL
# family (ok/bad/eq), matching sibling suites.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"
DOD="$ROOT/scripts"

NUDGE="$DOD/dod-nudge.sh"
WRITE="$DOD/dod-write.sh"
GATE="$DOD/dod-gate.sh"
STUB="$DOD/dod-stub-done.sh"

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
  mkdir -p "$r/.claude/.harness/task-dod/archive"
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

# run_nudge <repo> <session_id> [tool] — pipe a PostToolUse payload, echo stdout.
run_nudge() {
  local tool="${3:-Bash}"
  printf '{"session_id":"%s","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{}}' "$2" "$tool" \
    | CLAUDE_PROJECT_DIR="$1" bash "$NUDGE" 2>/dev/null
}

# seed_session_baseline <repo> <sid> — run the real SessionStart hook so the
# tree baseline (.dirty) and .sha anchor exist for session-mode cases. This
# plugin has no baseline-snapshot.sh of its own (that hook belongs to the full
# harness), so seed the baseline files directly in the shape hc_resolve /
# hc_tree_status expect.
seed_session_baseline() {
  local repo="$1" sid="$2"
  mkdir -p "$repo/.claude/.harness/baselines"
  git -C "$repo" rev-parse HEAD > "$repo/.claude/.harness/baselines/${sid}.sha" 2>/dev/null
  git -C "$repo" status --porcelain > "$repo/.claude/.harness/baselines/${sid}.dirty" 2>/dev/null
}

marker()  { cat "$1/.claude/.harness/task-dod/.nudged-$2" 2>/dev/null; }
dodfile() { printf '%s/.claude/.harness/task-dod/%s.json' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Case 1 — artifact-only changeset (docs/ only): no nudge, Stop quiet.
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_session_baseline "$R" c1
mkdir -p "$R/docs"; echo "notes" > "$R/docs/plan.md"
git -C "$R" add -A; git -C "$R" commit -qm "docs: plan" >/dev/null
OUT=$(run_nudge "$R" c1)
[ -z "$OUT" ] && [ ! -f "$R/.claude/.harness/task-dod/.nudged-session-c1" ] \
  && ok "case 1: docs-only changeset → no nudge" \
  || bad "case 1: docs-only changeset → no nudge" "$OUT"
OUT=$(run_gate "$R" c1)
[ -z "$OUT" ] && ok "case 1: docs-only changeset → Stop quiet (allow)" \
  || bad "case 1: docs-only changeset → Stop quiet" "$OUT"

# ---------------------------------------------------------------------------
# Case 2 — product mutation via Write/Edit tool: nudge fires.
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_session_baseline "$R" c2
echo "print('x')" > "$R/app.py"            # an untracked product file (as a Write would leave)
OUT=$(run_nudge "$R" c2 Write)
is_msg() { printf '%s' "$1" | jq -e '.systemMessage | test("task DoD")' >/dev/null 2>&1; }
is_msg "$OUT" && [ -f "$R/.claude/.harness/task-dod/.nudged-session-c2" ] \
  && ok "case 2: product mutation via Write → nudge fires + marker" \
  || bad "case 2: product mutation via Write → nudge fires" "$OUT"

# ---------------------------------------------------------------------------
# Case 3 — product mutation via Bash (sed/heredoc): nudge fires.
# The nudge is changeset-derived, tool-agnostic — a Bash payload with no
# file_path still triggers because the tree carries a product change.
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_session_baseline "$R" c3
cat > "$R/lib.rb" <<'RB'
def hi; end
RB
OUT=$(run_nudge "$R" c3 Bash)
is_msg "$OUT" && [ -f "$R/.claude/.harness/task-dod/.nudged-session-c3" ] \
  && ok "case 3: product mutation via Bash → nudge fires" \
  || bad "case 3: product mutation via Bash → nudge fires" "$OUT"

# ---------------------------------------------------------------------------
# Case 4 — mixed changeset (docs + code): treated as product.
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_session_baseline "$R" c4
mkdir -p "$R/docs"; echo "d" > "$R/docs/x.md"; echo "c" > "$R/core.go"
OUT=$(run_gate "$R" c4)
is_block "$OUT" && ok "case 4: docs+code → treated as product (Stop blocks, no DoD)" \
  || bad "case 4: docs+code → Stop blocks" "$OUT"

# ---------------------------------------------------------------------------
# Case 5 — unlisted new directory: treated as product (fail-closed).
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_session_baseline "$R" c5
mkdir -p "$R/newthing"; echo "x" > "$R/newthing/a.txt"
OUT=$(run_gate "$R" c5)
is_block "$OUT" && ok "case 5: unlisted new dir → product (fail-closed, Stop blocks)" \
  || bad "case 5: unlisted new dir → Stop blocks" "$OUT"
# and the classifier itself:
( . "$SCRIPTS/harness-common.sh"; . "$DOD/lib-classify.sh"
  dod_is_product_path "newthing/a.txt" ) \
  && ok "case 5: dod_is_product_path('newthing/a.txt') → product" \
  || bad "case 5: dod_is_product_path unlisted → product"
( . "$SCRIPTS/harness-common.sh"; . "$DOD/lib-classify.sh"
  dod_is_product_path "docs/README.md" ) \
  && bad "case 5: docs/README.md wrongly product" \
  || ok "case 5: dod_is_product_path('docs/README.md') → artifact (README* by basename)"

# ---------------------------------------------------------------------------
# Case 6 — product mutation, no task DoD: Stop blocks. (task mode)
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
OUT=$(run_gate "$R" c6)
is_block "$OUT" && ok "case 6: product committed, no DoD → Stop blocks" \
  || bad "case 6: product committed, no DoD → Stop blocks" "$OUT"
printf '%s' "$OUT" | jq -e '.reason | test("no task DoD")' >/dev/null 2>&1 \
  && ok "case 6: block reason names the missing task DoD" \
  || bad "case 6: block reason names the missing task DoD" "$OUT"

# ---------------------------------------------------------------------------
# Case 7 — task DoD present + stub-done: Stop allows.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf '{"__session_id":"c7","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
OUT=$(run_gate "$R" c7)
is_block "$OUT" && ok "case 7: DoD present, /done not run → Stop still blocks" \
  || bad "case 7: DoD present, /done not run → Stop blocks" "$OUT"
CLAUDE_PROJECT_DIR="$R" bash "$STUB" c7 >/dev/null 2>&1
OUT=$(run_gate "$R" c7)
[ -z "$OUT" ] && ok "case 7: DoD present + stub-done → Stop allows (empty stdout)" \
  || bad "case 7: DoD present + stub-done → Stop allows" "$OUT"
[ -f "$R/.claude/.harness/task-dod/archive/$(git -C "$R" rev-parse HEAD).json" ] \
  && ok "case 7: live DoD archived by verified_sha on allow" \
  || bad "case 7: live DoD archived by verified_sha"

# ---------------------------------------------------------------------------
# Case 8 — delete/soften an existing DoD entry: writer rejects.
# ---------------------------------------------------------------------------
R=$(make_repo task)
BASE='{"__session_id":"c8","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"medium","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"},{"text":"REQ TWO","origin":"prompt","added_at":"t"}]}'
printf '%s' "$BASE" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
# drop REQ TWO
DROP='{"__session_id":"c8","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"medium","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"}]}'
printf '%s' "$DROP" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok "case 8: dropping an existing requirement → writer rejects (rc=$RC)" \
  || bad "case 8: dropping an existing requirement → rejected" "rc=$RC"
# soften (reword) REQ TWO
SOFT='{"__session_id":"c8","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"medium","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"},{"text":"req two, ish","origin":"prompt","added_at":"t"}]}'
printf '%s' "$SOFT" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "case 8: rewording an existing requirement → writer rejects" \
  || bad "case 8: rewording an existing requirement → rejected"
# immutable blast_radius
BR='{"__session_id":"c8","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"REQ ONE","origin":"prompt","added_at":"t"},{"text":"REQ TWO","origin":"prompt","added_at":"t"}]}'
printf '%s' "$BR" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
[ "$?" -ne 0 ] && ok "case 8: changing blast_radius after first write → writer rejects" \
  || bad "case 8: changing blast_radius → rejected"
# original file untouched
eq "case 8: file still holds both original requirements" "REQ ONE
REQ TWO" "$(jq -r '.requirements[].text' "$(dodfile "$R" br-feature-x)")"

# ---------------------------------------------------------------------------
# Case 9 — append a new entry mid-task: accepted, origin recorded.
# ---------------------------------------------------------------------------
R=$(make_repo task)
B9='{"__session_id":"c9","created_at":"2026-02-02T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"first","origin":"prompt","added_at":"t1"}]}'
printf '%s' "$B9" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
ADD='{"__session_id":"c9","created_at":"2026-02-02T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"first","origin":"prompt","added_at":"t1"},{"text":"second, clarified later","origin":"follow-up","added_at":"t2"}]}'
printf '%s' "$ADD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
RC=$?
F=$(dodfile "$R" br-feature-x)
[ "$RC" -eq 0 ] && ok "case 9: appending a new requirement mid-task → accepted" \
  || bad "case 9: appending a new requirement → accepted" "rc=$RC"
eq "case 9: both requirements now on file, in order" "first
second, clarified later" "$(jq -r '.requirements[].text' "$F")"
eq "case 9: new entry records origin=follow-up" "follow-up" \
  "$(jq -r '.requirements[1].origin' "$F")"
# idempotent re-write of the same payload is a no-op accept (dedup by text)
printf '%s' "$ADD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
eq "case 9: re-writing the same payload → still exactly 2 (dedup by text)" "2" \
  "$(jq '.requirements | length' "$F")"

# ---------------------------------------------------------------------------
# Case 10 — done-state at HEAD, then a NEW product mutation: new DoD required,
# old one archived by the previous verified_sha.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "v1" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat1 >/dev/null
printf '{"__session_id":"c10","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"task one","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" c10 >/dev/null 2>&1
SHA1=$(git -C "$R" rev-parse HEAD)
OUT=$(run_gate "$R" c10)
[ -z "$OUT" ] && ok "case 10: first task → Stop allows" || bad "case 10: first task allows" "$OUT"
[ -f "$R/.claude/.harness/task-dod/archive/$SHA1.json" ] \
  && ok "case 10: task one archived at its verified_sha" \
  || bad "case 10: task one archived at verified_sha"
[ ! -f "$(dodfile "$R" br-feature-x)" ] \
  && ok "case 10: no live DoD after the boundary" \
  || bad "case 10: live DoD removed at the boundary"
# a NEW product mutation past that SHA
echo "v2 more" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat2 >/dev/null
OUT=$(run_gate "$R" c10)
is_block "$OUT" && ok "case 10: new product mutation past verified_sha → fresh DoD required (blocks)" \
  || bad "case 10: new product mutation past verified_sha → blocks" "$OUT"

# ---------------------------------------------------------------------------
# Case 11 — repeated product edits: nudge fires once, not per edit.
# ---------------------------------------------------------------------------
R=$(make_repo)
seed_session_baseline "$R" c11
echo "a" > "$R/one.py"
OUT1=$(run_nudge "$R" c11 Write)
echo "b" > "$R/two.py"
OUT2=$(run_nudge "$R" c11 Write)
echo "c" >> "$R/one.py"
OUT3=$(run_nudge "$R" c11 Bash)
{ is_msg "$OUT1" && [ -z "$OUT2" ] && [ -z "$OUT3" ]; } \
  && ok "case 11: nudge fires on the FIRST product edit only (2nd/3rd silent)" \
  || bad "case 11: nudge fires once" "1=[$OUT1] 2=[$OUT2] 3=[$OUT3]"

# ---------------------------------------------------------------------------
# Case 12 — non-git dir / detached HEAD / mid-rebase: no-op, never blocks.
# ---------------------------------------------------------------------------
# (a) non-git dir
ND=$(hc__test_mktemp_d); CLEANUP_DIRS="$CLEANUP_DIRS $ND"
mkdir -p "$ND"; echo "x" > "$ND/f.py"
OUT=$(run_gate "$ND" c12a)
[ -z "$OUT" ] && ok "case 12a: non-git dir → Stop no-op (allow)" \
  || bad "case 12a: non-git dir → no-op" "$OUT"
# (b) detached HEAD
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
git -C "$R" checkout -q --detach HEAD
OUT=$(run_gate "$R" c12b)
[ -z "$OUT" ] && ok "case 12b: detached HEAD → Stop no-op (allow)" \
  || bad "case 12b: detached HEAD → no-op" "$OUT"
# (c) mid-rebase (fake the rebase-merge dir)
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
GD=$(git -C "$R" rev-parse --git-dir); case "$GD" in /*) : ;; *) GD="$R/$GD" ;; esac
mkdir -p "$GD/rebase-merge"
OUT=$(run_gate "$R" c12c)
rmdir "$GD/rebase-merge" 2>/dev/null
[ -z "$OUT" ] && ok "case 12c: mid-rebase → Stop no-op (allow)" \
  || bad "case 12c: mid-rebase → no-op" "$OUT"

# ---------------------------------------------------------------------------
# Regression (review finding 1) — pre-existing baseline dirt must NOT trigger
# the DoD demand. An idle session in a repo with a product file that predates
# the session baseline stays quiet.
# ---------------------------------------------------------------------------
R=$(make_repo)
echo "stray" > "$R/stray.py"          # product dirt BEFORE the baseline
seed_session_baseline "$R" c13         # baseline now records stray.py as pre-existing
OUT=$(run_gate "$R" c13)
[ -z "$OUT" ] && ok "reg-1: pre-existing product dirt (baseline warning) → Stop quiet" \
  || bad "reg-1: pre-existing product dirt → Stop quiet" "$OUT"

# ---------------------------------------------------------------------------
# Regression (review finding 2) — the stop_hook_active brake is category-scoped.
# A block on a DIFFERENT category must still fire while stop_hook_active:true;
# only the SAME repeated category releases.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
# turn 1: no DoD → block, category "no-dod" recorded
run_gate "$R" c14 >/dev/null
# turn 2, stop_hook_active: same "no-dod" demand → released (not trapped)
OUT=$(run_gate_active "$R" c14)
[ -z "$OUT" ] && ok "reg-2: repeated same-category block under stop_hook_active → released" \
  || bad "reg-2: repeated same-category block released" "$OUT"
# now write the DoD; turn 3, stop_hook_active: category flips to "dod-no-done"
# → MUST still block (a blanket brake would have swallowed this).
printf '{"__session_id":"c14","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
OUT=$(run_gate_active "$R" c14)
is_block "$OUT" && ok "reg-2: new-category block still fires under stop_hook_active" \
  || bad "reg-2: new-category block still fires under stop_hook_active" "$OUT"

# ---------------------------------------------------------------------------
# Regression (review finding 3) — HEAD advancing past verified_sha must NOT by
# itself re-trigger the gate. A bare re-commit of already-verified content
# (e.g. `git add && git commit` of a file written and verified in a prior
# turn, or an empty/metadata-only commit) moves HEAD without introducing any
# NEW product change and must stay allowed.
# ---------------------------------------------------------------------------
R=$(make_repo task)
echo "v1" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat1 >/dev/null
printf '{"__session_id":"c15","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"task one","origin":"prompt","added_at":"t"}]}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITE" >/dev/null 2>&1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" c15 >/dev/null 2>&1
OUT=$(run_gate "$R" c15)
[ -z "$OUT" ] && ok "case 15: first task → Stop allows" || bad "case 15: first task allows" "$OUT"
# a commit that touches NOTHING new (empty commit) past the verified boundary
git -C "$R" commit -q --allow-empty -m "chore: no-op" >/dev/null
OUT=$(run_gate "$R" c15)
[ -z "$OUT" ] && ok "case 15: empty commit past verified_sha → Stop stays quiet" \
  || bad "case 15: empty commit past verified_sha → Stop stays quiet" "$OUT"

# ---------------------------------------------------------------------------
# Extra — the fallback artifact-path list matches the shipped default config.
# This plugin has no contracts/done-config.default.json of its own (that
# artifact lives in the full completion-harness bundle) — assert the literal
# lib-classify.sh fallback stays predictable instead.
# ---------------------------------------------------------------------------
LIB=$( . "$DOD/lib-classify.sh"; printf '%s' "$DOD_DEFAULT_ARTIFACT_PATHS" )
eq "extra: lib-classify fallback list is the documented default" \
  "docs/** tasks/** README* CHANGELOG* LICENSE*" "$LIB"

echo
echo "test-dod: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
