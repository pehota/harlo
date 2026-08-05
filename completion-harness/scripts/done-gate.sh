#!/bin/bash
#
# Completion Harness — Stop hook (the gate).
#
# Fires on every main-agent turn exit. Blocks the stop unless a valid done-state
# exists for this session and matches the live git state.
#
# Contract (matches the repo block pattern): on BLOCK, print a JSON object
#   {"decision":"block","reason":"..."}
# to stdout AND exit 0. On exit 0 the runtime parses the stdout JSON and honours
# the block decision; the reason is delivered to the agent from that JSON. (Exit
# 2 is deliberately NOT used: on exit 2 the runtime reads STDERR and ignores the
# stdout JSON, discarding the structured reason.) A short human-log line is also
# written to stderr for hook logs, but the decisive output is the stdout JSON.
#
# Fail-safe: any unexpected condition -> allow the stop (exit 0 with no decision
# JSON). We never trap the user. EXCEPTION: Step 8 (recorded-outcome check)
# deliberately INVERTS this — a missing/malformed/red outcome there fails toward
# BLOCK (see the Step 8 comment). There is deliberately NO `set -e` and NO
# catch-all EXIT trap: a stray mid-script failure must not abort before the block
# JSON is emitted, nor produce a spurious nonzero exit. Every jq/git call is
# guarded explicitly. An allow is exit 0 with empty stdout; a block is exit 0
# with the decision JSON on stdout — the two are distinguished by stdout, not by
# exit code.

# --- project root -----------------------------------------------------------
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- resolve identity (task_key, base) via the shared resolver --------------
# Sourced library: sets HC_MODE HC_TASK_KEY HC_BASE (+ PROJECT_DIR HARNESS_DIR).
# Done-state is keyed by HC_TASK_KEY (task-branch continuity across sessions),
# not the raw session id. Guarded: if it cannot be sourced we fall back to a
# session-scoped key so the gate never crashes. Sourced before the stdin read
# below so hc_read_hook_input is available; sourcing itself has no dependency
# on anything parsed from stdin.
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

# --- read hook JSON from stdin ----------------------------------------------
# jq missing -> cannot reason about state -> fail safe. This check stays
# ahead of the read (unlike auto-branch.sh/baseline-snapshot.sh, which
# degrade fields to "" instead of exiting) because the gate's stated fail-safe
# posture is "no jq -> allow the stop", not "carry on with empty fields".
hc_has_jq || exit 0

if hc_has_fn hc_read_hook_input; then
  hc_read_hook_input
  SESSION_ID="$HC_HOOK_SESSION_ID"
  STOP_HOOK_ACTIVE="$HC_HOOK_STOP_ACTIVE"
else
  # harness-common.sh failed to source: fall back to the original inline read
  # rather than defaulting STOP_HOOK_ACTIVE to "false". jq is already proven
  # present above, and a stuck-false STOP_HOOK_ACTIVE would disable the
  # recursion brake at the stop_hook_active check below on every retriggered
  # Stop — the exact runaway-recursion class this repo already got burned by.
  HOOK_INPUT=$(cat 2>/dev/null)
  SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // ""' 2>/dev/null)
  STOP_HOOK_ACTIVE=$(printf '%s' "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
fi

# Fallback session id so the gate path matches baseline-snapshot.sh exactly
# when session_id is absent (both fall back to "unknown-session").
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-session"

if hc_has_fn hc_resolve; then
  hc_resolve "$SESSION_ID" 2>/dev/null
fi
[ -z "$HC_TASK_KEY" ] && HC_TASK_KEY="session-${SESSION_ID}"

# --- helper: emit block + exit 0 --------------------------------------------
block() {
  local reason="$1"
  # stdout: the machine-readable decision the runtime consumes on exit 0.
  jq -n --arg r "$reason" '{"decision":"block","reason":$r}' 2>/dev/null \
    || printf '{"decision":"block","reason":"%s"}\n' "$reason"
  # stderr: human-readable log line only; not parsed by the runtime on exit 0.
  printf 'Completion harness: %s\n' "$reason" >&2
  exit 0
}

# --- Step 1: loop guard -----------------------------------------------------
# A block must never trap the agent forever.
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- Step 2: not a git repo -> no changeset baseline possible ---------------
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null)
if [ -z "$HEAD_SHA" ]; then
  exit 0
fi
# HEAD's TREE id — the content fingerprint the Step-5 carry compares against.
# Empty means git could not resolve it; Step 5 then refuses to carry (strict):
# no tree, no proof of identical content.
HEAD_TREE=$(git -C "$PROJECT_DIR" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)

# --- paths (task-mandated locations under .harness) -------------------------
# Done-state is keyed by HC_TASK_KEY (task mode: br-<branch>; session mode:
# session-<id>) so a task's done-state is shared across resuming sessions.
HARNESS_DIR="$(hc__harness_dir)"
DONE_STATE_FILE="$HARNESS_DIR/done-state/$HC_TASK_KEY.json"

