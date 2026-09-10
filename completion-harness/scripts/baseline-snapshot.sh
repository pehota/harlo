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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source the shared helpers early (before reading stdin) so hc_read_hook_input
# is available. Sourcing has no dependency on anything parsed below — the rest
# of this script's "not sourced until below" bootstrapping (HARNESS_DIR etc.)
# is unaffected, it just no longer waits on this specific source line.
# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

SESSION_ID=""
SOURCE=""
if hc_has_fn hc_read_hook_input; then
  hc_read_hook_input
  SESSION_ID="$HC_HOOK_SESSION_ID"
  # SessionStart source: startup | resume | clear | compact | fork (top-level).
  # Fires on /compact AND on AUTO-compaction — mid-task, with a DIRTY tree.
  SOURCE="$HC_HOOK_SOURCE"
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

# Literal, not hc__harness_dir: harness-common.sh IS sourced above now (for
# hc_read_hook_input), but hc_resolve below is what actually needs it wired
# up; keeping this literal avoids coupling the mkdir bootstrap to whether
# sourcing succeeded.
HARNESS_DIR="$PROJECT_DIR/.claude/.harness"
BASELINE_DIR="$HARNESS_DIR/baselines"
mkdir -p "$BASELINE_DIR" "$HARNESS_DIR/done-state" "$HARNESS_DIR/pending-escalation" 2>/dev/null

# --- drop the previous task's SESSION CONFIG --------------------------------
# session-config.json is the per-task override layer (hc_cfg): the only channel
# through which an instruction the user gives in chat reaches a hook, which runs
# as a static command with no argv the conversation can reach. Its lifetime is
# ONE task, so a "stay on trunk, this once" never silently governs the next
# task. Dropped on a FRESH context (startup|clear) and kept on resume|compact|
# fork, which continue the same task — the same distinction IS_COMPACT draws for
# the baseline. An EMPTY source (older CLI that sends no `source`) also drops:
# this file only ever grants leniency, so an unknown source must fail toward the
# persisted config, not toward an override surviving indefinitely. Guarded; a
# missing file is a no-op.
case "$SOURCE" in
  resume|compact|fork) : ;;
  *)
    rm -f "$PROJECT_DIR/.claude/.harness/session-config.json" 2>/dev/null
    # last-block/ is the Stop gate's reason-scoped loop-guard memory (the
    # category of the previous turn's block). It is meaningful only WITHIN a
    # task's block/comply cycle; a fresh context starts a new task with no
    # prior block, so a stale category here must not brake the first genuine
    # block of the new task. Dropped on the same startup|clear boundary as the
    # session config, kept on resume|compact|fork (same task continues).
    rm -rf "$PROJECT_DIR/.claude/.harness/last-block" 2>/dev/null
    ;;
esac

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
# last-block/ is NOT excluded: it is transient loop-guard memory, already
# dropped on a fresh context above, and a 14-day-old marker is certainly stale.
#
# baselines/ IS excluded from this per-file sweep and reaped PER SESSION ID
# instead — see the grouped reap below. A per-file age test there deleted the
# SAFETY MARKERS while sparing the state they qualify, because the mtimes of a
# session's files are ASYMMETRIC:
#   <sid>.watermark    rewritten on every completed sweep → always fresh
#   <sid>.own-commits  appended on every claimed commit   → fresh
#   <sid>.bg-seen      created once, never touched again  → FROZEN
#   <sid>.sweep-failed created once, never touched again  → FROZEN
# So a long-lived session's two markers age past the threshold while its ledger
# and cursor stay young. Losing .bg-seen makes `pre` revert to pinning HEAD, and
# the next backgrounded commit is missed; losing .sweep-failed re-enables the
# base advance over a ledger the hook itself recorded as INCOMPLETE. Both are
# SILENT SKIPS — the one direction this harness must never fail in.
if [ -d "$HARNESS_DIR" ]; then
  find "$HARNESS_DIR" -type f \
    -not -path '*/task-base/*' -not -path '*/tree-base/*' -not -path '*/review-log/*' \
    -not -path '*/escalation-accept/*' -not -path '*/baselines/*' \
    -mtime +14 -delete 2>/dev/null || true
fi

