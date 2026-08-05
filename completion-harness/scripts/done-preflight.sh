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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Literal, not hc__harness_dir: kept simple/direct rather than coupling this
# early path derivation to whether sourcing below succeeded.
HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
BASELINE_DIR="$HARNESS_DIR/baselines"

# --- source the shared library early (before Check 2 needs hc_has_jq) -------
# Sourcing has no dependency on anything checked below.
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

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
if ! hc_has_jq; then
  warn "jq not found — the gate fails open (allows) and config-driven checks degrade. Install jq for full enforcement."
  exit 0
fi

# Resolve session id with the SAME precedence the skill/writer use so preflight
# can't drift onto a different key than the rest of the pipeline (which would
# false-positive the missing-.dirty block): arg → authoritative current-session
# marker → newest baselines/*.sha heuristic. The env var is deliberately NOT
# used — it leaks into child/subagent shells (carrying a child session id) and
# into test subprocesses, so the per-project marker is the trustworthy source.
SESSION_ID="${1:-}"
if [ -z "$SESSION_ID" ] && [ -f "$HARNESS_DIR/current-session" ]; then
  SESSION_ID=$(cat "$HARNESS_DIR/current-session" 2>/dev/null)
fi
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(ls -t "$BASELINE_DIR"/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//')
fi
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"
say "session: $SESSION_ID"

if hc_has_fn hc_resolve; then
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
  # change blocks). This is a GUARANTEED deadlock, not a mere degrade: without a
  # baseline, hc_tree_status treats every PRE-EXISTING file as introduced → the
  # gate blocks on files the agent never touched → /done can never pass. So this
  # is a HARD problem, not a warning. Preflight does NOT seed it: preflight can
  # run AFTER edits, so snapshotting live porcelain here would capture the
  # agent's own work as "pre-existing" and later let it pass the gate. Only
  # SessionStart (baseline-snapshot.sh) — which runs before edits — may pin it.
  prob "no pinned tree baseline ($DIRTY_FILE) — the SessionStart hook has not recorded it, so tree classification degrades to STRICT: the gate will treat ALL pre-existing files as yours and block forever (guaranteed deadlock). Remediation: restart the session so SessionStart (baseline-snapshot.sh) records the tree baseline before you edit; preflight will NOT seed it (it may run after edits, which would whitelist your own work)."
fi

# --- Check 3.5: session-mode HEAD diverged with NO session commits (P2-a, #6) -
# In SESSION mode, if the baseline .sha is present, HEAD has moved PAST it, yet
# NONE of the commits in BASELINE_SHA..HEAD are session-authored (Chunk-A
# predicate), then the session is sitting atop foreign work it did not author —
# a diverged baseline. Warn LOUDLY with the author list so the operator knows the
# changeset the gate resolves is NOT this session's work. NON-BLOCKING (HARD
# stays 0; the verdict stays winnable) — it is guidance, not a deadlock.
if [ "${HC_MODE:-}" = "session" ] && [ -f "$SHA_FILE" ]; then
  PF_BASE=$(cat "$SHA_FILE" 2>/dev/null)
  PF_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
  if [ -n "$PF_BASE" ] && [ -n "$PF_HEAD" ] && [ "$PF_BASE" != "$PF_HEAD" ]; then
    PF_AUTHORED="0"
    if hc_has_fn hc__session_authored_count; then
      PF_AUTHORED=$(hc__session_authored_count "$PF_BASE" "$PF_HEAD" "$SESSION_ID" 2>/dev/null)
    fi
    if [ "$PF_AUTHORED" = "0" ]; then
      PF_AUTHORS=$(git -C "$PROJECT_DIR" log --format='%cn' "$PF_BASE..$PF_HEAD" 2>/dev/null \
        | sort | uniq -c | sort -rn | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+(.*)$/\2 \1/' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
      warn "DIVERGED BASELINE: HEAD has moved past this session's baseline ($(printf '%s' "$PF_BASE" | cut -c1-7)..$(printf '%s' "$PF_HEAD" | cut -c1-7)) but 0 of those commits were authored this session — the changeset the gate resolves is NOT your work (authors: ${PF_AUTHORS:-unknown}). If you intend to verify only your own slice, commit it on a fresh branch or restart the session so the baseline tracks your work."
    fi
  fi
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
if hc_has_fn hc_tree_status; then
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
