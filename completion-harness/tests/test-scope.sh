#!/bin/bash
#
# Scope-gating tests for #5 — the harness stands down on non-code changesets.
#
# Two layers, both self-contained (bash + git + jq; no bats, no install step):
#   (A) hc_changeset_is_code predicate — sourced from the REAL harness-common.sh,
#       exercised over real throwaway git repos. Asserts the code/noncode/empty
#       contract, the fail-safe (unknown ext → code), and config tunability.
#   (B) done-gate.sh end-to-end — a non-code changeset must exit 0 with EMPTY
#       stdout (silent stand-down, NOT a block), while a code changeset still
#       gates exactly as before.
#
# Prints PASS/FAIL per assertion; exits non-zero on any failure.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$TESTS_DIR/../scripts/harness-common.sh"
GATE="$TESTS_DIR/../scripts/done-gate.sh"
FIX="$TESTS_DIR/fixtures"

[ -f "$LIB" ]  || { echo "FATAL: no harness-common.sh at $LIB" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FATAL: no done-gate.sh at $GATE" >&2; exit 1; }

FAILS=0
CASES=0

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  CASES=$((CASES + 1))
  if [ "$actual" = "$expected" ]; then
    printf 'PASS  %s (= %s)\n' "$label" "$expected"
  else
    printf 'FAIL  %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual"
    FAILS=$((FAILS + 1))
  fi
}

# --- throwaway repo scaffolding ---------------------------------------------
CLEANUP_DIRS=""
cleanup() {
  local d
  for d in $CLEANUP_DIRS; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

# make_repo — task-mode repo (feature branch off main root). Echoes its path.
make_repo() {
  local dir
  dir=$(mktemp -d)
  CLEANUP_DIRS="$CLEANUP_DIRS $dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email "t@t.t"
  git -C "$dir" config user.name  "t"
  mkdir -p "$dir/.claude/.harness/done-state" \
           "$dir/.claude/.harness/review-log" \
           "$dir/.claude/.harness/baselines" \
           "$dir/.claude/.harness/tree-base" \
           "$dir/.claude/.harness/task-base"
  # The shared fixture ships noncode_globs=[] (so OTHER suites keep pre-#5
  # "everything is code"); this suite exercises the ALLOWLIST, so seed the
  # production default set (mirrors install.sh / done-detect.sh).
  jq '.noncode_globs = ["*.md","*.markdown","*.txt","*.rst","*.adoc","*.org","LICENSE","LICENSE.*","NOTICE","*.png","*.jpg","*.jpeg","*.gif","*.svg","*.webp","*.ico","*.pdf"]' \
    "$FIX/done-config.json" > "$dir/.claude/done-config.json"
  echo ".claude/.harness/" > "$dir/.gitignore"
  echo "root" > "$dir/root.txt"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "root"
  git -C "$dir" checkout -q -b feature/x
  printf '%s' "$dir"
}

commit_change() {
  local dir="$1" name="$2" content="$3"
  echo "$content" > "$dir/$name"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "add $name"
  git -C "$dir" rev-parse HEAD
}

# Run hc_changeset_is_code in a subshell against the repo (resolves identity
# first so HC_BASE + HC_TREE_BLOCKERS are populated exactly as callers see them).
# Echoes "<stdout>|<rc>".
run_pred() {
  local dir="$1"
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    hc_resolve "sid-scope" >/dev/null 2>&1
    hc_tree_status "sid-scope" >/dev/null 2>&1
    local head out rc
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
    out=$(hc_changeset_is_code "$HC_BASE" "$head" "$dir")
    rc=$?
    printf '%s|%s' "$out" "$rc"
  )
}
pred_out() { printf '%s' "${1%%|*}"; }
pred_rc()  { printf '%s' "${1#*|}"; }

# Run the real Stop gate against the repo. Echoes "<stdout>". A block prints
# decision JSON; a silent stand-down (or allow) prints nothing.
run_gate() {
  local dir="$1"
  printf '{"session_id":"sid-scope","stop_hook_active":false}' \
    | CLAUDE_PROJECT_DIR="$dir" bash "$GATE" 2>/dev/null
}
gate_is_block() {
  printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1
}

