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
# Preflight does NOT seed the tree baseline in the general case. Preflight can
# run AFTER edits, so snapshotting the current porcelain here would capture the
# agent's own work as "pre-existing" and later let it pass the gate (Invariant
# 2 violation). The tree baseline is normally pinned ONLY by
# dod-session-start.sh at SessionStart, which reliably runs before edits. A
# missing baseline → the classifier degrades to STRICT (everything blocks) —
# the safe direction — so preflight REPORTS it and tells the user to restart
# the session.
#
# ONE narrow exception (see Check 3 below): a brand-new TASK-mode key (a
# branch created mid-session, never seen by SessionStart) with a GENUINELY
# CLEAN working tree is safe to seed on the spot — there is nothing in the
# tree to launder as "pre-existing" when the tree is already empty of changes.
# Every other missing-baseline case still requires a restart.

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
  # gate blocks on files the agent never touched → /done can never pass.
  #
  # NARROW SAFE EXCEPTION — new TASK KEY, CLEAN tree: this fires whenever a
  # branch is created/switched to MID-SESSION (dod-session-start.sh only pins a
  # baseline for whatever branch was checked out at session start; a task key
  # is derived fresh from the CURRENT branch every hc_resolve call, so a new
  # branch is a brand-new, never-before-seen task key with no tree-base file of
  # its own). The general "preflight never seeds" rule exists because preflight
  # can run AFTER edits, and snapshotting live porcelain then would capture the
  # agent's own uncommitted work as "pre-existing" (whitelisting it). But when
  # the tree is GENUINELY CLEAN (`git status --porcelain` empty) right now,
  # there is nothing to launder — an empty baseline is correct and safe to pin
  # on the spot, exactly as if SessionStart had run on this branch. Only
  # applies in TASK mode (a real branch != trunk); SESSION mode still requires
  # a restart (its baseline is per-session, not per-branch, so there is no
  # equivalent "this key has simply never been seen" case).
  if [ "${HC_MODE:-}" = "task" ]; then
    LIVE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
    if [ -z "$LIVE_STATUS" ]; then
      TMP_DIRTY="${DIRTY_FILE}.tmp.$$"
      mkdir -p "$(dirname "$DIRTY_FILE")" 2>/dev/null
      if git -C "$PROJECT_DIR" status --porcelain > "$TMP_DIRTY" 2>/dev/null \
         && mv -f "$TMP_DIRTY" "$DIRTY_FILE" 2>/dev/null; then
        warn "no pinned tree baseline for task_key '${HC_TASK_KEY:-unknown}' (new branch created mid-session) — tree was clean, so it was safely seeded on the spot; no restart needed."
      else
        rm -f "$TMP_DIRTY" 2>/dev/null
        prob "no pinned tree baseline ($DIRTY_FILE) and the on-the-spot seed attempt failed — restart the session so SessionStart (dod-session-start.sh) records the tree baseline before you edit."
      fi
    else
      prob "no pinned tree baseline ($DIRTY_FILE) for task_key '${HC_TASK_KEY:-unknown}' (new branch created mid-session) — the tree currently has uncommitted changes, so it is NOT safe to auto-seed here (that would whitelist your own in-progress work as pre-existing). Remediation: commit or stash your current changes, then restart the session so SessionStart records the baseline before you resume editing."
    fi
  else
    prob "no pinned tree baseline ($DIRTY_FILE) — the SessionStart hook has not recorded it, so tree classification degrades to STRICT: the gate will treat ALL pre-existing files as yours and block forever (guaranteed deadlock). Remediation: restart the session so SessionStart (dod-session-start.sh) records the tree baseline before you edit; preflight will NOT seed it (it may run after edits, which would whitelist your own work)."
  fi
fi

# --- Check 3.5: session-mode HEAD diverged since baseline (P2-a, #6) --------
# In SESSION mode, if the baseline .sha is present and HEAD has moved PAST it,
# warn that the changeset the gate resolves may include work from other
# sessions sharing this git identity. NON-BLOCKING (HARD stays 0; the verdict
# stays winnable) — it is guidance, not a deadlock.
#
# NOTE: dod's trimmed harness-common.sh does not carry the per-commit
# session-authorship ledger (hc__session_authored_count /
# hc_session_changeset_commits) that completion-harness uses to distinguish
# "diverged, but all commits are mine" from "diverged onto foreign work" — so
# this check cannot narrow to the zero-authored-commits case and instead warns
# on ANY divergence, listing the commit authors for the operator to judge.
if [ "${HC_MODE:-}" = "session" ] && [ -f "$SHA_FILE" ]; then
  PF_BASE=$(cat "$SHA_FILE" 2>/dev/null)
  PF_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
  if [ -n "$PF_BASE" ] && [ -n "$PF_HEAD" ] && [ "$PF_BASE" != "$PF_HEAD" ]; then
    PF_AUTHORS=$(git -C "$PROJECT_DIR" log --format='%cn' "$PF_BASE..$PF_HEAD" 2>/dev/null \
      | sort | uniq -c | sort -rn | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+(.*)$/\2 \1/' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    warn "DIVERGED BASELINE: HEAD has moved past this session's baseline ($(printf '%s' "$PF_BASE" | cut -c1-7)..$(printf '%s' "$PF_HEAD" | cut -c1-7)) — commit authors in that range: ${PF_AUTHORS:-unknown}. If any are not you, the changeset the gate resolves may include foreign work; verify only your own slice by committing on a fresh branch or restarting the session so the baseline tracks your work."
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
