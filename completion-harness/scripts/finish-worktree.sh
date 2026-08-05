#!/bin/bash
#
# Completion Harness — verified worktree teardown.
#
#   finish-worktree.sh [--skip-verify]
#
# Run from INSIDE the task worktree. Integrates the branch into trunk only after
# proving, in order, that:
#
#   1. the worktree is clean;
#   2. a done-state exists for this task key, is GREEN, and still describes the
#      worktree's HEAD;
#   3. the branch rebases cleanly onto origin/<trunk>;
#   4. trunk FAST-FORWARDS to the branch — --ff-only, never a merge commit.
#
# Only then is the worktree removed and the branch deleted. Each gate refuses
# loudly and changes nothing beyond its own step, so a refusal always leaves a
# worktree you can go on working in.
#
# NEVER PUSHES. It prints what would be pushed and stops. Publishing is a
# decision, not a side effect of tidying up.
#
# WHY GATES 1 AND 2 REUSE LIBRARY PREDICATES. hc_tree_status classifies the tree
# and hc_verification_state / hc_done_state_blocked answer "is this done-state
# fresh and green?" — the same functions done-gate.sh uses. Asking those
# questions a second way here would let this script integrate work the gate
# still blocks on. Writer/gate divergence has already caused two silent
# forever-blocks in this codebase; this direction would be worse.

set -u

SKIP_VERIFY=0
for arg in "$@"; do
  case "$arg" in
    --skip-verify) SKIP_VERIFY=1 ;;
    -h|--help) printf 'usage: finish-worktree.sh [--skip-verify]\n'; exit 0 ;;
    *) printf 'finish-worktree: unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared helpers early (before the first die() call below) so hc_die
# is available. Sourcing has no dependency on anything checked in this
# script — it only sets HC_CONTRACTS_DIR and a few path constants.
# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

HC_DIE_PREFIX="finish-worktree"
die()  { hc_die "$1"; }
say()  { printf '%s\n' "$1"; }
warn() { printf '%s\n' "$1" >&2; }

command -v jq >/dev/null 2>&1 || die "jq is required"

# --- locate this worktree and the MAIN one ----------------------------------
WT=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null)
[ -n "$WT" ] || die "not a git repository"

