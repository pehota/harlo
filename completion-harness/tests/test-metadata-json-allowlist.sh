#!/bin/bash
#
# metadata_json_allowlist tests — the structured sibling to noncode_globs that
# lets a version-only (or otherwise pure-metadata) bump to a JSON manifest
# (package.json, plugin.json, ...) stand down the gate the same way a
# docs-only changeset does, WITHOUT letting a glob alone wave through a real
# change to that same file (a new dependency, script, or permission).
#
# Three layers, mirroring test-scope.sh's structure:
#   (A) hc_path_is_metadata_json_safe predicate — the structural per-file diff.
#   (B) hc_changeset_is_code — the whole-changeset classifier, now consulting
#       (A) for files it cannot already clear via noncode_globs.
#   (C) done-gate.sh end-to-end — a version-only manifest bump must silently
#       stand down like a docs-only changeset; a manifest change touching any
#       other key must still gate exactly as before.
#
# Prints PASS/FAIL per assertion; exits non-zero on any failure.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$TESTS_DIR/../scripts/harness-common.sh"
GATE="$TESTS_DIR/../scripts/done-gate.sh"

[ -f "$LIB" ]  || { echo "FATAL: no harness-common.sh at $LIB" >&2; exit 1; }
[ -f "$GATE" ] || { echo "FATAL: no done-gate.sh at $GATE" >&2; exit 1; }

# shellcheck source=./test-helpers.sh
. "$TESTS_DIR/test-helpers.sh"

# make_repo — task-mode repo (feature branch off main root) with:
#   - noncode_globs = ["*.md"]        (so a CHANGELOG.md alongside a manifest
#                                       bump doesn't itself force a "code" verdict)
#   - metadata_json_allowlist = [{"glob":"package.json","keys":["version"]}]
#   - package.json seeded on the root/base commit at version 1.0.0
# Both config keys land on the ROOT commit (the task's fork base), same
# reasoning as test-scope.sh's set_noncode_globs: a done-config.json edit on
# the base itself is not part of the changeset under test.
make_repo() {
  local dir; dir=$(hc__test_make_repo)
  jq '.noncode_globs = ["*.md"]
      | .metadata_json_allowlist = [{"glob":"package.json","keys":["version"]}]' \
    "$dir/.claude/done-config.json" > "$dir/.claude/done-config.json.tmp" \
    && mv "$dir/.claude/done-config.json.tmp" "$dir/.claude/done-config.json"
  printf '{"name":"x","version":"1.0.0"}\n' > "$dir/package.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -a --amend -m root
  git -C "$dir" checkout -q -b feature/x
  printf '%s' "$dir"
}

bump_version() {
  local dir="$1" version="$2"
  jq --arg v "$version" '.version = $v' "$dir/package.json" \
    > "$dir/package.json.tmp" && mv "$dir/package.json.tmp" "$dir/package.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "bump to $version"
  git -C "$dir" rev-parse HEAD
}

add_dependency() {
  local dir="$1"
  jq '.dependencies = {"foo": "^1.0.0"}' "$dir/package.json" \
    > "$dir/package.json.tmp" && mv "$dir/package.json.tmp" "$dir/package.json"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "add dependency"
  git -C "$dir" rev-parse HEAD
}

commit_file() {
  local dir="$1" name="$2" content="$3"
  echo "$content" > "$dir/$name"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "add $name"
  git -C "$dir" rev-parse HEAD
}

# run_safe <dir> <base> <head> [path] — hc_path_is_metadata_json_safe in a
# subshell (so its env/config edits never leak between cases). Returns the
# predicate's own exit code.
run_safe() {
  local dir="$1" base="$2" head="$3" path="${4:-package.json}"
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    hc_path_is_metadata_json_safe "$path" "$base" "$head" "$dir"
  )
}

# run_pred <dir> — hc_changeset_is_code, resolved exactly as done-gate.sh sees
# it (same hc_resolve/hc_tree_status sequence as test-scope.sh's run_pred).
# Echoes "<stdout>|<rc>".
run_pred() {
  local dir="$1"
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    hc_resolve "sid-metajson" >/dev/null 2>&1
    hc_tree_status "sid-metajson" >/dev/null 2>&1
    local head out rc
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
    out=$(hc_changeset_is_code "$HC_BASE" "$head" "$dir")
    rc=$?
    printf '%s|%s' "$out" "$rc"
  )
}
pred_out() { printf '%s' "${1%%|*}"; }
pred_rc()  { printf '%s' "${1#*|}"; }