# --- Step 2a: changeset-anchor recovery (empty HC_BASE) ---------------------
# HC_BASE is empty whenever the resolver found no anchor: session mode with no
# baselines/<sid>.sha (state dir deleted mid-session, 14-day age-reap, or a
# SessionStart that never ran for the id the gate resolves), a zero-length or
# unwritable baseline file, or task mode with an empty pin. The gate then loses
# its coverage check (hc_review_coverage_gap SKIPs without a base) and its
# changeset summary.
#
# An anchor the harness ITSELF stamped can be recovered: done-write-state.sh
# records `base_sha` from its own resolved HC_BASE and DELETES the key when that
# base is empty, so the field is a writer fact, never agent payload
# (hc__recover_base_from_state re-validates it as a live commit object anyway).
#
# STRUCTURAL SAFETY BOUNDARY — the recovered value is kept in its OWN variable
# and is deliberately NOT assigned to HC_BASE. HC_BASE drives the only two steps
# that GRANT a pass (Step 3's HEAD==base quiet-exit and Step 3c's
# empty-changeset allow); a recovered base equal to HEAD would make an entire
# unverified session look like "nothing to verify". Keeping it separate makes
# that impossible by construction rather than by predicate. The recovered anchor
# feeds ONLY checks that make the gate STRICTER: review coverage and the summary.

# --- Step 2a-0: recover the ANCHOR ITSELF from the session marker ------------
# Before any of the below: the commonest way HC_BASE goes empty is not a deleted
# state dir, it is a SESSION-ID DISAGREEMENT. The gate resolves its base from
# baselines/<its own stdin session_id>.sha; SessionStart wrote that file under
# the id IT saw. When the two ids differ, a perfectly good anchor sits one
# filename away and the session blocks with the no-anchor reason — including a
# session that changed NOTHING, which should have taken the Step-3 quiet exit.
#
# So: adopt baselines/<marker_id>.sha. Unlike the done-state recovery below,
# this value IS assigned to HC_BASE, and the provenance is what makes that safe.
# A baselines/*.sha is written by SessionStart alone, from live HEAD, before any
# edit — the exact same producer and the exact same meaning as the anchor the
# resolver failed to find. It is not agent payload, so the Step-2a "keep it out
# of HC_BASE" boundary (which exists because done-state is written mid-task) does
# not apply.
#
# Two conditions bound it, both about not INVENTING a base:
#   - the value must be a real commit object that is an ANCESTOR of HEAD. A
#     non-ancestor is a base from another line of history; judging emptiness
#     against it is meaningless.
#   - SESSION MODE only. Task mode keys by branch and pins its own base.
# Residual: if the marker names a session that started LATER than ours, its
# baseline is nearer HEAD and the changeset resolves SMALLER. That requires two
# live sessions in one checkout, which is already unsupported (they race on the
# tree); the single-session model this marker exists to serve cannot hit it.
if [ -z "$HC_BASE" ] && [ "${HC_MODE:-session}" = "session" ] && [ -f "$HARNESS_DIR/current-session" ]; then
  ANCHOR_MARKER_ID=$(cat "$HARNESS_DIR/current-session" 2>/dev/null | tr -d '\r\n')
  # Same path hygiene as the marker-state lookup below: the file's contents are
  # untrusted for filename purposes.
  case "$ANCHOR_MARKER_ID" in
    ''|'.'|'..'|*[!A-Za-z0-9._-]*) ANCHOR_MARKER_ID="" ;;
  esac
  if [ -n "$ANCHOR_MARKER_ID" ] && [ "$ANCHOR_MARKER_ID" != "$SESSION_ID" ]; then
    MARKER_ANCHOR=$(cat "$HARNESS_DIR/baselines/${ANCHOR_MARKER_ID}.sha" 2>/dev/null | tr -d '\r\n')
    if [ -n "$MARKER_ANCHOR" ] \
       && { hc_has_fn hc__is_object_id; } \
       && hc__is_object_id "$MARKER_ANCHOR" \
       && git -C "$PROJECT_DIR" cat-file -e "${MARKER_ANCHOR}^{commit}" 2>/dev/null \
       && git -C "$PROJECT_DIR" merge-base --is-ancestor "$MARKER_ANCHOR" "$HEAD_SHA" 2>/dev/null; then
      HC_BASE="$MARKER_ANCHOR"
      HC_BASE_ORIG="$MARKER_ANCHOR"

      # THE TREE ANCHOR MOVES WITH IT. The changeset anchor alone is not enough:
      # hc_resolve also pointed HC_TREE_BASE_FILE at baselines/<gate id>.dirty,
      # which in this scenario does not exist either — so hc_tree_status would
      # degrade to the empty baseline, call every pre-existing entry introduced,
      # and Step 3b would block with "finish the slice". A zero-file task in a
      # repo with any pre-existing dirt would stay stuck, one step earlier than
      # before. hc_tree_status reads HC_TREE_BASE_FILE verbatim (it does not
      # re-derive it from its session_id argument), and this runs before Step 3a,
      # so repointing it here is what makes the recovery real.
      #
      # ASYMMETRY, stated: the .sha is cross-checked against git (object id, live
      # commit, ancestor of HEAD); a .dirty is a porcelain capture with nothing to
      # validate it against, so it rests on provenance alone — same producer
      # (SessionStart, pre-edit) as the .sha it accompanies. Adopted ONLY when the
      # file exists; otherwise HC_TREE_BASE_FILE keeps pointing at the missing
      # file and the classifier stays in its strict degrade.
      if [ -f "$HARNESS_DIR/baselines/${ANCHOR_MARKER_ID}.dirty" ]; then
        HC_TREE_BASE_FILE="$HARNESS_DIR/baselines/${ANCHOR_MARKER_ID}.dirty"
      fi
    fi
  fi