echo "=============================================================="
echo " scope-gating (#5) — predicate + gate stand-down"
echo "=============================================================="

# ---------------------------------------------------------------------------
# (A) hc_changeset_is_code predicate contract
# ---------------------------------------------------------------------------

echo
echo "--- A1: committed .md/.txt only → noncode / rc 1 ---"
DIR=$(make_repo)
commit_change "$DIR" "notes.md"   "# notes" >/dev/null
commit_change "$DIR" "readme.txt" "hi"      >/dev/null
R=$(run_pred "$DIR")
assert_eq "A1 stdout" "$(pred_out "$R")" "noncode"
assert_eq "A1 rc"     "$(pred_rc "$R")"  "1"

echo
echo "--- A2: code file (.sh) among .md → code / rc 0 ---"
DIR=$(make_repo)
commit_change "$DIR" "doc.md"    "# d"     >/dev/null
commit_change "$DIR" "script.sh" "echo hi" >/dev/null
R=$(run_pred "$DIR")
assert_eq "A2 stdout" "$(pred_out "$R")" "code"
assert_eq "A2 rc"     "$(pred_rc "$R")"  "0"

echo
echo "--- A3: UNKNOWN extension alone (.xyz) → code / rc 0 (fail-safe) ---"
DIR=$(make_repo)
commit_change "$DIR" "thing.xyz" "data" >/dev/null
R=$(run_pred "$DIR")
assert_eq "A3 stdout" "$(pred_out "$R")" "code"
assert_eq "A3 rc"     "$(pred_rc "$R")"  "0"

echo
echo "--- A4: empty changeset (HEAD==base, clean) → empty / rc 2 ---"
DIR=$(make_repo)                       # feature/x sits AT the root/base, clean
R=$(run_pred "$DIR")
assert_eq "A4 stdout" "$(pred_out "$R")" "empty"
assert_eq "A4 rc"     "$(pred_rc "$R")"  "2"

echo
echo "--- A5: introduced .md dirt only (uncommitted) → noncode / rc 1 ---"
DIR=$(make_repo)
echo "# wip" > "$DIR/wip.md"           # untracked → introduced blocker, non-code
R=$(run_pred "$DIR")
assert_eq "A5 stdout" "$(pred_out "$R")" "noncode"
assert_eq "A5 rc"     "$(pred_rc "$R")"  "1"

echo
echo "--- A6: introduced .sh dirt → code / rc 0 (still in scope) ---"
DIR=$(make_repo)
echo "echo hi" > "$DIR/wip.sh"
R=$(run_pred "$DIR")
assert_eq "A6 stdout" "$(pred_out "$R")" "code"
assert_eq "A6 rc"     "$(pred_rc "$R")"  "0"

# set_noncode_globs <dir> <jq-array-literal> — rewrite noncode_globs AND commit
# it onto the BASE (main) so the override is part of the anchor, not the
# changeset under test (a .claude/done-config.json edit is not matched by the
# globs and would otherwise show up as a code file in base..HEAD).
set_noncode_globs() {
  local dir="$1" arr="$2"
  git -C "$dir" checkout -q main
  jq ".noncode_globs = $arr" "$dir/.claude/done-config.json" \
    > "$dir/.claude/done-config.json.tmp" \
    && mv "$dir/.claude/done-config.json.tmp" "$dir/.claude/done-config.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "config: noncode_globs"
  git -C "$dir" checkout -q feature/x
  git -C "$dir" rebase -q main >/dev/null 2>&1
}

echo
echo "--- A7: config override adds *.xyz → a .xyz-only changeset is noncode ---"
DIR=$(make_repo)
set_noncode_globs "$DIR" '["*.md","*.xyz"]'
commit_change "$DIR" "thing.xyz" "data" >/dev/null
R=$(run_pred "$DIR")
assert_eq "A7 stdout" "$(pred_out "$R")" "noncode"
assert_eq "A7 rc"     "$(pred_rc "$R")"  "1"