run_gate() {
  local dir="$1"
  printf '{"session_id":"sid-metajson","stop_hook_active":false}' \
    | CLAUDE_PROJECT_DIR="$dir" bash "$GATE" 2>/dev/null
}
gate_is_block() {
  printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1
}

echo "=============================================================="
echo " metadata_json_allowlist — predicate + classifier + gate stand-down"
echo "=============================================================="

# ---------------------------------------------------------------------------
# (A) hc_path_is_metadata_json_safe predicate contract
# ---------------------------------------------------------------------------

echo
echo "--- A1: version-only bump (matching glob+key) → safe / rc 0 ---"
DIR=$(make_repo)
HEAD=$(bump_version "$DIR" "1.0.1")
BASE=$(git -C "$DIR" rev-parse feature/x~1)
run_safe "$DIR" "$BASE" "$HEAD"; RC=$?
CASES=$((CASES+1))
if [ "$RC" -eq 0 ]; then printf 'PASS  A1 version-only bump is safe\n'
else FAILS=$((FAILS+1)); printf 'FAIL  A1 expected safe (rc 0), got %s\n' "$RC"; fi

echo
echo "--- A2: version bump PLUS a new key (dependencies) → unsafe / rc 1 ---"
DIR=$(make_repo)
jq '.version = "1.0.1" | .dependencies = {"foo":"^1.0.0"}' "$DIR/package.json" \
  > "$DIR/package.json.tmp" && mv "$DIR/package.json.tmp" "$DIR/package.json"
git -C "$DIR" add -A; git -C "$DIR" commit -q -m "bump + dep"
HEAD=$(git -C "$DIR" rev-parse HEAD)
BASE=$(git -C "$DIR" rev-parse feature/x~1)
run_safe "$DIR" "$BASE" "$HEAD"; RC=$?
CASES=$((CASES+1))
if [ "$RC" -ne 0 ]; then printf 'PASS  A2 version+dependencies change is unsafe\n'
else FAILS=$((FAILS+1)); printf 'FAIL  A2 expected unsafe (nonzero rc), got %s\n' "$RC"; fi

echo
echo "--- A3: path not matched by any allowlist glob → unsafe / rc 1 ---"
DIR=$(make_repo)
printf '{"a":1}\n' > "$DIR/other.json"
git -C "$DIR" add -A; git -C "$DIR" commit -q -m "add other.json"
BASE=$(git -C "$DIR" rev-parse HEAD)
jq '.a = 2' "$DIR/other.json" > "$DIR/other.json.tmp" && mv "$DIR/other.json.tmp" "$DIR/other.json"
git -C "$DIR" add -A; git -C "$DIR" commit -q -m "bump other.json"
HEAD=$(git -C "$DIR" rev-parse HEAD)
run_safe "$DIR" "$BASE" "$HEAD" "other.json"; RC=$?
CASES=$((CASES+1))
if [ "$RC" -ne 0 ]; then printf 'PASS  A3 unmatched path is unsafe\n'
else FAILS=$((FAILS+1)); printf 'FAIL  A3 expected unsafe (nonzero rc), got %s\n' "$RC"; fi

echo
echo "--- A4: file did not exist at base (newly added) → unsafe / rc 1 ---"
DIR=$(make_repo)
HEAD=$(commit_file "$DIR" "package-lock-like.json" '{"version":"1.0.0"}')
BASE=$(git -C "$DIR" rev-parse feature/x~1)
run_safe "$DIR" "$BASE" "$HEAD" "package-lock-like.json"; RC=$?
CASES=$((CASES+1))
if [ "$RC" -ne 0 ]; then printf 'PASS  A4 newly-added file is unsafe (no base content to diff)\n'
else FAILS=$((FAILS+1)); printf 'FAIL  A4 expected unsafe (nonzero rc), got %s\n' "$RC"; fi

echo
echo "--- A5: EMPTY metadata_json_allowlist → nothing is metadata-safe ---"
DIR=$(make_repo)
jq '.metadata_json_allowlist = []' "$DIR/.claude/done-config.json" \
  > "$DIR/.claude/done-config.json.tmp" && mv "$DIR/.claude/done-config.json.tmp" "$DIR/.claude/done-config.json"