fi

HC_BASE_RECOVERED=""
if { hc_has_fn hc__recover_base_from_state; }; then
  # The base recovered from OUR OWN key's done-state — only meaningful when the
  # resolver (and 2a-0 above) found no anchor.
  if [ -z "$HC_BASE" ]; then
    HC_BASE_RECOVERED=$(hc__recover_base_from_state "$DONE_STATE_FILE" "$PROJECT_DIR" 2>/dev/null)
  fi

  # SESSION-ID DISAGREEMENT. The gate keys the done-state off the session id in
  # its OWN hook stdin; /done keys it off the current-session marker
  # SessionStart wrote. When those two ids diverge (observed live: marker
  # da3cea26…, gate 28222a43…) the gate reads a key nothing ever wrote and
  # blocks forever, with a verified done-state sitting one filename away.
  #
  # So when our own key has NO state, look at the ONE state the marker names.
  # This is a candidate set of exactly TWO harness-derived paths — never a
  # directory listing — the same discipline as the Step-8 review-log anchor.
  #
  # It cannot forge a green: every piece of evidence stays pinned to the LIVE
  # repo, not to the key. Step 5 still demands verified_sha == HEAD (or a
  # byte-identical tree), Step 8 still demands green recorded outcomes and an
  # independent review-log for HEAD. Only WHICH KEY names that evidence relaxes.
  #
  # ADMISSION REQUIRES AN ANCHOR. A marker state with no usable base_sha is NOT
  # adopted: without it, coverage would SKIP and the marker path would be
  # strictly WEAKER than the anchored one — a new pass route with the coverage
  # check switched off. No anchor → leave the key alone → the honest no-anchor
  # block. And because the recovered base still never reaches HC_BASE, a marker
  # session whose base equals HEAD cannot short-circuit anything either; it must
  # produce the same HEAD-pinned evidence as everyone else.
  #
  # SESSION MODE ONLY: in task mode the key is br-<branch>, already shared across
  # sessions by design, so a session marker has no business redirecting it.
  #
  # NOT CONDITIONED ON AN EMPTY HC_BASE — and that is load-bearing since 2a-0.
  # This redirect used to sit inside the `[ -z "$HC_BASE" ]` recovery block, which
  # was harmless only while nothing could fill HC_BASE in this exact scenario.
  # 2a-0 now does: it adopts the marker's BASELINE, which falsifies that guard and
  # would skip the redirect entirely — so a disagreeing session with real work and
  # a green done-state under the marker key would block forever, the very deadlock
  # Step 2a exists to break. The redirect's own preconditions (our key has NO
  # state, session mode, and the marker state supplies a usable base_sha) are what
  # bound it; the state of HC_BASE never was.
  if [ ! -f "$DONE_STATE_FILE" ] && [ "${HC_MODE:-session}" = "session" ] && [ -f "$HARNESS_DIR/current-session" ]; then
    MARKER_ID=$(cat "$HARNESS_DIR/current-session" 2>/dev/null | tr -d '\r\n')
    # Path hygiene: the marker is a file, so treat its contents as untrusted for
    # filename purposes. Only a plain [A-Za-z0-9._-] component may name a state.
    case "$MARKER_ID" in
      ''|'.'|'..'|*[!A-Za-z0-9._-]*) MARKER_ID="" ;;
    esac
    if [ -n "$MARKER_ID" ] && [ "$MARKER_ID" != "$SESSION_ID" ]; then
      MARKER_STATE="$HARNESS_DIR/done-state/session-$MARKER_ID.json"
      MARKER_BASE=$(hc__recover_base_from_state "$MARKER_STATE" "$PROJECT_DIR" 2>/dev/null)
      if [ -n "$MARKER_BASE" ]; then
        DONE_STATE_FILE="$MARKER_STATE"
        HC_BASE_RECOVERED="$MARKER_BASE"
      fi
    fi
  fi
fi
# The base the STRICTER checks use: the real anchor when we have one, else the
# recovered one, else empty (coverage SKIPs and the reason says so — Step 4).
COVER_BASE="${HC_BASE:-$HC_BASE_RECOVERED}"

# --- Step 2b: pending-escalation one-shot pass (P1-b, #6) -------------------
# When /done needs to AskUserQuestion for a Category-C / user_halt escalation, it
# writes pending-escalation/<task_key>.json FIRST. The AskUserQuestion turn ends
# with a Stop the gate would otherwise BLOCK (no green done-state yet) — trapping
# the very question meant for the user. So: if a pending file exists, consume it
# (rm) and allow EXACTLY ONCE, letting that turn reach the user. The next Stop
# finds no pending file and re-gates normally. One file → one allow; it cannot
# indefinitely disarm the gate. Placed after the loop-guard + git checks but
# BEFORE the tree/done-state checks. Reaping is covered by the default age-reap
# (no exclusion needed). Guarded; a missing dir is a no-op.
PENDING="$HARNESS_DIR/pending-escalation/$HC_TASK_KEY.json"
if [ -f "$PENDING" ]; then
  rm -f "$PENDING" 2>/dev/null
  exit 0
