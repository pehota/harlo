#!/bin/bash
#
# Completion Harness — /done preflight (run at TASK START, before edits).
#
# PROVES the gate is winnable BEFORE the agent does work / spawns subagents.
# It CALLS the shared logic (hc_resolve + hc_tree_status) — it does NOT
# reimplement the gate. Human-readable report to stdout.
#
# Exit: non-zero (1) on any HARD problem (gate not winnable as-is); 0 when
# winnable (warnings allowed). Every problem is printed with exact remediation.
#
# Preflight NEVER seeds the tree baseline. Preflight can run AFTER edits, so
# snapshotting the current porcelain here would capture the agent's own work as
# "pre-existing" and later let it pass the gate (Invariant 2 violation). The
# tree baseline is pinned ONLY by baseline-snapshot.sh at SessionStart, which
# reliably runs before edits. A missing baseline → the classifier degrades to
# STRICT (everything blocks) — the safe direction — so preflight only REPORTS
# it and tells the user to restart the session; it does not paper over it.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
BASELINE_DIR="$HARNESS_DIR/baselines"

HARD=0   # set to 1 on any hard problem → exit 1.

say()  { printf '%s\n' "$1"; }
prob() { printf 'PROBLEM: %s\n' "$1"; HARD=1; }
warn() { printf 'warning: %s\n' "$1"; }

say "== completion-harness preflight =="

# --- Check 1: not a git repo → nothing to win -------------------------------
if ! git -C "$PROJECT_DIR" rev-parse HEAD >/dev/null 2>&1; then
  say "harness inactive (not a git repo) — gate will allow-all"
  exit 0
fi

# --- Check 2: jq missing → gate fails open ----------------------------------
if ! command -v jq >/dev/null 2>&1; then
  warn "jq not found — the gate fails open (allows) and config-driven checks degrade. Install jq for full enforcement."
  exit 0
fi

# --- source the shared library + resolve identity ---------------------------
if [ -f "$(dirname "$0")/harness-common.sh" ]; then
  . "$(dirname "$0")/harness-common.sh" 2>/dev/null
fi

# Resolve session id the same way done-write-state.sh does: arg, else newest
# baselines/*.sha.
SESSION_ID="${1:-}"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -t "$BASELINE_DIR"/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//')
fi
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"
say "session: $SESSION_ID"

if command -v hc_resolve >/dev/null 2>&1 || type hc_resolve >/dev/null 2>&1; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
say "mode: ${HC_MODE:-unknown}  task_key: ${HC_TASK_KEY:-unknown}"

# --- Check 3: baseline files present for this session/task ------------------
# The tree baseline path is resolver-pinned (HC_TREE_BASE_FILE): task-scoped in
# task mode (pinned once at the fork), session-scoped otherwise.
SHA_FILE="$BASELINE_DIR/${SESSION_ID}.sha"
DIRTY_FILE="${HC_TREE_BASE_FILE:-$BASELINE_DIR/${SESSION_ID}.dirty}"

if [ ! -f "$SHA_FILE" ]; then
  warn "no baseline .sha for session '$SESSION_ID' — the SessionStart hook has not recorded a baseline. Restart the session so baseline-snapshot.sh runs."
fi

if [ ! -f "$DIRTY_FILE" ]; then
  # Missing tree baseline → the classifier degrades to STRICT (every current
  # change blocks — the safe direction). Preflight does NOT seed it: preflight
  # can run AFTER edits, so snapshotting live porcelain here would capture the
  # agent's own work as "pre-existing" and later let it pass the gate. Only
  # SessionStart (baseline-snapshot.sh) — which runs before edits — may pin it.
  warn "no pinned tree baseline ($DIRTY_FILE) — the SessionStart hook has not pinned it, so tree classification degrades to STRICT: every current untracked/modified file will BLOCK. Restart the session so baseline-snapshot.sh pins the baseline before you edit; preflight will NOT seed it (it may run after edits, which would whitelist your own work)."
fi

# --- Check 4: baseline_snapshot enabled but no effective test command -------
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
SNAPSHOT_ENABLED="false"
TEST_CMD=""
if [ -f "$CONFIG_FILE" ]; then
  SNAPSHOT_ENABLED=$(jq -r '.baseline_snapshot // false' "$CONFIG_FILE" 2>/dev/null)
  TEST_CMD=$(jq -r '(.overrides.test // .detected.test) // ""' "$CONFIG_FILE" 2>/dev/null)
fi
if [ "$SNAPSHOT_ENABLED" = "true" ] && [ -z "$TEST_CMD" ]; then
  prob "baseline_snapshot enabled but no test command detected — the before/after red-test discrimination will be INERT. Remediation: ensure the project has a test script or set overrides.test in .claude/done-config.json."
fi

# --- Check 5: tree state via the shared classifier --------------------------
if command -v hc_tree_status >/dev/null 2>&1 || type hc_tree_status >/dev/null 2>&1; then
  hc_tree_status "$SESSION_ID" 2>/dev/null
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    prob "working tree has changes that will BLOCK the gate (deadlock risk): $(hc_tree_remediation)"
  fi
  # Pre-existing (warned-only) tree entries are intentionally NOT surfaced —
  # they are irrelevant to the task and only add noise.
fi

# --- verdict ----------------------------------------------------------------
if [ "$HARD" -ne 0 ]; then
  say "verdict: NOT WINNABLE — fix the PROBLEM(s) above before proceeding."
  exit 1
fi
say "verdict: winnable (warnings, if any, are non-blocking)."
exit 0