# --- grouped reap: baselines/ is aged PER SESSION ID, all-or-nothing --------
# A session's files under baselines/ are ONE unit of state: <sid>.sha, .dirty,
# .cursor, .cursor.<tool_use_id>, .own-commits, .watermark, .bg-seen,
# .sweep-failed, .started. The group is
# reaped only when its NEWEST member is older than the threshold — i.e. when
# nothing about that session has been touched in 14 days — and then entirely.
# Any single fresh member keeps all of them.
#
# This removes the whole class rather than exempting two filenames: any future
# per-session file inherits the rule for free, including a write-once marker.
# The group key is the basename up to the FIRST dot (session ids are uuids and
# contain no dot); files are deleted by ENUMERATION, never by re-globbing the
# key, so an unexpected key shape can never widen the deletion.
if [ -d "$HARNESS_DIR/baselines" ]; then
  # TWO find calls, whatever the file count: the FRESH members (the keep-set's
  # source) and the STALE ones (the only deletion candidates). Asking find for
  # freshness directly is what keeps this off a per-file stat.
  BL_FRESH=$(find "$HARNESS_DIR/baselines" -maxdepth 1 -type f \! -mtime +14 2>/dev/null)
  BL_STALE=$(find "$HARNESS_DIR/baselines" -maxdepth 1 -type f -mtime +14 2>/dev/null)
  if [ -n "$BL_STALE" ]; then
    # Keep-set: the session key of every fresh member. One fresh member is
    # enough — the whole group is then load-bearing.
    BL_KEEP=""
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b=${f##*/}
      BL_KEEP="${BL_KEEP:+$BL_KEEP
}${b%%.*}"
    done <<EOF
$BL_FRESH
EOF
    # Delete every stale member whose key is NOT in the keep-set. Membership is
    # by exact whole-line match; deletion is by the enumerated path, never by
    # re-globbing the key, so an unexpected key shape cannot widen the rm.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      b=${f##*/}
      printf '%s\n' "$BL_KEEP" | grep -qxF -- "${b%%.*}" 2>/dev/null && continue
      rm -f "$f" 2>/dev/null || true
    done <<EOF
$BL_STALE
EOF
  fi
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

# --- record the session START TIME (epoch seconds, in the CONTENT) ----------
# The floor for the commit ledger's committer-date filter: commit-ledger.sh
# appends a swept sha only when its COMMITTER date is >= this epoch. That is
# what stops a `git pull --ff-only` inside a tool-call window from being read as
# authorship — a fast-forward moves HEAD over commits authored ELSEWHERE,
# EARLIER, and "HEAD moved inside the window" cannot tell receiving a commit
# from creating one.
#
# THE EPOCH IS THE FILE'S CONTENT, NEVER ITS MTIME. Baseline mtime is already
# identified in this codebase as a mutable false-PASS risk (any later write, or
# a `touch`, moves it), so it is not a signal anything may depend on.
#
# WRITTEN ONLY WHEN ABSENT — not refreshed on startup|resume|clear|fork the way
# the .sha is. A resumed session keeps its id, and re-stamping the epoch forward
# would filter out a commit the session really authored before the resume but
# has not swept yet (the backgrounded-job shape: the commit lands between
# windows and the NEXT sweep claims it). An epoch that is too EARLY only ever
# filters LESS, which is the over-block direction.
[ -f "$BASELINE_DIR/${SESSION_ID}.started" ] || \
  date +%s > "$BASELINE_DIR/${SESSION_ID}.started" 2>/dev/null

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
# Resolve via the shared resolver (already sourced above). In task mode this
# pins the fork base under .harness/task-base on first call. HC_WARN is
# non-empty only when we fell back to session mode BECAUSE of trunk (on
# trunk, or unconfident trunk) — in that case surface a non-blocking guidance
# message about task continuity.
if hc_has_fn hc_resolve; then
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
if hc_has_fn hc_live_task_keys; then
  REAP_TRUNK=""
  if hc_has_fn hc__detect_trunk; then
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

# --- helper: delete *.json files in a dir whose basename-minus-.json is not
# in the live-sha keep-set --------------------------------------------------
prune_by_live_shas() {
  local dir="$1" live_shas="$2" f sha
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    sha=$(basename "$f" .json)
    if ! printf '%s\n' "$live_shas" | grep -Fxq -- "$sha" 2>/dev/null; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
  return 0
}

# --- review-log hygiene: prune superseded fix-churn logs --------------------
# review-log/<HEAD>.json accumulates one per fix commit. A log is load-bearing
# ONLY if its <HEAD> is a commit the gate might check — the tip of some local
# branch or the current HEAD. Prune the rest (superseded fix-churn).
# SAFETY: never delete the current HEAD's review-log (it IS in the keep-set).
if { [ -d "$HARNESS_DIR/review-log" ] || [ -d "$HARNESS_DIR/escalation-accept" ]; } \
   && { hc_has_fn hc_live_review_shas; }; then
  LIVE_SHAS=$(hc_live_review_shas "$PROJECT_DIR" 2>/dev/null)
  # Only prune when we could compute a keep-set (git ok). Empty keep-set in a git
  # repo means no branches AND no HEAD — treat as "cannot judge" → keep all.
  if [ -n "$LIVE_SHAS" ]; then
    prune_by_live_shas "$HARNESS_DIR/review-log" "$LIVE_SHAS"
    # escalation-accept/<sha>.json (P2-b, #6) is governed by the SAME keep-set:
    # exempt from the 14-day age-reap (above), pruned ONLY when its SHA is no
    # longer reachable (unreachable commit → acceptance is dead). Mirrors the
    # review-log prune so a live task's per-commit acceptance survives as long as
    # its commit does, and no longer.
    if [ -d "$HARNESS_DIR/escalation-accept" ]; then
      prune_by_live_shas "$HARNESS_DIR/escalation-accept" "$LIVE_SHAS"
    fi
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
# That distinction only holds if a 0-byte file can ONLY mean "clean" — see
# pin_tree_baseline below, which makes the capture atomic so a FAILED capture
# leaves no file at all instead of an empty one.
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