fi

# --- Step 3: no commits on this changeset (HEAD == base) AND clean tree ------
# Quiet exit ONLY when nothing was committed since the base AND the working tree
# is clean. HC_BASE is the resolver's anchor: in task mode it is the pinned fork
# base (HEAD==base => no commits yet on the branch); in session mode it is the
# SessionStart baseline (HEAD==baseline => no session commits). If HC_BASE is
# empty (no anchor) we skip the quiet-exit and fall through. If HEAD == base but
# the tree is DIRTY, we do NOT exit here: an uncommitted "done" must still be
# gated, so we fall through to the remaining steps (Step 4 -> block).
if [ -n "$HC_BASE" ] && [ "$HC_BASE" = "$HEAD_SHA" ]; then
  STEP3_TREE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
  # Harness-owned dirt is not "the tree is dirty": it is the state dir and the
  # config the harness writes itself, and letting it defeat the quiet exit is
  # how the harness ends up gating on its own bookkeeping. Same predicate the
  # classifier below uses (single rule); unavailable → unfiltered, i.e. strict.
  if type hc_filter_harness_own >/dev/null 2>&1; then
    STEP3_TREE_STATUS=$(printf '%s\n' "$STEP3_TREE_STATUS" | hc_filter_harness_own "$PROJECT_DIR")
  fi
  if [ -z "$STEP3_TREE_STATUS" ]; then
    exit 0
  fi
fi

# --- Step 3a: out-of-scope non-code changeset -> silent stand down (#5) ------
# The harness governs CODING changesets only. If a changeset EXISTS (committed
# range base..HEAD non-empty OR introduced tree dirt) but EVERY changed file is
# recognised non-code (prose/docs/images per noncode_globs), the harness stands
# down completely: exit 0 with EMPTY stdout (no block JSON) — mirroring hc_state
# S_OOS. Placed AFTER Step 3 (empty-changeset quiet-exit) and BEFORE Step 3b so
# that introduced CODE dirt still blocks: hc_changeset_is_code returns NON-CODE
# ONLY when the WHOLE changeset (union of committed range + introduced paths) is
# non-code, so any code file — committed or introduced-uncommitted — keeps us in
# the gate. hc_tree_status must run first (populates HC_TREE_BLOCKERS, the
# introduced set the predicate unions in); the result is reused by Step 3b below.
# Fail-safe: hc_changeset_is_code returns "code" on ANY error → we do NOT exit →
# normal gating. An unavailable predicate/classifier also falls through (safe).
TREE_STATUS_DONE=0
if hc_has_fn hc_tree_status; then
  hc_tree_status "$SESSION_ID" 2>/dev/null
  TREE_STATUS_DONE=1
fi
if hc_has_fn hc_changeset_is_code; then
  SCOPE=$(hc_changeset_is_code "$HC_BASE" "$HEAD_SHA" "$PROJECT_DIR" 2>/dev/null)
  if [ "$SCOPE" = "noncode" ]; then
    exit 0
  fi
fi

# --- Step 3b: working tree has INTRODUCED changes -> BLOCK ------------------
# Re-check the tree live at gate time via the shared baseline-relative
# classifier (hc_tree_status). Only changes INTRODUCED this session (not present
# at the SessionStart baseline) block; pre-existing entries are ignored, not
# blocked (and never surfaced) — this is what breaks the pre-existing-untracked deadlock without
# weakening the gate (the changeset's own uncommitted work still blocks). Runs
# BEFORE the done-state checks (Steps 4/4b/5) so an introduced-dirty tree blocks
# with the S1 ("finish the slice") reason — aligned with hc_state, which
# evaluates the introduced-dirty guard FIRST. A clean tree makes this a no-op and
# the done-state checks below proceed exactly as before. Also enforced before
# escalation (Step 7). hc_tree_status already ran in Step 3a (TREE_STATUS_DONE);
# only call it here if that path was unavailable.
if [ "$TREE_STATUS_DONE" -eq 1 ]; then
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    block "finish the slice ($(hc_tree_remediation)), then commit"
  fi
elif hc_has_fn hc_tree_status; then
  hc_tree_status "$SESSION_ID" 2>/dev/null
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    block "finish the slice ($(hc_tree_remediation)), then commit"
  fi
else
  # Classifier unavailable (source failed): fall back to the strict live check
  # so the gate never weakens toward allow.
  TREE_STATUS=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
  if [ -n "$TREE_STATUS" ]; then
    block "finish the slice (commit or stash your uncommitted changes), then commit"
  fi
fi

