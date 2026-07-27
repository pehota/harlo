#!/bin/bash
#
# Completion Harness — SessionStart hook.
#
# Records the baseline HEAD SHA for this session and (optionally) captures a
# background pass/fail snapshot of the test suite, keyed by SHA so it is shared
# across sessions and only computed once per SHA.
#
# Never blocks session start and never exits non-zero: everything is guarded.
# No `set -e`; background work is detached with ( ... ) & so it cannot stall.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

HOOK_INPUT=$(cat 2>/dev/null)

SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
fi
# Fallback session id so we always have a stable filename.
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"

HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
BASELINE_DIR="$HARNESS_DIR/baselines"
mkdir -p "$BASELINE_DIR" "$HARNESS_DIR/done-state" 2>/dev/null

# --- reap stale harness state -----------------------------------------------
# Reap stale harness state (older than 14 days). Fresh files (this session's
# just-written baseline, active parallel sessions) are far younger, so safe.
# Runs BEFORE any early return so non-git sessions get cleaned up too.
if [ -d "$HARNESS_DIR" ]; then
  find "$HARNESS_DIR" -type f -mtime +14 -delete 2>/dev/null || true
fi

# --- record baseline SHA ----------------------------------------------------
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  printf 'no-git\n' > "$BASELINE_DIR/${SESSION_ID}.sha" 2>/dev/null
  exit 0
fi
printf '%s\n' "$HEAD_SHA" > "$BASELINE_DIR/${SESSION_ID}.sha" 2>/dev/null

# --- resolve identity (lazily pins the task base in task mode) --------------
# Source the shared resolver and resolve. In task mode this pins the fork base
# under .harness/task-base on first call. HC_WARN is non-empty only when we fell
# back to session mode BECAUSE of trunk (on trunk, or unconfident trunk) — in
# that case surface a non-blocking guidance message about task continuity.
if [ -f "$(dirname "$0")/harness-common.sh" ]; then
  . "$(dirname "$0")/harness-common.sh" 2>/dev/null
fi
if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi

if [ -n "$HC_WARN" ]; then
  # auto_branch default is TRUE when the key is absent, or the config/jq is
  # unavailable. NOTE: a plain `// true` jq default is WRONG here — jq's `//`
  # treats a literal `false` as empty and would flip it back to true — so we
  # must probe with has() and only then read the value.
  AUTO_BRANCH="true"
  CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
  if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
    if jq -e 'has("auto_branch")' "$CONFIG_FILE" >/dev/null 2>&1; then
      AUTO_BRANCH=$(jq -r '.auto_branch' "$CONFIG_FILE" 2>/dev/null)
    fi
  fi

  if [ "$AUTO_BRANCH" = "false" ]; then
    MSG="⚠ on trunk $HC_TRUNK; completion harness in session fallback — cross-session task continuity OFF. Use a feature branch."
  else
    MSG="on trunk $HC_TRUNK; a task branch will be auto-created on first edit (task continuity via branch)."
  fi
  # Surface as a non-blocking systemMessage on stdout (guarded); never fail.
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "$MSG" '{"systemMessage":$m}' 2>/dev/null
  else
    printf '{"systemMessage":"%s"}\n' "$MSG"
  fi
fi

# --- optional background test snapshot --------------------------------------
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
SNAPSHOT_ENABLED="false"
if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
  SNAPSHOT_ENABLED=$(jq -r '.baseline_snapshot // false' "$CONFIG_FILE" 2>/dev/null)
fi

TESTS_FILE="$BASELINE_DIR/${HEAD_SHA}.tests.json"

# Only run if enabled AND we have not already snapshotted this SHA (amortise).
if [ "$SNAPSHOT_ENABLED" = "true" ] && [ ! -f "$TESTS_FILE" ]; then
  # Resolve effective test command: override wins over detected.
  TEST_CMD=""
  if command -v jq >/dev/null 2>&1; then
    TEST_CMD=$(jq -r '(.overrides.test // .detected.test) // ""' "$CONFIG_FILE" 2>/dev/null)
  fi
  if [ -n "$TEST_CMD" ]; then
    (
      cd "$PROJECT_DIR" 2>/dev/null || exit 0
      OUTPUT=$(eval "$TEST_CMD" 2>&1)
      CODE=$?
      if command -v jq >/dev/null 2>&1; then
        jq -n \
          --arg sha "$HEAD_SHA" \
          --arg cmd "$TEST_CMD" \
          --argjson code "$CODE" \
          --arg out "$OUTPUT" \
          '{sha:$sha, command:$cmd, exit_code:$code, output:$out}' \
          > "$TESTS_FILE" 2>/dev/null
      else
        printf '{"sha":"%s","exit_code":%s}\n' "$HEAD_SHA" "$CODE" > "$TESTS_FILE" 2>/dev/null
      fi
    ) &
  fi
fi

exit 0
