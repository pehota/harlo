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
SOURCE=""
if command -v jq >/dev/null 2>&1; then
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
  # SessionStart source: startup | resume | clear | compact | fork (top-level).
  # Fires on /compact AND on AUTO-compaction — mid-task, with a DIRTY tree.
  SOURCE=$(printf '%s' "$HOOK_INPUT" | jq -r '.source // ""' 2>/dev/null)
fi
# Fallback session id so we always have a stable filename.
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"

# Source-aware baseline guard. On a compact (manual /compact or auto-compaction)
# the task is CONTINUING mid-flight with the agent's own uncommitted work in the
# tree; re-snapshotting the baseline from that dirty tree would capture the
# agent's work as "pre-existing" (whitelisting it) and lose the task's real
# baseline. So on source == "compact" we PRESERVE an existing baseline and only
# write it when ABSENT (first sight). For every other source
# (startup|resume|clear|fork) or an empty/unknown source (older CLI), we
# capture/refresh as before — a new-ish task context.
IS_COMPACT=0
[ "$SOURCE" = "compact" ] && IS_COMPACT=1

HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
BASELINE_DIR="$HARNESS_DIR/baselines"
mkdir -p "$BASELINE_DIR" "$HARNESS_DIR/done-state" 2>/dev/null

# --- reap stale harness state -----------------------------------------------
# Reap stale harness state (older than 14 days). Fresh files (this session's
# just-written baseline, active parallel sessions) are far younger, so safe.
# Runs BEFORE any early return so non-git sessions get cleaned up too.
# EXCLUDE task-base/ AND tree-base/ — a task's pinned base (merge-base SHA) and
# pinned tree baseline (fork-point porcelain) must live as long as its branch.
# Reaping task-base/ would re-pin at a later merge-base if trunk moved; reaping
# tree-base/ would let the next SessionStart re-seed the "pre-existing" set from
# live porcelain and thereby whitelist the agent's own uncommitted work (the
# very carryover bug this pinning fixes). Pins are tiny; orphaned ones harmless.
# ALSO EXCLUDE review-log/ — blob-keyed coverage walks a live task's WHOLE chain
# of logs (hc_review_coverage_gap), so an intermediate-commit log can be
# load-bearing long after 14 days. Its lifetime is governed SOLELY by the
# ancestry keep-set (hc_live_review_shas + the review-log hygiene prune below),
# never by age. Session-mode baselines/<sid>.dirty MAY still be reaped — session
# state is ephemeral (the changeset is the session).
if [ -d "$HARNESS_DIR" ]; then
  find "$HARNESS_DIR" -type f \
    -not -path '*/task-base/*' -not -path '*/tree-base/*' -not -path '*/review-log/*' \
    -mtime +14 -delete 2>/dev/null || true
fi

# --- record the AUTHORITATIVE current-session marker ------------------------
# SessionStart is the one hook that knows the REAL session_id (from its own hook
# stdin) and reliably runs before any edit. Write that id to a single well-known
# marker, overwritten every SessionStart. This is the authoritative session-id
# source for the /done skill and the writer/preflight: it removes their reliance
# on the `ls -t baselines/*.sha` heuristic, which can pick the WRONG id (a stale
# or a parallel session's baseline) and make /done write a done-state under a key
# the Stop gate never reads → a silent forever-block. Authoritative for the
# supported single-session/worktree model; parallel same-dir sessions are already
# unsupported (they race on the git tree). Written BEFORE the git-repo check so
# the marker is recorded even in a non-git dir (it is the session id, not a git
# fact). Guarded; never fails the hook.
printf '%s\n' "$SESSION_ID" > "$HARNESS_DIR/current-session" 2>/dev/null

# --- record baseline SHA ----------------------------------------------------
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  printf 'no-git\n' > "$BASELINE_DIR/${SESSION_ID}.sha" 2>/dev/null
  exit 0
fi
# Compact preserves an existing session baseline (mid-task continuation); it must
# not be re-snapshotted from the dirty mid-task HEAD. Write only if absent.
if [ "$IS_COMPACT" -eq 1 ] && [ -f "$BASELINE_DIR/${SESSION_ID}.sha" ]; then
  : # keep the existing session baseline
else
  printf '%s\n' "$HEAD_SHA" > "$BASELINE_DIR/${SESSION_ID}.sha" 2>/dev/null
fi

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