echo
echo "--- A8: EMPTY noncode_globs → nothing is non-code → .md is code ---"
DIR=$(make_repo)
jq '.noncode_globs = []' "$DIR/.claude/done-config.json" \
  > "$DIR/.claude/done-config.json.tmp" && mv "$DIR/.claude/done-config.json.tmp" "$DIR/.claude/done-config.json"
commit_change "$DIR" "notes.md" "# n" >/dev/null
R=$(run_pred "$DIR")
assert_eq "A8 stdout (empty globs → all code, safe)" "$(pred_out "$R")" "code"
assert_eq "A8 rc"     "$(pred_rc "$R")"  "0"

echo
echo "--- A9: nested path .md (docs/a.md) → noncode (glob spans '/') ---"
DIR=$(make_repo)
mkdir -p "$DIR/docs"
echo "# d" > "$DIR/docs/a.md"
git -C "$DIR" add -A
git -C "$DIR" commit -q -m "docs"
R=$(run_pred "$DIR")
assert_eq "A9 stdout" "$(pred_out "$R")" "noncode"

# ---------------------------------------------------------------------------
# (B) done-gate.sh end-to-end
# ---------------------------------------------------------------------------

echo
echo "--- B1: committed .md/.txt only → gate exits 0, EMPTY stdout (stand down) ---"
DIR=$(make_repo)
commit_change "$DIR" "notes.md"   "# notes" >/dev/null
commit_change "$DIR" "readme.txt" "hi"      >/dev/null
OUT=$(run_gate "$DIR")
if [ -z "$OUT" ]; then
  CASES=$((CASES+1)); printf 'PASS  B1 gate silent stand-down (empty stdout)\n'
else
  CASES=$((CASES+1)); FAILS=$((FAILS+1)); printf 'FAIL  B1 expected empty stdout, got: %s\n' "$OUT"
fi

echo
echo "--- B2: committed .sh among .md → gate BLOCKS (S2 committed-unverified) ---"
DIR=$(make_repo)
commit_change "$DIR" "doc.md"    "# d"     >/dev/null
commit_change "$DIR" "script.sh" "echo hi" >/dev/null
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if gate_is_block "$OUT"; then printf 'PASS  B2 gate blocks a code changeset\n'
else FAILS=$((FAILS+1)); printf 'FAIL  B2 expected block, got: %s\n' "${OUT:-<empty>}"; fi

echo
echo "--- B3: UNKNOWN ext alone (.xyz) → gate BLOCKS (fail-safe) ---"
DIR=$(make_repo)
commit_change "$DIR" "thing.xyz" "data" >/dev/null
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if gate_is_block "$OUT"; then printf 'PASS  B3 unknown-ext changeset gates (fail-safe)\n'
else FAILS=$((FAILS+1)); printf 'FAIL  B3 expected block, got: %s\n' "${OUT:-<empty>}"; fi

echo
echo "--- B4: introduced .md dirt only → gate exits 0, EMPTY stdout ---"
DIR=$(make_repo)
echo "# wip" > "$DIR/wip.md"
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if [ -z "$OUT" ]; then printf 'PASS  B4 non-code dirt stands down\n'
else FAILS=$((FAILS+1)); printf 'FAIL  B4 expected empty stdout, got: %s\n' "$OUT"; fi

echo
echo "--- B5: introduced .sh dirt → gate BLOCKS (Step 3b, S1) ---"
DIR=$(make_repo)
echo "echo hi" > "$DIR/wip.sh"
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if gate_is_block "$OUT"; then printf 'PASS  B5 code dirt still blocks\n'
else FAILS=$((FAILS+1)); printf 'FAIL  B5 expected block, got: %s\n' "${OUT:-<empty>}"; fi

echo
echo "--- B6: empty changeset (clean, HEAD==base) → gate exits 0 quietly (S0) ---"
DIR=$(make_repo)
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if [ -z "$OUT" ]; then printf 'PASS  B6 empty changeset quiet-exit (unchanged)\n'
else FAILS=$((FAILS+1)); printf 'FAIL  B6 expected empty stdout, got: %s\n' "$OUT"; fi

