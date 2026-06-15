#!/usr/bin/env bash
# Regression test for the shell-injection fix in templates/.claude/hooks/format-and-check.sh
#
# The hook used to interpolate the agent-controlled file_path into an eval string
# unquoted-but-double-quoted: eval "$FMT \"$fp\"". A file_path containing a double
# quote could break out and inject arbitrary commands. The fix shell-quotes the path
# via printf '%q' before interpolation. This test drives the hook over stdin with a
# malicious file_path and proves no injected command runs.
#
# Self-contained: pure bash + jq. Creates a throwaway REPO via mktemp -d and points
# the hook at it with CLAUDE_PROJECT_DIR.

set -uo pipefail

# Locate the hook relative to this script so the test works from any cwd.
# Allow override via $HOOK so the validation harness can point at a copy.
HOOK="${HOOK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/.claude/hooks/format-and-check.sh}"

if [ ! -f "$HOOK" ]; then
  echo "FATAL: hook not found at $HOOK" >&2
  exit 2
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# A recorder script: appends each invocation's args (as one line) to an ARGS file.
# Used as the format / lint_file command so we can assert exactly what was passed.
RECORDER="$TMP/recorder.sh"
cat >"$RECORDER" <<'EOF'
#!/usr/bin/env bash
# Record the argument vector this command received: number of args, then each arg.
printf 'argc=%d' "$#" >>"$ARGS_FILE"
for a in "$@"; do printf ' [%s]' "$a" >>"$ARGS_FILE"; done
printf '\n' >>"$ARGS_FILE"
EOF
chmod +x "$RECORDER"

# Build a .harness.json in the temp repo. $1=format command, $2=lint_file command.
write_cfg() {
  jq -n --arg fmt "$1" --arg lf "$2" \
    '{test_file_exts:["ts","tsx"], commands:{format:$fmt, lint_file:$lf}}' \
    >"$TMP/.harness.json"
}

# Run the hook with a given file_path JSON-encoded over stdin.
run_hook() {
  local fp="$1"
  jq -n --arg fp "$fp" '{tool_input:{file_path:$fp}}' \
    | CLAUDE_PROJECT_DIR="$TMP" bash "$HOOK" >/dev/null 2>&1
}

# Count lines in a file (0 if absent).
line_count() {
  [ -f "$1" ] && wc -l <"$1" | tr -d ' ' || echo 0
}

# ---------------------------------------------------------------------------
# Case 1: INJECTION via commands.format
# ---------------------------------------------------------------------------
case_injection_format() {
  local name="injection-format"
  rm -f "$TMP/ARGS_FMT" "$TMP/INJECTED_FMT"
  # format = recorder; lint_file = harmless ":" so only format records.
  ARGS_FILE="$TMP/ARGS_FMT" write_cfg "ARGS_FILE='$TMP/ARGS_FMT' '$RECORDER'" ":"
  # Malicious path: closes the quote, runs touch sentinel, ends in .ts to pass the ext gate.
  local payload="x\";touch $TMP/INJECTED_FMT;\".ts"
  ARGS_FILE="$TMP/ARGS_FMT" run_hook "$payload"

  if [ -e "$TMP/INJECTED_FMT" ]; then
    fail "$name: injection succeeded (sentinel INJECTED_FMT was created)"
    return
  fi
  local n; n=$(line_count "$TMP/ARGS_FMT")
  if [ "$n" != "1" ]; then
    fail "$name: format recorder got $n invocations/lines, expected exactly 1 (arg-splitting?)"
    return
  fi
  if ! grep -q "argc=1 " "$TMP/ARGS_FMT"; then
    fail "$name: path not passed as exactly one argument: $(cat "$TMP/ARGS_FMT")"
    return
  fi
  pass "$name: no command injection; path delivered as a single argument"
}

# ---------------------------------------------------------------------------
# Case 2: INJECTION via commands.lint_file
# ---------------------------------------------------------------------------
case_injection_lint() {
  local name="injection-lint_file"
  rm -f "$TMP/ARGS_LF" "$TMP/INJECTED_LF"
  # format = harmless ":"; lint_file = recorder so only lint_file records.
  ARGS_FILE="$TMP/ARGS_LF" write_cfg ":" "ARGS_FILE='$TMP/ARGS_LF' '$RECORDER'"
  local payload="y\";touch $TMP/INJECTED_LF;\".ts"
  ARGS_FILE="$TMP/ARGS_LF" run_hook "$payload"

  if [ -e "$TMP/INJECTED_LF" ]; then
    fail "$name: injection succeeded (sentinel INJECTED_LF was created)"
    return
  fi
  local n; n=$(line_count "$TMP/ARGS_LF")
  if [ "$n" != "1" ]; then
    fail "$name: lint_file recorder got $n invocations/lines, expected exactly 1 (arg-splitting?)"
    return
  fi
  if ! grep -q "argc=1 " "$TMP/ARGS_LF"; then
    fail "$name: path not passed as exactly one argument: $(cat "$TMP/ARGS_LF")"
    return
  fi
  pass "$name: no command injection; path delivered as a single argument"
}

# ---------------------------------------------------------------------------
# Case 3: POSITIVE — benign path runs the formatter with the exact path
# ---------------------------------------------------------------------------
case_positive() {
  local name="positive-benign"
  rm -f "$TMP/ARGS_POS"
  ARGS_FILE="$TMP/ARGS_POS" write_cfg "ARGS_FILE='$TMP/ARGS_POS' '$RECORDER'" ":"
  ARGS_FILE="$TMP/ARGS_POS" run_hook "src/foo.ts"

  local n; n=$(line_count "$TMP/ARGS_POS")
  if [ "$n" != "1" ]; then
    fail "$name: format recorder got $n invocations/lines, expected exactly 1"
    return
  fi
  if ! grep -Fqx "argc=1 [src/foo.ts]" "$TMP/ARGS_POS"; then
    fail "$name: expected 'argc=1 [src/foo.ts]', got: $(cat "$TMP/ARGS_POS")"
    return
  fi
  pass "$name: formatter ran once with exactly 'src/foo.ts'"
}

# ---------------------------------------------------------------------------
# Case 4: SKIP — non-matching extension does not run the recorder
# ---------------------------------------------------------------------------
case_skip() {
  local name="skip-nonmatching-ext"
  rm -f "$TMP/ARGS_SKIP"
  ARGS_FILE="$TMP/ARGS_SKIP" write_cfg "ARGS_FILE='$TMP/ARGS_SKIP' '$RECORDER'" ":"
  ARGS_FILE="$TMP/ARGS_SKIP" run_hook "notes.md"

  local n; n=$(line_count "$TMP/ARGS_SKIP")
  if [ "$n" != "0" ]; then
    fail "$name: recorder ran for a .md file ($n lines); hook should have exited early"
    return
  fi
  pass "$name: non-matching extension skipped, recorder did not run"
}

echo "== format-and-check.sh regression tests =="
echo "HOOK: $HOOK"
case_injection_format
case_injection_lint
case_positive
case_skip

echo
if [ "$FAILURES" -ne 0 ]; then
  echo "RESULT: $FAILURES case(s) FAILED"
  exit 1
fi
echo "RESULT: all cases PASSED"
exit 0