# pin_tree_baseline <file> — capture `git status --porcelain` ATOMICALLY.
#
# `git status --porcelain > "$file"` truncates the target BEFORE git runs, so a
# git failure, a killed hook or a full disk leaves a 0-BYTE file — byte-identical
# to the legitimate "clean tree at baseline" snapshot documented above. The
# classifier then reads an empty-but-HEALTHY baseline set, so
# HC_TREE_BASELINE_MISSING stays 0 and the block reason asserts the live changes
# are ones "you introduced" — exactly the unattributable claim a3b600e removed,
# reintroduced through the back door.
#
# So: write to a SIBLING temp (same directory → same filesystem → the mv is a
# rename, never an interruptible cross-device copy) and move it into place ONLY
# on a clean git exit. On any failure leave NO file — including removing a stale
# one from an earlier session, which would otherwise whitelist that session's
# work. Missing is the honest state: hc_tree_status reports BASELINE_MISSING, the
# verdict stays strict, and the wording hedges and names the real repair. "0
# bytes = genuinely clean" is now true BY CONSTRUCTION, not by assumption.
pin_tree_baseline() {
  local file="$1" tmp="$1.tmp.$$"
  mkdir -p "$(dirname "$file")" 2>/dev/null
  if git -C "$PROJECT_DIR" status --porcelain > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp" "$file" 2>/dev/null; }
  else
    rm -f "$tmp" "$file" 2>/dev/null
  fi
}
if [ -n "$HC_TREE_BASE_FILE" ]; then
  # Task mode is ALREADY pin-once (never re-seeded), so it is inherently safe on
  # compact. The source guard's job is to protect SESSION-mode
  # baselines/<sid>.dirty, which is normally rewritten every SessionStart: on a
  # compact the tree is dirty with the agent's OWN work, so an existing session
  # tree-base must be preserved (write only if ABSENT), exactly like the .sha.
  if [ "$HC_MODE" = "task" ]; then
    if [ ! -f "$HC_TREE_BASE_FILE" ]; then
      pin_tree_baseline "$HC_TREE_BASE_FILE"
    fi
  elif [ "$IS_COMPACT" -eq 1 ] && [ -f "$HC_TREE_BASE_FILE" ]; then
    : # compact: preserve the existing session tree baseline (do not re-seed)
  else
    pin_tree_baseline "$HC_TREE_BASE_FILE"
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
if hc_has_fn hc_state; then
  hc_state "$SESSION_ID" 2>/dev/null
fi

# ADDL_CTX carries the agent-visible proactive steering, injected via
# hookSpecificOutput.additionalContext in the ACTIONABLE states (S1/S2/S4). The
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
  append_msg "⚠ on trunk $HC_TRUNK; completion harness in session fallback — cross-session task continuity OFF. Use a feature branch."
fi

# --- optional background test snapshot --------------------------------------
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
SNAPSHOT_ENABLED="false"
if hc_has_jq && [ -f "$CONFIG_FILE" ]; then
  SNAPSHOT_ENABLED=$(jq -r '.baseline_snapshot // false' "$CONFIG_FILE" 2>/dev/null)
fi

TESTS_FILE="$BASELINE_DIR/${HEAD_SHA}.tests.json"

if [ "$SNAPSHOT_ENABLED" = "true" ] && [ ! -f "$TESTS_FILE" ]; then
  # Resolve effective test command: override wins over detected.
  TEST_CMD=""
  if hc_has_jq; then
    TEST_CMD=$(jq -r '(.overrides.test // .detected.test) // ""' "$CONFIG_FILE" 2>/dev/null)
  fi

  # Chicken-and-egg fix: a fresh project has detected:{} so no test command is
  # known yet. Run the (idempotent) detector to seed/refresh done-config.json,
  # then re-read the effective test command. Guarded; never fails the hook.
  if [ -z "$TEST_CMD" ]; then
    if [ -f "$SCRIPT_DIR/done-detect.sh" ]; then
      bash "$SCRIPT_DIR/done-detect.sh" >/dev/null 2>&1
    fi
    if hc_has_jq && [ -f "$CONFIG_FILE" ]; then
      TEST_CMD=$(jq -r '(.overrides.test // .detected.test) // ""' "$CONFIG_FILE" 2>/dev/null)
    fi
  fi

  if [ -n "$TEST_CMD" ] && hc_has_jq; then
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
    if hc_has_jq; then
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
  if hc_has_jq; then
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