HEAD=$(bump_version "$DIR" "1.0.1")
BASE=$(git -C "$DIR" rev-parse feature/x~1)
run_safe "$DIR" "$BASE" "$HEAD"; RC=$?
CASES=$((CASES+1))
if [ "$RC" -ne 0 ]; then printf 'PASS  A5 empty allowlist → unsafe (opt-out, safe direction)\n'
else FAILS=$((FAILS+1)); printf 'FAIL  A5 expected unsafe (nonzero rc), got %s\n' "$RC"; fi

# ---------------------------------------------------------------------------
# (B) hc_changeset_is_code — whole-changeset classification
# ---------------------------------------------------------------------------

echo
echo "--- B1: version-only bump + CHANGELOG.md → whole changeset noncode ---"
DIR=$(make_repo)
bump_version "$DIR" "1.0.1" >/dev/null
commit_file "$DIR" "CHANGELOG.md" "## 1.0.1" >/dev/null
R=$(run_pred "$DIR")
assert_eq "B1 stdout" "$(pred_out "$R")" "noncode"
assert_eq "B1 rc"     "$(pred_rc "$R")"  "1"

echo
echo "--- B2: version bump PLUS new key (dependencies) → whole changeset code ---"
DIR=$(make_repo)
jq '.version = "1.0.1" | .dependencies = {"foo":"^1.0.0"}' "$DIR/package.json" \
  > "$DIR/package.json.tmp" && mv "$DIR/package.json.tmp" "$DIR/package.json"
git -C "$DIR" add -A; git -C "$DIR" commit -q -m "bump + dep"
R=$(run_pred "$DIR")
assert_eq "B2 stdout" "$(pred_out "$R")" "code"
assert_eq "B2 rc"     "$(pred_rc "$R")"  "0"

echo
echo "--- B3: introduced (uncommitted) version bump → still code (dirt path skips the check) ---"
DIR=$(make_repo)
jq '.version = "1.0.1"' "$DIR/package.json" > "$DIR/package.json.tmp" && mv "$DIR/package.json.tmp" "$DIR/package.json"
R=$(run_pred "$DIR")
assert_eq "B3 stdout" "$(pred_out "$R")" "code"
assert_eq "B3 rc"     "$(pred_rc "$R")"  "0"

echo
echo "--- B4: SCOPE BOUNDARY — a real code commit, THEN a version-only bump, ---"
echo "--- classified over the WHOLE base..head range → still code (correct; ---"
echo "--- this predicate scopes the ENTIRE changeset, not the delta since the ---"
echo "--- last review — a task/session with prior code work still gates on ---"
echo "--- its trailing publish-only commit) ---"
DIR=$(make_repo)
commit_file "$DIR" "tool.sh" "echo hi" >/dev/null
bump_version "$DIR" "1.0.1" >/dev/null
R=$(run_pred "$DIR")
assert_eq "B4 stdout" "$(pred_out "$R")" "code"
assert_eq "B4 rc"     "$(pred_rc "$R")"  "0"

# ---------------------------------------------------------------------------
# (C) done-gate.sh end-to-end
# ---------------------------------------------------------------------------

echo
echo "--- C1: version-only manifest bump → gate exits 0, EMPTY stdout ---"
DIR=$(make_repo)
bump_version "$DIR" "1.0.1" >/dev/null
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if [ -z "$OUT" ]; then printf 'PASS  C1 gate silent stand-down (empty stdout)\n'
else FAILS=$((FAILS+1)); printf 'FAIL  C1 expected empty stdout, got: %s\n' "$OUT"; fi

echo
echo "--- C2: manifest change touching a non-allowed key → gate BLOCKS ---"
DIR=$(make_repo)
jq '.version = "1.0.1" | .dependencies = {"foo":"^1.0.0"}' "$DIR/package.json" \
  > "$DIR/package.json.tmp" && mv "$DIR/package.json.tmp" "$DIR/package.json"
git -C "$DIR" add -A; git -C "$DIR" commit -q -m "bump + dep"
OUT=$(run_gate "$DIR")
CASES=$((CASES+1))
if gate_is_block "$OUT"; then printf 'PASS  C2 gate blocks a manifest change outside the allowlist\n'
else FAILS=$((FAILS+1)); printf 'FAIL  C2 expected block, got: %s\n' "${OUT:-<empty>}"; fi

echo
echo "=============================================================="
echo "test-metadata-json-allowlist: $CASES cases, $FAILS failed"
[ "$FAILS" -eq 0 ]