# --- Step 3c: empty changeset -> allow (P0-b, #6) ---------------------------
# Reaching here means Step 3b found NO introduced tree blockers. If the
# commit-range base..HEAD is ALSO empty (no committed work to gate), there is
# nothing to verify → allow. This handles the case where base-advance (Step-A)
# advanced HC_BASE past foreign commits up to a point where HEAD == the advanced
# base only in content (identical trees), and, more importantly, where the
# resolved changeset diff is genuinely empty.
#
# Fail-safe: `git diff --quiet` exits 0 ONLY on a genuinely empty diff; ANY git
# failure exits non-zero → we do NOT short-circuit → fall through to the gate.
# An empty HC_BASE skips the guard entirely (no anchor → cannot judge emptiness).
# Introduced dirt has already blocked above (Step 3b precedes this), so an empty
# range with pre-existing-only dirt correctly reaches here and is allowed.
if [ -n "$HC_BASE" ] && git -C "$PROJECT_DIR" diff --quiet "$HC_BASE" "$HEAD_SHA" 2>/dev/null; then
  exit 0
fi

# --- Step 3d: SHA-keyed escalation sidecar (cross-session disarm, P2-b #6) ----
# An accepted escalation is persisted as escalation-accept/<HEAD_SHA>.json,
# keyed to the EXACT committed HEAD. A DIFFERENT session (a fresh session-<id>
# key) has no done-state for this task, so the Step-4 done-state-missing check
# below would block first — the Step-7 sidecar honoring would then be dead code
# for the cross-session case. Honoring it HERE — AFTER the tree-check (3b) and
# empty-changeset check (3c) but BEFORE the done-state checks (Step 4) — lets an
# accepted escalation survive across sessions on an unchanged trunk HEAD.
#
# Fail-safe: placed AFTER Step 3b so INTRODUCED uncommitted dirt still blocks
# first — an accepted escalation disarms the COMMITTED changeset at this exact
# HEAD, not new uncommitted work. Invariant: keyed to the exact HEAD sha, so any
# new/amended commit → different sha → no sidecar → re-block.
if [ -f "$HARNESS_DIR/escalation-accept/$HEAD_SHA.json" ]; then
  exit 0
fi

# --- changeset-missing block reason (P1-a, #6): prepend a content-ful summary -
# The S2 "/done" reason below (Steps 4/4b/5) is a bare instruction. Prepend a
# one-shot changeset summary so the message says WHAT is being gated — file/commit
# counts and how many commits were authored THIS session (HC_BASE_ORIG, the
# unadvanced base, so it can honestly read "0 authored this session" when every
# commit is foreign). Guarded: if the helper is unavailable, S2_REASON degrades to
# the bare string. HC_SESSION_ID lets hc_changeset_summary find the baseline mtime
# for its session-authorship tally.
#
# With an EMPTY base the summary is a lie — "changeset ..<head> — 0 files, +0/-0"
# is an empty range against an empty rev, not an empty changeset — so it is
# suppressed and S2_REASON stays the bare instruction.
S2_REASON="run /done to verify the changeset (owns the Step-5 review)"
if [ -n "$COVER_BASE" ] \
   && { hc_has_fn hc_changeset_summary; }; then
  HC_SESSION_ID="$SESSION_ID"
  CS_SUMMARY=$(hc_changeset_summary "${HC_BASE_ORIG:-$COVER_BASE}" "$HEAD_SHA" "$PROJECT_DIR" 2>/dev/null)
  [ -n "$CS_SUMMARY" ] && S2_REASON="$CS_SUMMARY
$S2_REASON"
fi

# NO-ANCHOR REASON — used at Step 4 ONLY, i.e. when the done-state is ALSO
# absent. Then, and only then, is the missing anchor the whole story: "/done the
# changeset" is unactionable because what is missing is the anchor, not the
# verification. The VERDICT is unchanged (same discipline as a3b600e: without an
# anchor git cannot distinguish "nothing to verify" from "a whole session of
# unverified commits", so we block rather than guess) — only the CLAIM and the
# REMEDY change: name the missing artefact, the ways it goes missing, and the one
# repair that actually restores it (a SessionStart). Re-snapshotting the baseline
# here would be the wrong repair: at gate time HEAD already carries the session's
# commits, so a fresh baseline would whitelist exactly the work under gate.
#
# SCOPED DELIBERATELY. Steps 4b/5/8 also block with S2_REASON, but they are
# reached only when a done-state EXISTS — and an anchorless state is the normal
# shape of a LEGACY state written before base_sha existed (2b740c9). Blaming a
# schema-invalid or stale-HEAD legacy state on a missing baseline, and sending
# the agent off to restart the session, would be exactly the misdiagnosis this
# whole change removes. Those steps keep the generic reason.
S2_NO_ANCHOR=""
if [ -z "$COVER_BASE" ]; then
  S2_NO_ANCHOR="no changeset anchor was recorded for this session — $(hc__harness_dir)/baselines/${SESSION_ID}.sha is missing, so the harness cannot tell an empty changeset from a whole session of unverified commits, and blocks rather than guess. Likely cause: .claude/.harness was deleted mid-session, the baseline was age-reaped, or SessionStart never ran for this session id. Restart the session so SessionStart records a baseline, then re-run /done."
fi

# --- Step 4: missing done-state -> BLOCK ------------------------------------
# The ONLY site that uses the no-anchor reason: no state AND no anchor means the
# anchor is the whole story. With a state present the later steps have a more
# specific truth to tell (see the S2_NO_ANCHOR comment).
if [ ! -f "$DONE_STATE_FILE" ]; then
  block "${S2_NO_ANCHOR:-$S2_REASON}"