echo
echo "--- B7: config override *.xyz → a .xyz-only changeset now stands down ---"
DIR=$(make_repo)
set_noncode_globs "$DIR" '["*.md","*.xyz"]'
commit_change "$DIR" "thing.xyz" "data" >/dev/null
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if [ -z "$OUT" ]; then printf 'PASS  B7 override makes .xyz stand down\n'
else FAILS=$((FAILS+1)); printf 'FAIL  B7 expected empty stdout, got: %s\n' "$OUT"; fi

# ============================================================================
# C — hc_cfg, the layered config read. The SESSION layer
#     (.claude/.harness/session-config.json) is how an instruction the user gave
#     in chat reaches a hook, which runs as a static command with no argv the
#     conversation can address. These cases pin the layering and the degrades.
# ============================================================================
echo
echo "--- C: hc_cfg layering + degrades ---"

# cfg <repo> <key> <default> — evaluate hc_cfg exactly as a hook would.
cfg() {
  local dir="$1" key="$2" def="$3"
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    hc_cfg "$key" "$def"
  )
}
seed_session_cfg() {
  mkdir -p "$1/.claude/.harness" 2>/dev/null
  printf '%s\n' "$2" > "$1/.claude/.harness/session-config.json"
}

DIR=$(make_repo)
jq '.auto_branch = true | .trunk = "main"' "$DIR/.claude/done-config.json" > "$DIR/c.tmp" \
  && mv "$DIR/c.tmp" "$DIR/.claude/done-config.json"

assert_eq "C1 repo layer read"                 "$(cfg "$DIR" auto_branch true)"  "true"
assert_eq "C2 built-in default when key absent" "$(cfg "$DIR" nope_key fallback)" "fallback"

# The whole point of the has() probe: a literal false must not be flipped back
# to the default by jq's `//`.
seed_session_cfg "$DIR" '{"auto_branch":false}'
assert_eq "C3 session layer wins (literal false survives)" "$(cfg "$DIR" auto_branch true)" "false"

# An explicit null is "unset at this layer" → fall through to the repo config.
seed_session_cfg "$DIR" '{"auto_branch":null}'
assert_eq "C4 session null falls through to repo layer" "$(cfg "$DIR" auto_branch false)" "true"

# Malformed session JSON must not poison the read: jq fails on it, so the repo
# layer answers. Degrading toward the persisted config, never toward a fabricated
# value, is the safe direction.
seed_session_cfg "$DIR" '{not json'
assert_eq "C5 malformed session layer degrades to repo layer" "$(cfg "$DIR" auto_branch false)" "true"
rm -f "$DIR/.claude/.harness/session-config.json"

# Arrays are space-joined — the shape the glob-list readers consume.
seed_session_cfg "$DIR" '{"noncode_globs":["*.md","*.rst"]}'
assert_eq "C6 array value is space-joined" "$(cfg "$DIR" noncode_globs X)" "*.md *.rst"
rm -f "$DIR/.claude/.harness/session-config.json"

# The session layer reaches the SCOPE rule end to end: declaring .sh non-code
# for this task alone flips a code changeset to noncode.
DIR=$(make_repo)
commit_change "$DIR" "tool.sh" "echo hi" >/dev/null
R=$(run_pred "$DIR")
assert_eq "C7 .sh is code by default" "$(pred_out "$R")" "code"
seed_session_cfg "$DIR" '{"noncode_globs":["*.sh"]}'
R=$(run_pred "$DIR")
assert_eq "C8 session noncode_globs reaches hc_changeset_is_code" "$(pred_out "$R")" "noncode"

echo
echo "=============================================================="
if [ "$FAILS" -eq 0 ]; then
  printf ' ALL %d ASSERTIONS PASSED\n' "$CASES"
  echo "=============================================================="
  exit 0
else
  printf ' %d/%d ASSERTIONS FAILED\n' "$FAILS" "$CASES"
  echo "=============================================================="
  exit 1
fi