# --- terminal reap: clean a task's state once it is INTEGRATED --------------
# "Done is done": a task's changeset is truly finished when its branch is merged
# into trunk or the branch is gone. Only then is its task-keyed state dead.
#
# HARD SAFETY: an IN-PROGRESS task's state is load-bearing (the gate re-reads it
# every turn). We reap ONLY br-* task keys whose branch is merged/gone, computed
# via the testable hc_live_task_keys keep-set. We NEVER reap:
#   - a key any live (unmerged) local branch maps to (collision-safe: the key is
#     in the keep-set, so it is kept even if a lossy sanitization collides);
#   - SESSION-mode state (session-<id> done-states, baselines/*) — no branch to
#     test integration against; that stays on the 14-day age reap.
# If trunk is EMPTY/UNCONFIDENT we SKIP terminal reap entirely (never guess
# "merged"). Fully guarded; never fails the hook.
if command -v hc_live_task_keys >/dev/null 2>&1 || type hc_live_task_keys >/dev/null 2>&1; then
  REAP_TRUNK=""
  if command -v hc__detect_trunk >/dev/null 2>&1 || type hc__detect_trunk >/dev/null 2>&1; then
    REAP_TRUNK=$(hc__detect_trunk 2>/dev/null)
  fi
  if [ -n "$REAP_TRUNK" ] && [ -d "$HARNESS_DIR" ]; then
    # Keep-set: br-* keys of in-progress (unmerged, non-trunk) local branches.
    # Pass HC_BRANCH (already resolved by hc_resolve above) so the current-task
    # key can never be dropped by a HEAD that detaches after the pin (the reap
    # would otherwise re-derive the branch and, if detached, treat a
    # freshly-forked current branch as "merged" → reap its just-pinned state).
    LIVE_KEYS=$(hc_live_task_keys "$PROJECT_DIR" "$REAP_TRUNK" "$HC_BRANCH" 2>/dev/null)
    # is_live_key <key> → 0 iff <key> is in the keep-set (exact whole-line match).
    is_live_key() { printf '%s\n' "$LIVE_KEYS" | grep -Fxq -- "$1" 2>/dev/null; }
    # For every task-keyed state file whose key is a br-* key, reap it unless the
    # key is live. task-base/*.sha, tree-base/*.dirty, done-state/*.json.
    for d in task-base tree-base done-state; do
      [ -d "$HARNESS_DIR/$d" ] || continue
      for f in "$HARNESS_DIR/$d"/*; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        # Strip the single known extension to recover the <key>.
        key="${b%.sha}"; key="${key%.dirty}"; key="${key%.json}"
        case "$key" in
          br-*) ;;                 # a task key — subject to terminal reap
          *) continue ;;           # session-* or other — NOT terminal-reapable
        esac
        if ! is_live_key "$key"; then
          rm -f "$f" 2>/dev/null || true
        fi
      done
    done
  fi
fi

# --- review-log hygiene: prune superseded fix-churn logs --------------------
# review-log/<HEAD>.json accumulates one per fix commit. A log is load-bearing
# ONLY if its <HEAD> is a commit the gate might check — the tip of some local
# branch or the current HEAD. Prune the rest (superseded fix-churn).
# SAFETY: never delete the current HEAD's review-log (it IS in the keep-set).
if [ -d "$HARNESS_DIR/review-log" ] \
   && { command -v hc_live_review_shas >/dev/null 2>&1 || type hc_live_review_shas >/dev/null 2>&1; }; then
  LIVE_SHAS=$(hc_live_review_shas "$PROJECT_DIR" 2>/dev/null)
  # Only prune when we could compute a keep-set (git ok). Empty keep-set in a git
  # repo means no branches AND no HEAD — treat as "cannot judge" → keep all.
  if [ -n "$LIVE_SHAS" ]; then
    for f in "$HARNESS_DIR/review-log"/*.json; do
      [ -e "$f" ] || continue
      sha=$(basename "$f" .json)
      if ! printf '%s\n' "$LIVE_SHAS" | grep -Fxq -- "$sha" 2>/dev/null; then
        rm -f "$f" 2>/dev/null || true
      fi
    done
  fi
fi

# --- pin the tree baseline (for the classifier) -----------------------------
# Whole `git status --porcelain` lines — the "pre-existing" set hc_tree_status
# uses to distinguish pre-existing changes from ones the agent introduces. The
# PATH is resolver-pinned (HC_TREE_BASE_FILE): task-scoped in task mode,
# session-scoped otherwise.
#
# SessionStart is the one entry point that reliably runs BEFORE any edits, so
# pinning here (never in a post-edit path like preflight) is safe.
#
#   SESSION mode → rewrite every SessionStart (fresh per session; the changeset
#                  IS the session).
#   TASK mode    → write ONLY IF it does not already exist — pin ONCE at the
#                  first session on the branch and NEVER re-seed. Re-seeding
#                  from a later session's live porcelain is exactly the bug that
#                  whitelisted an earlier session's own uncommitted work.
#
# Always create the file (even when empty) so "missing" (→ strict) is
# distinguishable from "clean at baseline". Fully guarded; never fails the hook.
#
# UNCONDITIONAL fallback: if the resolver could not run (harness-common.sh
# failed to source → HC_TREE_BASE_FILE empty), we still MUST record a .dirty for
# SOME baseline, else hc_tree_status degrades to STRICT and treats every
# pre-existing file as introduced → the gate blocks everything → deadlock. Fall
# back to the session-scoped path the resolver would have used in session mode
# (baselines/<sid>.dirty), so a .dirty is ALWAYS captured on any git-repo
# SessionStart. (Non-git dirs return above at the no-git early exit: they have no
# tree baseline and the Stop gate fails open on a non-git repo, so no deadlock.)
if [ -z "$HC_TREE_BASE_FILE" ]; then
  HC_TREE_BASE_FILE="$BASELINE_DIR/${SESSION_ID}.dirty"
fi
if [ -n "$HC_TREE_BASE_FILE" ]; then
  # Task mode is ALREADY pin-once (never re-seeded), so it is inherently safe on
  # compact. The source guard's job is to protect SESSION-mode
  # baselines/<sid>.dirty, which is normally rewritten every SessionStart: on a
  # compact the tree is dirty with the agent's OWN work, so an existing session
  # tree-base must be preserved (write only if ABSENT), exactly like the .sha.
  if [ "$HC_MODE" = "task" ]; then
    if [ ! -f "$HC_TREE_BASE_FILE" ]; then
      mkdir -p "$(dirname "$HC_TREE_BASE_FILE")" 2>/dev/null
      git -C "$PROJECT_DIR" status --porcelain > "$HC_TREE_BASE_FILE" 2>/dev/null \
        || : > "$HC_TREE_BASE_FILE" 2>/dev/null
    fi
  elif [ "$IS_COMPACT" -eq 1 ] && [ -f "$HC_TREE_BASE_FILE" ]; then
    : # compact: preserve the existing session tree baseline (do not re-seed)
  else
    mkdir -p "$(dirname "$HC_TREE_BASE_FILE")" 2>/dev/null
    git -C "$PROJECT_DIR" status --porcelain > "$HC_TREE_BASE_FILE" 2>/dev/null \
      || : > "$HC_TREE_BASE_FILE" 2>/dev/null
  fi
fi

# --- classify the FSM state for proactive steering (P2) ---------------------
# Compose the classifier (hc_state) to learn the current operator-facing state
# and its canonical next-action. Run AFTER the tree baseline is pinned above, so
# hc_tree_status classifies against the just-written .dirty (a first-session tree
# would otherwise degrade to strict and misclassify a clean S0 as S1). Same guard
# idiom as hc_resolve; pre-init so a source failure leaves them empty (→ no
# additionalContext, silent). Read-only w.r.t. baselines — it reclassifies, it
# does not re-pin.
HC_STATE=""
HC_NEXT=""
if command -v hc_state >/dev/null 2>&1 || type hc_state >/dev/null 2>&1; then
  hc_state "$SESSION_ID" 2>/dev/null
fi

# ADDL_CTX carries the agent-visible proactive steering, injected via
# hookSpecificOutput.additionalContext ONLY in ACTIONABLE states (S1/S2/S4). The
# first line is the D4 review-ownership directive; the second injects the FSM
# next-action. Silent (empty) in S0/S5.
ADDL_CTX=""
case "$HC_STATE" in
  S1|S2|S4)
    ADDL_CTX="[completion-harness] /done owns the Step-5 independent code review — it is the Definition-of-Done. Do NOT run your own separate pre-commit review.
Next action: ${HC_NEXT}"
    ;;
esac

# SYS_MSG accumulates non-blocking guidance; emitted ONCE at the end as a single
# JSON object (two objects on stdout = invalid JSON). It may coexist with
# hookSpecificOutput.additionalContext in that one object.
SYS_MSG=""
append_msg() { SYS_MSG="${SYS_MSG:+$SYS_MSG
}$1"; }

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
    append_msg "⚠ on trunk $HC_TRUNK; completion harness in session fallback — cross-session task continuity OFF. Use a feature branch."
  else
    append_msg "on trunk $HC_TRUNK; a task branch will be auto-created on first edit (task continuity via branch)."
  fi
fi

# --- optional background test snapshot --------------------------------------
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
SNAPSHOT_ENABLED="false"
if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
  SNAPSHOT_ENABLED=$(jq -r '.baseline_snapshot // false' "$CONFIG_FILE" 2>/dev/null)
fi

TESTS_FILE="$BASELINE_DIR/${HEAD_SHA}.tests.json"

if [ "$SNAPSHOT_ENABLED" = "true" ] && [ ! -f "$TESTS_FILE" ]; then
  # Resolve effective test command: override wins over detected.
  TEST_CMD=""
  if command -v jq >/dev/null 2>&1; then
    TEST_CMD=$(jq -r '(.overrides.test // .detected.test) // ""' "$CONFIG_FILE" 2>/dev/null)
  fi

  # Chicken-and-egg fix: a fresh project has detected:{} so no test command is
  # known yet. Run the (idempotent) detector to seed/refresh done-config.json,
  # then re-read the effective test command. Guarded; never fails the hook.
  if [ -z "$TEST_CMD" ]; then
    if [ -x "$(dirname "$0")/done-detect.sh" ] || [ -f "$(dirname "$0")/done-detect.sh" ]; then
      bash "$(dirname "$0")/done-detect.sh" >/dev/null 2>&1
    fi
    if command -v jq >/dev/null 2>&1 && [ -f "$CONFIG_FILE" ]; then
      TEST_CMD=$(jq -r '(.overrides.test // .detected.test) // ""' "$CONFIG_FILE" 2>/dev/null)
    fi
  fi

  if [ -n "$TEST_CMD" ] && command -v jq >/dev/null 2>&1; then
    # Real snapshot: run tests in the background. Atomic write via temp + mv so a
    # concurrent /done never reads a half-written file. Keyed by SHA (amortised).
    (
      cd "$PROJECT_DIR" 2>/dev/null || exit 0
      OUTPUT=$(eval "$TEST_CMD" 2>&1)
      CODE=$?
      TMP_SNAP="${TESTS_FILE}.tmp.$$"
      jq -n \
        --arg sha "$HEAD_SHA" \
        --arg cmd "$TEST_CMD" \
        --argjson code "$CODE" \
        --arg out "$OUTPUT" \
        '{sha:$sha, command:$cmd, exit_code:$code, output:$out}' \
        > "$TMP_SNAP" 2>/dev/null \
        && mv -f "$TMP_SNAP" "$TESTS_FILE" 2>/dev/null
      [ -f "$TMP_SNAP" ] && rm -f "$TMP_SNAP" 2>/dev/null
    ) &
  else
    # FAIL LOUD (never silently inert): snapshot is enabled but no test command
    # is available even after detection (or jq is missing). Write an explicit
    # inert marker (atomic) and surface it so the /done before/after red-test
    # discrimination is known to be unavailable, not silently skipped.
    if command -v jq >/dev/null 2>&1; then
      TMP_SNAP="${TESTS_FILE}.tmp.$$"
      jq -n --arg sha "$HEAD_SHA" \
        '{sha:$sha, status:"inert", reason:"no test command detected"}' \
        > "$TMP_SNAP" 2>/dev/null \
        && mv -f "$TMP_SNAP" "$TESTS_FILE" 2>/dev/null
      [ -f "$TMP_SNAP" ] && rm -f "$TMP_SNAP" 2>/dev/null
    else
      printf '{"sha":"%s","status":"inert","reason":"jq unavailable"}\n' "$HEAD_SHA" > "$TESTS_FILE" 2>/dev/null
    fi
    append_msg "⚠ baseline test snapshot could not run (no test command detected) — newly-red vs pre-existing-red discrimination is UNAVAILABLE for this session. Set a test command (overrides.test) or add a test script."
  fi
fi

# --- emit ONE JSON object carrying the user-facing systemMessage AND/OR the ---
# --- agent-visible additionalContext (guarded) ------------------------------
# The SessionStart contract: a top-level `additionalContext` is silently ignored
# by the runtime — the agent-visible channel is hookSpecificOutput.additionalContext
# (nested, with hookEventName:"SessionStart"). ONE object MAY carry BOTH a
# top-level `systemMessage` (shown in the user's terminal, NOT agent-visible) and
# hookSpecificOutput.additionalContext (injected into agent context) — both are
# honoured. Never emit two JSON objects (invalid).
#
# jq builds the object safely, dropping any absent key: systemMessage only when
# SYS_MSG is non-empty (preserving prior behaviour), hookSpecificOutput only when
# ADDL_CTX is non-empty (actionable state). The whole emission is guarded so a
# fully-silent session (S0/S5, no warnings) prints nothing.
#
# jq-absent fallback: without jq the nested object cannot be built, so we degrade
# to the systemMessage-only form (additionalContext dropped) — matching the
# existing degrade path; emit only when SYS_MSG is set.
if [ -n "$SYS_MSG" ] || [ -n "$ADDL_CTX" ]; then
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg m "$SYS_MSG" --arg ctx "$ADDL_CTX" '
      {
        systemMessage: (if $m != "" then $m else null end),
        hookSpecificOutput: (if $ctx != ""
          then {hookEventName:"SessionStart", additionalContext:$ctx}
          else null end)
      } | with_entries(select(.value != null))
    ' 2>/dev/null
  elif [ -n "$SYS_MSG" ]; then
    printf '{"systemMessage":"%s"}\n' "$SYS_MSG"
  fi
fi

exit 0