fi

# --- Step 4b: done-state must satisfy the hard contract (schema) -> BLOCK ----
# The done-state exists; before trusting any of its fields (verified_sha, the
# outcome checks in Step 8, ...) it must be structurally valid. A missing schema
# file itself → hc_validate nonzero → BLOCK (broken install, safe direction). The
# jq-missing degrade at the top of the gate already exited before this point, so
# this never fires on a jq-less host.
if hc_has_fn hc_validate; then
  if ! hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$DONE_STATE_FILE" >/dev/null 2>&1; then
    block "$S2_REASON"
  fi
else
  block "$S2_REASON"
fi

# --- Step 5: verified_sha != HEAD -> BLOCK unless the TREE is identical ------
# Re-check live, do not trust any stored convenience flag. This is enforced
# BEFORE any escalation is honoured, so a stale escalation cannot disarm the
# gate once HEAD has moved past the changeset it was recorded against.
#
# TREE-IDENTICAL CARRY. A HEAD move does not always change the code: `reset
# --soft` + recommit to reword a message, or a `pull --rebase` that replays the
# same patches, leaves EVERY blob and every mode byte-identical. Demanding a
# fresh review and a rewritten done-state for that is churn with no safety
# value — the verified content is still exactly what is at HEAD. So when the
# shas differ we compare TREES, and carry the existing verification iff they
# are equal (CARRY=1). Everything downstream (Step 8's outcomes, severity,
# coverage) still runs in full; only the sha-equality requirement relaxes.
#
# Tree equality is the WHOLE guarantee — deliberately NOT ancestry. Ancestry is
# strictly weaker: `reset --hard` past an empty commit yields both an identical
# tree AND a descendant verified_sha, so an ancestry test would admit moves that
# tree equality already covers while also admitting content changes.
#
# Sources, in order: the done-state's recorded head_tree (writer-injected), else
# — for LEGACY states written before that field existed — the tree recomputed
# live from verified_sha, so the fix works on the session that installs it. When
# verified_sha STILL resolves we additionally cross-check its tree; after a gc
# it does not resolve and the recorded head_tree carries it alone.
#
# Fail direction: an empty HEAD_TREE, an unobtainable recorded tree, or any
# mismatch → BLOCK, exactly as before.
#
# The freshness decision itself lives in hc_verification_state (exact | carry |
# stale) so finish-worktree.sh consults the IDENTICAL implementation instead of
# writing its own verified_sha comparison. Only the block ACTION stays here — a
# sourced library must never exit its caller. An unavailable library forces
# "stale", i.e. BLOCK, never an accidental allow.
VERIFIED_SHA=$(jq -r '.verified_sha // ""' "$DONE_STATE_FILE" 2>/dev/null)
if hc_has_fn hc_verification_state; then
  VSTATE=$(hc_verification_state "$DONE_STATE_FILE" "$HEAD_SHA" "$HEAD_TREE" "$PROJECT_DIR")
else
  VSTATE="stale"
fi
if [ "$VSTATE" = "stale" ]; then
  block "$S2_REASON"
fi
# Audit signal only: records WHY Step 5 did not block. Step 8 deliberately
# does NOT gate the anchor admission on it (see there).
CARRY=0
[ "$VSTATE" = "carry" ] && CARRY=1

# --- Step 7: valid escalation present -> exit 0 -----------------------------
# "Valid" = escalation field present and non-null. Escalation is honoured LAST,
# after the SHA and tree checks above. Consequence: an escalation only disarms
# the exact committed changeset it was recorded against (verified_sha == HEAD,
# clean tree). Any new commit moves HEAD, Step 5 blocks first, and /done must
# be re-run — a stale escalation can no longer disarm the gate for the session.
ESCALATION=$(jq -r '.escalation // "null"' "$DONE_STATE_FILE" 2>/dev/null)
if [ -n "$ESCALATION" ] && [ "$ESCALATION" != "null" ]; then
  exit 0
fi
# NOTE: the SHA-keyed escalation sidecar (escalation-accept/<HEAD>.json) is
# honoured EARLY at Step 3d — BEFORE the done-state checks (Step 4) — so the
# cross-session disarm path is reachable even when no done-state exists for the
# new session key. It is therefore intentionally NOT re-checked here (a check at
# this point would be dead code: Step 4/5 already required a valid done-state at
# HEAD). This same-session path is the .escalation-field check above.

# --- Step 8: recorded checklist outcomes must all be green -> else BLOCK -----
# With no escalation (step 7 already returned if one was present), the gate
# enforces the CHECKLIST OUTCOMES, not just commit hygiene: a done-state that
# records red tests / red lint / a failed task_check, or a HEAD with no
# independent review-log (or one with open findings), must NOT pass.
#
# Fail direction is deliberately INVERTED from the script's global fail-safe:
# here a MISSING/null/malformed outcome (or a jq crash) is treated as NOT green
# -> BLOCK. A complete done-state written by done-write-state.sh always carries
# these fields and parses fine, so a valid green state passes; anything else is
# blocked in the safe direction. All comparisons are STRING comparisons against
# a sentinel default so an empty jq result fails toward BLOCK (never toward an
# accidental allow via a broken numeric test).