GIT_DIR=$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)
GIT_COMMON=$(git -C "$WT" rev-parse --git-common-dir 2>/dev/null)
case "$GIT_COMMON" in /*) ;; *) GIT_COMMON="$WT/$GIT_COMMON" ;; esac
if [ "$GIT_DIR" = "$GIT_COMMON" ]; then
  die "this is the MAIN checkout, not a linked worktree — nothing to finish"
fi

# The main worktree is the first entry of `worktree list`. Branch operations that
# touch trunk must run THERE: git refuses to check out or move a branch that is
# checked out in another worktree, so a fast-forward attempted from in here
# would fail for a reason that has nothing to do with the work.
MAIN=$(git -C "$WT" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
[ -n "$MAIN" ] && [ -d "$MAIN" ] || die "cannot locate the main worktree"

# Sourced above (before the first die() call); if it failed, die() itself is
# unusable (it delegates to hc_die), so this one check stays a literal.
type hc_resolve >/dev/null 2>&1 \
  || { printf 'finish-worktree: harness-common.sh could not be sourced\n' >&2; exit 1; }

BRANCH=$(git -C "$WT" symbolic-ref --short -q HEAD 2>/dev/null)
[ -n "$BRANCH" ] || die "worktree HEAD is detached — check out the task branch first"

# --- trunk: resolved against the MAIN checkout ------------------------------
# hc__detect_trunk reads $PROJECT_DIR/.claude/done-config.json. That file is
# routinely gitignored, so a fresh worktree does not have it and a repo with a
# `trunk` override would silently lose it here and fall back to main/master.
# Resolve against the main checkout, which does have it.
PROJECT_DIR="$MAIN"
TRUNK=$(hc__detect_trunk)
[ -n "$TRUNK" ] || die "cannot determine trunk confidently; set .trunk in .claude/done-config.json"
[ "$BRANCH" != "$TRUNK" ] || die "the worktree is on trunk ($TRUNK) — there is nothing to integrate"

# --- resolve harness identity IN THE WORKTREE -------------------------------
# From here on PROJECT_DIR is the worktree: the done-state, the tree baseline and
# the review-log all live under the worktree's own .claude/.harness, because that
# is where /done ran.
PROJECT_DIR="$WT"
export CLAUDE_PROJECT_DIR="$WT"
hc_resolve "finish-worktree" 2>/dev/null
HARNESS_DIR="$(hc__harness_dir "$WT")"
TASK_KEY="${HC_TASK_KEY:-br-$(hc__sanitize "$BRANCH")}"
DONE_STATE="$HARNESS_DIR/done-state/$TASK_KEY.json"

say "worktree: $WT"
say "branch:   $BRANCH  →  $TRUNK"
say "main:     $MAIN"
say ""

# ===========================================================================
# GATE 1 — the worktree must be clean.
# ===========================================================================
hc_tree_status "finish-worktree" 2>/dev/null
# hc_tree_status splits the tree into BLOCKERS (introduced since the baseline)
# and WARNINGS (present at the baseline already). For teardown BOTH matter:
# `git worktree remove` would delete either, and pre-existing dirt is still
# unsaved work. The one exemption the classifier makes — paths the HARNESS
# itself owns (hc_is_harness_own_path: its state dir and its config) — is
# honoured here too, via that same predicate rather than a second spelling of
# it. Losing harness state to `worktree remove` is the point of teardown, not a
# reason to refuse.
DIRT=$(printf '%s\n%s\n' "${HC_TREE_BLOCKERS:-}" "${HC_TREE_WARNINGS:-}" \
       | hc_filter_harness_own "$WT")
if [ -n "$DIRT" ]; then
  warn "REFUSED (gate 1): the worktree is not clean. Commit or discard first:"
  printf '%s\n' "$DIRT" | sed 's/^/    /' >&2
  exit 1
fi
say "gate 1 ok: worktree clean"

# ===========================================================================
# GATE 2 — a green, fresh done-state for this task key.
# ===========================================================================
HEAD_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
HEAD_TREE=$(git -C "$WT" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)
[ -n "$HEAD_SHA" ] || die "cannot resolve worktree HEAD"

if [ "$SKIP_VERIFY" -eq 1 ]; then
  warn ""
  warn "  ####################################################################"
  warn "  #  --skip-verify: the done-state gate was BYPASSED.                #"
  warn "  #  This branch is being integrated with NO proof that its tests    #"
  warn "  #  passed or that it was reviewed. You are the verification now.   #"
  warn "  ####################################################################"
  warn ""
else
  [ -f "$DONE_STATE" ] || {
    warn "REFUSED (gate 2): no done-state at $DONE_STATE"
    warn "  Run /done in this worktree first, or re-run with --skip-verify."
    exit 1
  }

  # FRESHNESS — the gate's own Step-5 predicate, not a second sha comparison.
  # 'carry' is a pass: the shas differ but the trees are byte-identical, which
  # is precisely what the gate accepts.
  VSTATE=$(hc_verification_state "$DONE_STATE" "$HEAD_SHA" "$HEAD_TREE" "$WT")
  if [ "$VSTATE" = "stale" ]; then
    VSHA=$(jq -r '.verified_sha // "(none)"' "$DONE_STATE" 2>/dev/null)
    warn "REFUSED (gate 2): the done-state is stale."
    warn "  verified_sha: $VSHA"
    warn "  worktree HEAD: $HEAD_SHA"
    warn "  Neither the sha nor the tree matches. Re-run /done."
    exit 1
  fi

  # GREENNESS — the gate's own Step-8 aggregation.
  MIN_LEVEL=$(jq -r '.min_review_level // "high"' "$WT/.claude/done-config.json" 2>/dev/null)
  if [ -z "$MIN_LEVEL" ] || [ "$MIN_LEVEL" = "null" ]; then MIN_LEVEL="high"; fi
  hc_done_state_blocked "$DONE_STATE" "$HEAD_SHA" "${HC_BASE:-}" \
    "$HARNESS_DIR" "${HC_CONTRACTS_DIR:-}" "$MIN_LEVEL" 2>/dev/null
  if [ -n "${HC_DONE_BLOCKED_REASON:-}" ]; then
    warn "REFUSED (gate 2): the done-state is not green — ${HC_DONE_BLOCKED_REASON}"
    warn "  Fix it and re-run /done, or re-run with --skip-verify."
    exit 1
  fi
  say "gate 2 ok: done-state green and current ($VSTATE)"
fi

# ===========================================================================
# GATE 3 — rebase onto origin/<trunk>.
# ===========================================================================
say "fetching origin…"
git -C "$WT" fetch --quiet origin 2>/dev/null || die "git fetch origin failed"

ORIGIN_TRUNK=$(git -C "$WT" rev-parse -q --verify "refs/remotes/origin/$TRUNK" 2>/dev/null)
[ -n "$ORIGIN_TRUNK" ] || die "origin/$TRUNK does not resolve after fetch"

if ! git -C "$WT" rebase "origin/$TRUNK" >/dev/null 2>&1; then
  git -C "$WT" rebase --abort >/dev/null 2>&1
  warn "REFUSED (gate 3): the branch does not rebase cleanly onto origin/$TRUNK."
  warn "  The rebase was ABORTED — the worktree is exactly as you left it."
  warn "  Resolve the conflicts yourself (git rebase origin/$TRUNK), then re-run."
  exit 1
fi
say "gate 3 ok: rebased onto origin/$TRUNK"

# A rebase that actually replayed commits moves HEAD past the sha gate 2
# verified, so what lands on trunk is no longer byte-identical to what was
# reviewed. That is inherent to verify-then-rebase and is NOT made a gate —
# blocking here would mean a branch can never be integrated once trunk moves.
# It is REPORTED, because "verified" quietly meaning "verified against a
# different tree" is the kind of thing that should never be silent.
POST_SHA=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
if [ "$SKIP_VERIFY" -eq 0 ] && [ "$POST_SHA" != "$HEAD_SHA" ]; then
  if [ "$(hc_verification_state "$DONE_STATE" "$POST_SHA" \
          "$(git -C "$WT" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" "$WT")" = "stale" ]; then
    say "  note: the rebase replayed commits onto newer trunk, so the verified tree"
    say "        ($HEAD_SHA) is not the tree being integrated ($POST_SHA)."
  fi
fi
HEAD_SHA="$POST_SHA"

# ===========================================================================
# GATE 4 — fast-forward trunk. --ff-only, never a merge commit.
# ===========================================================================
MAIN_BRANCH=$(git -C "$MAIN" symbolic-ref --short -q HEAD 2>/dev/null)
if [ "$MAIN_BRANCH" != "$TRUNK" ]; then
  warn "REFUSED (gate 4): the main checkout is on '$MAIN_BRANCH', not '$TRUNK'."
  warn "  The branch is rebased and ready. Check out $TRUNK in $MAIN and re-run."
  exit 1
fi
MAIN_DIRT=$(git -C "$MAIN" status --porcelain --untracked-files=no 2>/dev/null \
            | hc_filter_harness_own "$MAIN")
# The self-owned filter matters MOST here. new-worktree.sh persists the detected
# `worktree` block into the SOURCE checkout's .claude/done-config.json, so in a
# repo that TRACKS that file, provisioning a worktree leaves the main checkout
# with exactly one modified tracked file — and --untracked-files=no sees nothing
# else. Without the filter, the harness refuses its own teardown over dirt the
# harness created.
if [ -n "$MAIN_DIRT" ]; then
  warn "REFUSED (gate 4): the main checkout has uncommitted tracked changes."
  warn "  A fast-forward would move its working tree underneath them."
  printf '%s\n' "$MAIN_DIRT" | sed 's/^/    /' >&2
  exit 1
fi

if ! git -C "$MAIN" merge --ff-only "$BRANCH" >/dev/null 2>&1; then
  warn "REFUSED (gate 4): $TRUNK cannot fast-forward to $BRANCH."
  warn "  Something moved $TRUNK locally after the rebase. Nothing was merged;"
  warn "  there is deliberately no merge-commit fallback."
  warn "  The worktree and branch are intact at $WT."
  exit 1
fi
say "gate 4 ok: $TRUNK fast-forwarded to $BRANCH"

# ===========================================================================
# TEARDOWN — only now.
# ===========================================================================
if ! git -C "$MAIN" worktree remove "$WT" >/dev/null 2>&1; then
  # Gate 1 already proved there is no unsaved work; what remains is ignored
  # build output (node_modules/, target/) and the config symlinks we created,
  # which `worktree remove` counts as a reason to stop. Removing those is the
  # whole point of teardown, so force it — but only after that proof.
  if ! git -C "$MAIN" worktree remove --force "$WT" >/dev/null 2>&1; then
    warn "note: $TRUNK was fast-forwarded, but the worktree could not be removed."
    warn "  Remove it by hand: git -C $MAIN worktree remove --force $WT"
  fi
fi
# Deleting the branch uses -D behind an EXPLICIT ancestry proof rather than -d.
# `git branch -d` refuses a branch that is not merged into its UPSTREAM, and a
# task branch has none — it would decline every single time even though trunk
# was just fast-forwarded onto it. `merge-base --is-ancestor` asserts the thing
# that actually matters (every commit is reachable from trunk) and is a stronger
# check than the one -d would have made.
if git -C "$MAIN" merge-base --is-ancestor "$BRANCH" "$TRUNK" 2>/dev/null; then
  git -C "$MAIN" branch -D "$BRANCH" >/dev/null 2>&1 \
    || warn "note: could not delete branch '$BRANCH' — delete it by hand."
else
  warn "note: '$BRANCH' is NOT an ancestor of $TRUNK — branch kept, delete it yourself."
fi

# ===========================================================================
# NEVER PUSH.
# ===========================================================================
AHEAD=$(git -C "$MAIN" log --oneline "origin/$TRUNK..$TRUNK" 2>/dev/null)
say ""
say "Done. $TRUNK now contains the task's commits; the worktree and branch are gone."
say ""
if [ -n "$AHEAD" ]; then
  say "NOT pushed. $TRUNK is ahead of origin/$TRUNK by:"
  printf '%s\n' "$AHEAD" | sed 's/^/    /'
  say ""
  say "  git -C $MAIN push origin $TRUNK"
else
  say "Nothing to push: $TRUNK matches origin/$TRUNK."
fi
say ""
say "  (your shell may still be inside the removed worktree — cd $MAIN)"
exit 0