# tests must be GREEN with EVIDENCE (P1-c, #6). Escalation already short-circuited
# at Step 7, so a tests.status=="not_run" here is an unverified green claim ->
# block. A green result carries exit_code==0 AND non-empty command AND non-empty
# output_tail (un-forgeable green); a missing field -> "MISSING"/"" -> block.
TESTS_STATUS=$(jq -r '.tests.status // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TESTS_STATUS" = "not_run" ]; then
  block "tests were not run and there is no escalation — run tests, re-commit, re-run /done"
fi
TESTS_EXIT=$(jq -r '.tests.exit_code // "MISSING"' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TESTS_EXIT" != "0" ]; then
  block "fix failing tests, re-commit, re-run /done"
fi
TESTS_CMD=$(jq -r '.tests.command // ""' "$DONE_STATE_FILE" 2>/dev/null)
TESTS_TAIL=$(jq -r '.tests.output_tail // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ -z "$TESTS_CMD" ] || [ -z "$TESTS_TAIL" ]; then
  block "green tests must carry evidence (command + output_tail); re-run /done recording them"
fi

# lint (conditional). Only projects with a lint command record a .lint object.
# If .lint is PRESENT its exit_code must be exactly "0"; if it is absent/null
# (no lint configured) skip — write-state enforces lint-when-configured, so a
# missing .lint here is not a failure. A present-but-nonzero (or a jq crash
# yielding "") fails toward BLOCK via the string compare.
LINT_EXIT=$(jq -r '.lint.exit_code // "MISSING"' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$LINT_EXIT" != "MISSING" ] && [ "$LINT_EXIT" != "0" ]; then
  block "fix lint, re-commit, re-run /done"
fi

# review: an INDEPENDENT review-log must exist for the current HEAD, written by
# the Step-4 review subagent (not a self-reported count in done-state). The
# BLOCKING count is computed STRUCTURALLY by hc_review_blocking from the log's
# findings[].severity and the configured min_review_level (default "high") — the
# reviewer cannot dodge the gate by miscounting open_findings. Findings BELOW the
# threshold are advisory and never block. A missing log, or a jq crash / unknown
# severity ("ERR"), all fail toward BLOCK — same fail-toward-block discipline as
# the tests.exit_code check.
#
# CANDIDATE SET — EXACTLY TWO harness-derived paths, never a directory listing:
#   1. review-log/<HEAD_SHA>.json, preferred; and
#   2. the ANCHOR review-log/<review_anchor_sha>.json, the log the done-state
#      records as the one its verification actually rests on.
# The anchor is admitted whenever its log exists — NOT only when CARRY=1. After
# a carry the writer records a done-state at the NEW sha whose anchor is still
# the OLD log; the next gate run takes the sha-equal path (CARRY=0) and would
# otherwise find no HEAD-exact log and re-block, undoing the carry one turn
# later. It is also admitted alongside an existing HEAD-exact log, because a
# delta-scoped HEAD log may attest fewer paths than the anchor does.
#
# HOW it is admitted depends on whether a HEAD-exact log exists, and that split
# is a SAFETY boundary, not a style choice (see hc_review_coverage_gap's header):
#
#   no HEAD-exact log  → the anchor IS this verification's log. Step 5 has just
#     proved the done-state's tree == HEAD's tree, and the writer only ever
#     records an anchor whose content equals that state's, so the anchor's
#     content equals HEAD's. Pass it as EXTRA_ADMIT: blobs resolve at HEAD,
#     which is byte-identical here and survives a gc of the anchor.
#
#   HEAD-exact log EXISTS → a later REAL commit has moved the tree on, so the
#     anchor is an ORPHAN: still attesting files that commit did not touch, but
#     no longer content-equal to HEAD. Head-resolution would self-validate it.
#     Pass it as CHAIN_ADMIT instead: blobs resolve at the ANCHOR's own sha, so a
#     file the later commit actually changed is genuinely uncovered and blocks.
#
# The writer applies the SAME split on the same discriminator, so the two resolve
# an identical candidate set. The anchor must be a raw object id: a symbolic
# value would resolve against the current tree and self-validate. Schema
# validation and hc_review_blocking then run on the ONE resolved log exactly as
# before.
REVIEW_LOG="$HARNESS_DIR/review-log/$HEAD_SHA.json"
EXTRA_ADMIT=""
CHAIN_ADMIT=""
# LEGACY states predate review_anchor_sha; for them the anchor IS verified_sha
# (the log the write validated by construction), the same fallback the writer
# uses. On the sha-equal path that resolves to HEAD_SHA, so it changes nothing
# there; on a carry it names the log Step 5 just proved still describes HEAD.
ANCHOR_SHA=$(jq -r '.review_anchor_sha // .verified_sha // ""' "$DONE_STATE_FILE" 2>/dev/null)
if [ -n "$ANCHOR_SHA" ] && { hc_has_fn hc__is_object_id; }; then
  if hc__is_object_id "$ANCHOR_SHA" && [ -f "$HARNESS_DIR/review-log/$ANCHOR_SHA.json" ]; then
    if [ ! -f "$REVIEW_LOG" ]; then
      REVIEW_LOG="$HARNESS_DIR/review-log/$ANCHOR_SHA.json"
      EXTRA_ADMIT="$ANCHOR_SHA"
    else
      CHAIN_ADMIT="$ANCHOR_SHA"
    fi
  fi
fi
if [ ! -f "$REVIEW_LOG" ]; then
  block "run an independent code review, then re-run /done"
fi
# Hard contract: the review-log must be structurally valid before its
# findings[]/files_reviewed are trusted by the severity + coverage checks below.
# A missing schema file → hc_validate nonzero → BLOCK (broken install, safe).
if hc_has_fn hc_validate; then
  if ! hc_validate "$HC_CONTRACTS_DIR/review-log.schema.json" "$REVIEW_LOG" >/dev/null 2>&1; then
    block "$S2_REASON"
  fi
else
  block "$S2_REASON"
fi
MIN_LEVEL=$(jq -r '.min_review_level // "high"' "$PROJECT_DIR/.claude/done-config.json" 2>/dev/null)
[ -z "$MIN_LEVEL" ] && MIN_LEVEL="high"
# Explicit availability guard (parity with the hc_tree_status fallback): if the
# library failed to source, force ERR so we fail toward BLOCK, never toward allow.
if hc_has_fn hc_review_blocking; then
  OPEN=$(hc_review_blocking "$REVIEW_LOG" "$MIN_LEVEL")
else
  OPEN="ERR"
fi
if [ "$OPEN" != "0" ]; then
  block "address the blocking review findings (${OPEN}), then re-run /done"
fi

# review COVERAGE: the review-log must attest (in .files_reviewed) EVERY file the
# changeset touched (git diff --name-only HC_BASE..HEAD). This turns "the review
# covered the whole changeset" into a STRUCTURAL check, not prose hope —
# recomputed by the same shared function the writer uses (hc_review_coverage_gap)
# so the two can never diverge. A non-empty gap (files changed but not attested)
# BLOCKS; SKIP (no changeset base → coverage not computable) passes — a
# no-regression degrade, there was no coverage check before. hc_review_blocking's
# availability guard above already forces a block if the library failed to source,
# so a missing function here cannot silently allow. A coverage-computation error
# with a real changeset returns the full changed set (non-empty → block), never
# SKIP — so it fails toward block, not toward an accidental allow.
GAP=$(hc_review_coverage_gap "$REVIEW_LOG" "$COVER_BASE" "$HEAD_SHA" "$PROJECT_DIR" "$EXTRA_ADMIT" "$CHAIN_ADMIT")
if [ -n "$GAP" ] && [ "$GAP" != "SKIP" ]; then
  GAP_LIST=$(printf '%s' "$GAP" | tr '\n' ' ')
  block "review the uncovered files (${GAP_LIST}), then re-run /done"
fi

# task_checks: every entry must be status "passed". Count the non-passed ones;
# an absent task_checks array yields length 0 (vacuously green). A jq crash
# yields "" which is != "0" -> block.
TASK_FAILED=$(jq -r '[.task_checks[]? | select(.status != "passed")] | length' "$DONE_STATE_FILE" 2>/dev/null)
if [ "$TASK_FAILED" != "0" ]; then
  block "fix ${TASK_FAILED} task check(s) not passed, then re-run /done"
fi

# --- Step 9: all checks pass -> allow the stop ------------------------------
#
# WORKTREE TEARDOWN SUGGESTION. When the gate allows and the project dir is a
# LINKED worktree on a non-trunk branch, the work is verified and ready to
# integrate — so name the script that does it.
#
# This is a SUGGESTION and nothing else. The gate must never integrate anything
# as a side effect of verification: /done proves, finish-worktree.sh acts, and a
# hook that quietly merged on a green result would make every verification a
# publication. It does not touch the allow/block decision and it is not reached
# from any block path.
#
# It goes to STDERR deliberately. This script's contract is that an allow is
# exit 0 with EMPTY stdout and a block is exit 0 with the decision JSON — the
# two are distinguished by stdout, not by exit code. Putting a human line on
# stdout would break that discriminator for anything parsing it. stderr is the
# channel the gate already uses for its human log line.
#
# Guarded end to end: a git failure, a missing branch, an unconfident trunk, or
# the main checkout all fall through to a plain exit 0.
if [ -n "${HC_BRANCH:-}" ] && [ -n "${HC_TRUNK:-}" ] && [ "$HC_BRANCH" != "$HC_TRUNK" ]; then
  GD=$(git -C "$PROJECT_DIR" rev-parse --absolute-git-dir 2>/dev/null)
  GC=$(git -C "$PROJECT_DIR" rev-parse --git-common-dir 2>/dev/null)
  case "$GC" in /*) ;; *) GC="$PROJECT_DIR/$GC" ;; esac
  if [ -n "$GD" ] && [ -n "$GC" ] && [ "$GD" != "$GC" ]; then
    printf 'Completion harness: verified. To integrate this worktree into %s, run finish-worktree.sh (it never pushes).\n' \
      "$HC_TRUNK" >&2
  fi
fi
exit 0
