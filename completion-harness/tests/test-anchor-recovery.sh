#!/bin/bash
#
# BEHAVIOURAL test — the gate must be HONEST when no changeset ANCHOR exists,
# and must RECOVER one only when recovery is provably safe.
#
# Symptom this pins down (reproduced byte-for-byte before the fix): in a repo
# with everything committed and a clean tree, the Stop gate emitted
#
#   changeset ..8af4e57 — 0 files, +0/-0
#   tree: 0 pre-existing, 0 new
#   run /done to verify the changeset (owns the Step-5 review)
#
# Note the EMPTY base before the "..". hc__resolve_session_base found no
# baselines/<sid>.sha, so HC_BASE was "" — which (i) makes Step 3c's
# empty-changeset allow skip its own guard, and (ii) makes hc_changeset_summary
# render an empty range and the reason instruct a /done that cannot fix the real
# problem. The VERDICT (block) is correct and stays: with no anchor git cannot
# distinguish "nothing to verify" from "a whole session of unverified commits".
# Only the CLAIM and the REMEDY change — the same discipline as a3b600e.
#
# The suite also pins the two SAFE recoveries and the ONE unsafe shortcut that
# must stay unimplemented:
#   (b) base_sha stamped into an existing done-state by done-write-state.sh —
#       a writer-computed FACT (deleted, never defaulted, when empty), so it
#       cannot be forged by an agent payload.
#   (a) the done-state reached via the current-session MARKER when the gate's own
#       key has none — the evidence stays HEAD/tree-pinned and outcome-checked;
#       only WHICH KEY names it relaxes. Admitted only when it also supplies a
#       usable base_sha, so the marker path is never weaker than the anchored one.
#   (c) a marker session's baselines/<id>.sha (+ its .dirty) AS the anchor —
#       Step 2a-0, layer I below. This suite previously REJECTED this recovery
#       outright, on the grounds that a marker whose base == HEAD makes the
#       changeset look empty and waves an unverified session through. That
#       rejection is now DELIBERATELY REVERSED, and the reversal is bounded:
#         - the value must be an object id naming a live commit that is an
#           ANCESTOR of HEAD, session mode only (I3 pins the rejection);
#         - a non-empty commit range still blocks with every check intact (I2);
#         - introduced tree dirt still blocks (I5).
#       What it buys: the SESSION-ID DISAGREEMENT (the gate resolves a different
#       id than the one SessionStart wrote) otherwise blocks a task that changed
#       NOTHING, forever, with a usable anchor one filename away.
#       RESIDUAL, accepted and documented in design.md: if the marker names a
#       session that started LATER than the one being gated, its baseline sits
#       nearer HEAD and the changeset resolves smaller. That needs the gated
#       session's own baseline to have vanished AND a second session to have
#       started in the same checkout — already outside the supported
#       single-session model.
#
# STRUCTURAL SAFETY INVARIANT (asserted, not merely intended): a base recovered
# from a DONE-STATE — an artefact written mid-task — may only feed checks that
# make the gate STRICTER (coverage, the summary). It is never assigned to
# HC_BASE, so it cannot reach Step 3's quiet-exit or Step 3c's empty-changeset
# allow, the only two places an anchor grants a pass. Recovery (c) is the sole
# exception and turns on PROVENANCE, not on the value: a baselines/*.sha is
# written by SessionStart alone, from live HEAD, before any edit — the same
# producer and meaning as the anchor the resolver missed.
#
# Runs against the source-tree scripts; each case builds an isolated throwaway
# git repo, in the style of test-missing-baseline.sh. No install, no set -e.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
HC_COMMON="$SCRIPTS/harness-common.sh"
GATE="$SCRIPTS/done-gate.sh"

# The honest no-anchor phrases the gate must use, and the misdiagnosis it must
# stop emitting.
NOANCHOR_PHRASE="no changeset anchor was recorded for this session"
RESTART_PHRASE="restart the session"
MISDIAGNOSIS="run /done to verify the changeset"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-anchor-recovery =="

if [ ! -f "$HC_COMMON" ]; then
  bad "harness-common.sh missing at $HC_COMMON"
  echo; echo "test-anchor-recovery: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot build done-state fixtures"
  echo; echo "test-anchor-recovery: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

# is_block <stdout> → 0 if the gate stdout is a block decision. A quiet exit is
# ALSO exit 0, so every assertion here reads stdout, never the exit code.
is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }
reason()   { printf '%s' "$1" | jq -r '.reason // ""' 2>/dev/null; }

# Fresh repo on `main` (trunk → session mode, task_key=session-<sid>), TWO more
# commits (b.js, c.js) laid on top of the shared fixture's root commit so a
# changeset spans three commits total. Echoes the repo path.
make_repo() {
  local r; r=$(hc__test_make_repo)
  printf 'b\n' > "$r/b.js"; git -C "$r" add -A; git -C "$r" commit -qm c2
  printf 'c\n' > "$r/c.js"; git -C "$r" add -A; git -C "$r" commit -qm c3
  printf '%s' "$r"
}

# A green, HEAD-pinned done-state + a review-log attesting the WHOLE range
# <base>..HEAD, written under done-state/session-<key>.json. When <base_sha> is
# non-empty it is stamped in, exactly as done-write-state.sh does.
seed_green_done() {
  local r="$1" key="$2" base="$3"
  local head tree files
  head=$(git -C "$r" rev-parse HEAD)
  tree=$(git -C "$r" rev-parse 'HEAD^{tree}')
  if [ -n "$base" ]; then
    files=$(git -C "$r" diff --name-only "$base" "$head" 2>/dev/null | jq -R . | jq -s .)
  else
    files='[]'
  fi
  jq -n --arg h "$head" --argjson f "$files" \
    '{contract_version:1,reviewed_sha:$h,min_review_level:"high",files_reviewed:$f,findings:[],open_findings:0}' \
    > "$r/.claude/.harness/review-log/$head.json"
  jq -n --arg sid "$key" --arg h "$head" --arg t "$tree" --arg b "$base" \
    '{contract_version:1,session_id:$sid,verified_sha:$h,head_tree:$t,tree_clean:true,
      dod:{sources:["base"],items:["tests green"]},
      tests:{exit_code:0,command:"t",output_tail:"ok"},
      task_checks:[{desc:"x",status:"passed"}],escalation:null}
     | (if $b != "" then .base_sha = $b else . end)' \
    > "$r/.claude/.harness/done-state/session-$key.json"
}

# SessionStart's tree baseline for <sid> (empty = clean at baseline), so
# hc_tree_status is not in its degraded/strict mode and the cases below isolate
# the CHANGESET anchor rather than the TREE anchor.
seed_tree_base() {
  printf '' > "$1/.claude/.harness/baselines/$2.dirty"
}

run_gate() {
  printf '{"session_id":"%s","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null
}

# ============================================================================
# A — NO ANCHOR, NOTHING RECOVERABLE. baselines/<sid>.sha absent, no done-state
#     for any key. Still BLOCKS (strict direction unchanged), but the reason must
#     name the missing anchor and the restart remedy, and must NOT render an
#     empty changeset range nor instruct a /done that cannot fix it.
# ============================================================================
R=$(make_repo); SID=noanchor
seed_tree_base "$R" "$SID"
OUT=$(run_gate "$R" "$SID"); RSN=$(reason "$OUT")
if is_block "$OUT"; then
  ok "A no anchor still BLOCKS (strict direction unchanged)"
else
  bad "A no anchor did not block — strict guarantee lost. out=$OUT"
fi
if printf '%s' "$RSN" | grep -qi "$NOANCHOR_PHRASE"; then
  ok "A no anchor: reason states the anchor was never recorded"
else
  bad "A no anchor: reason lacks '$NOANCHOR_PHRASE'. reason=$RSN"
fi
if printf '%s' "$RSN" | grep -q "baselines/$SID.sha"; then
  ok "A no anchor: reason names the missing artefact by path"
else
  bad "A no anchor: reason does not name baselines/$SID.sha. reason=$RSN"
fi
if printf '%s' "$RSN" | grep -qi "$RESTART_PHRASE"; then
  ok "A no anchor: reason carries the restart-the-session remediation"
else
  bad "A no anchor: reason omits the restart remediation. reason=$RSN"
fi
if printf '%s' "$RSN" | grep -q "$MISDIAGNOSIS"; then
  bad "A no anchor: reason still gives the unactionable '/done' instruction. reason=$RSN"
else
  ok "A no anchor: reason no longer misdiagnoses this as a missing /done"
fi
if printf '%s' "$RSN" | grep -qE 'changeset \.\.'; then
  bad "A no anchor: reason still renders an EMPTY changeset range. reason=$RSN"
else
  ok "A no anchor: reason no longer renders an empty '..<head>' range"
fi
rm -rf "$R"

# ============================================================================
# D — DIRTY TREE, NO ANCHOR. An introduced working-tree change must block on its
#     own terms (the S1 "finish the slice" reason, Step 3b) regardless of the
#     anchor situation. The no-anchor wording must not displace it, and no
#     recovery may ever let uncommitted work through.
# ============================================================================
R=$(make_repo); SID=dirty-noanchor
seed_tree_base "$R" "$SID"
printf 'new\n' > "$R/introduced.js"
OUT=$(run_gate "$R" "$SID"); RSN=$(reason "$OUT")
if is_block "$OUT"; then
  ok "D dirty tree + no anchor BLOCKS"
else
  bad "D dirty tree + no anchor did not block. out=$OUT"
fi
if printf '%s' "$RSN" | grep -q "introduced.js"; then
  ok "D dirty tree blocks on the introduced path (Step 3b keeps precedence)"
else
  bad "D dirty tree: reason does not name the introduced path. reason=$RSN"
fi
rm -rf "$R"

# ============================================================================
# B — RECOVERY (b): the done-state's writer-stamped base_sha.
#
# B1 is the discriminating case. With HC_BASE empty the coverage check SKIPs, so
# a review-log attesting NOTHING sailed through a two-file changeset: the gate
# ALLOWED. Recovering the anchor restores the coverage computation and it blocks.
# ============================================================================
R=$(make_repo); SID=recov-gap
C1=$(git -C "$R" rev-parse HEAD~2)
seed_tree_base "$R" "$SID"
seed_green_done "$R" "$SID" ""            # review-log attests [] ...
jq --arg b "$C1" '.base_sha = $b' "$R/.claude/.harness/done-state/session-$SID.json" \
  > "$R/.claude/.harness/done-state/session-$SID.json.tmp" \
  && mv "$R/.claude/.harness/done-state/session-$SID.json.tmp" \
        "$R/.claude/.harness/done-state/session-$SID.json"   # ... but base_sha spans 2 files
OUT=$(run_gate "$R" "$SID"); RSN=$(reason "$OUT")
if is_block "$OUT"; then
  ok "B1 recovered anchor restores the coverage check (uncovered changeset BLOCKS)"
else
  bad "B1 recovered anchor did not restore coverage — gate allowed an unattested changeset. out=$OUT"
fi
case "$RSN" in
  *"review the uncovered files"*b.js*|*"review the uncovered files"*c.js*)
    ok "B1 block names the uncovered files from the recovered range" ;;
  *) bad "B1 block is not the coverage block. reason=$RSN" ;;
esac
rm -rf "$R"

# B2 — same recovery, but the review-log DOES attest the whole recovered range:
#      the normal checks run and are satisfied → the gate must ALLOW, not block.
R=$(make_repo); SID=recov-ok
C1=$(git -C "$R" rev-parse HEAD~2)
seed_tree_base "$R" "$SID"
seed_green_done "$R" "$SID" "$C1"         # files_reviewed = diff C1..HEAD, base_sha = C1
OUT=$(run_gate "$R" "$SID")
if [ -z "$OUT" ]; then
  ok "B2 recovered anchor + full coverage + green outcomes → ALLOW"
else
  bad "B2 recovered anchor blocked a fully-verified changeset. out=$OUT"
fi
rm -rf "$R"

# B3 — hc__recover_base_from_state's admission guards, unit-level. Only a raw
#      object id naming a commit that EXISTS in this repo is admissible; a
#      symbolic name would resolve against the current tree and self-validate,
#      and a dangling/foreign sha would become a rev git later errors on.
R=$(make_repo)
# shellcheck source=../scripts/harness-common.sh
. "$HC_COMMON" 2>/dev/null
C1=$(git -C "$R" rev-parse HEAD~2)
S="$R/.claude/.harness/done-state/probe.json"
mk_state() { jq -n --arg b "$1" 'if $b == "ABSENT" then {} else {base_sha:$b} end' > "$S"; }
mk_state "$C1"
[ "$(hc__recover_base_from_state "$S" "$R")" = "$C1" ] \
  && ok "B3 recovers a real commit sha" \
  || bad "B3 did not recover a real commit sha"
mk_state "HEAD"
[ -z "$(hc__recover_base_from_state "$S" "$R")" ] \
  && ok "B3 rejects a SYMBOLIC base_sha (would self-validate against the live tree)" \
  || bad "B3 accepted the symbolic base_sha 'HEAD'"
mk_state "no-git"
[ -z "$(hc__recover_base_from_state "$S" "$R")" ] \
  && ok "B3 rejects the literal 'no-git' baseline marker" \
  || bad "B3 accepted 'no-git' as an anchor"
mk_state "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
[ -z "$(hc__recover_base_from_state "$S" "$R")" ] \
  && ok "B3 rejects a well-formed sha that is not an object in this repo" \
  || bad "B3 accepted a dangling sha as an anchor"
mk_state "ABSENT"
[ -z "$(hc__recover_base_from_state "$S" "$R")" ] \
  && ok "B3 recovers nothing when base_sha is absent (writer deletes it on an empty base)" \
  || bad "B3 invented an anchor from a state with no base_sha"
[ -z "$(hc__recover_base_from_state "$R/.claude/.harness/done-state/nope.json" "$R")" ] \
  && ok "B3 recovers nothing from a missing done-state" \
  || bad "B3 returned a value for a missing done-state"
rm -rf "$R"

# ============================================================================
# C — THE CASE-2 TRAP. A recovered anchor equal to HEAD must NEVER be usable to
#     declare the changeset empty. This is the structural invariant: the
#     recovered value never reaches HC_BASE, so Step 3's quiet-exit and Step 3c's
#     empty-changeset allow cannot see it. Fixture: base_sha == HEAD, clean tree,
#     and a done-state whose recorded outcomes are RED. If recovery leaked into
#     HC_BASE the gate would quiet-exit at Step 3 (empty stdout) and wave the
#     unverified session through; it must block on the red outcome instead.
# ============================================================================
R=$(make_repo); SID=trap-head
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
seed_tree_base "$R" "$SID"
seed_green_done "$R" "$SID" "$HEAD_SHA"
jq '.tests.exit_code = 1' "$R/.claude/.harness/done-state/session-$SID.json" > "$R/ds.tmp" \
  && mv "$R/ds.tmp" "$R/.claude/.harness/done-state/session-$SID.json"
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  ok "C recovered base == HEAD does NOT quiet-exit; the outcome check still runs"
else
  bad "C recovered base == HEAD waved an unverified session through. out=[$OUT]"
fi
case "$(reason "$OUT")" in
  *"fix failing tests"*) ok "C the block is the recorded-outcome block, as it should be" ;;
  *) bad "C blocked for the wrong reason: $(reason "$OUT")" ;;
esac
rm -rf "$R"

# ============================================================================
# E — DURABILITY ACROSS THE NEXT /done. The recovery reads base_sha out of the
#     done-state, but /done REWRITES that state, and with the writer's own
#     HC_BASE empty the fact-merge DELETES the key. Without a writer-side carry
#     the anchor survives exactly one turn and the gate reverts to no-anchor.
#     The writer must re-read the anchor from the state it is replacing.
# ============================================================================
WRITER="$SCRIPTS/done-write-state.sh"
R=$(make_repo); SID=durable
C1=$(git -C "$R" rev-parse HEAD~2)
HEADS=$(git -C "$R" rev-parse HEAD)
seed_tree_base "$R" "$SID"
seed_green_done "$R" "$SID" "$C1"
# No baselines/*.sha at all → the writer's dead-id backstop is skipped and its
# own HC_BASE resolves empty, exactly as in the reported repro.
PAYLOAD='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITER" "$SID" >/dev/null 2>&1
REWROTE=$(jq -r '.base_sha // ""' "$R/.claude/.harness/done-state/session-$SID.json" 2>/dev/null)
if [ "$REWROTE" = "$C1" ]; then
  ok "E /done rewrite carries the recovered anchor forward (base_sha survives)"
else
  bad "E /done rewrite dropped base_sha (recovery would work exactly once). got='$REWROTE' want='$C1'"
fi
rm -rf "$R"

# E2 — the carry must never OUTRANK a real base. With a live baseline the
#      writer's own HC_BASE wins over whatever the old state happened to hold.
R=$(make_repo); SID=durable2
C1=$(git -C "$R" rev-parse HEAD~2); C2=$(git -C "$R" rev-parse HEAD~1)
seed_tree_base "$R" "$SID"
seed_green_done "$R" "$SID" "$C1"
printf '%s\n' "$C2" > "$R/.claude/.harness/baselines/$SID.sha"   # real anchor = C2
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITER" "$SID" >/dev/null 2>&1
REWROTE=$(jq -r '.base_sha // ""' "$R/.claude/.harness/done-state/session-$SID.json" 2>/dev/null)
if [ "$REWROTE" = "$C2" ]; then
  ok "E2 a live baseline still wins over the carried anchor"
else
  bad "E2 carried anchor outranked the live baseline. got='$REWROTE' want='$C2'"
fi
rm -rf "$R"

# ============================================================================
# F — RECOVERY (a): the current-session MARKER names the done-state key.
#
# Session-id disagreement, observed live: /done wrote under the marker's id
# while the Stop gate resolved a different one from its own hook stdin, so the
# gate read a key nothing ever wrote and blocked forever with a verified
# done-state one filename away.
# ============================================================================
R=$(make_repo); GATE_SID=gate-id; MARK_SID=marker-id
C1=$(git -C "$R" rev-parse HEAD~2)
seed_tree_base "$R" "$GATE_SID"
seed_green_done "$R" "$MARK_SID" "$C1"                        # state under the OTHER key
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID")
if [ -z "$OUT" ]; then
  ok "F1 marker-named done-state clears the gate for a diverged session id"
else
  bad "F1 marker fallback did not resolve the done-state. out=$OUT"
fi
rm -rf "$R"

# F2 — the marker path is not a bypass: the evidence is still HEAD-pinned. Same
#      fixture, but a commit lands after the marker session's verification, so
#      verified_sha/head_tree no longer describe HEAD → Step 5 blocks.
R=$(make_repo); GATE_SID=gate-id2; MARK_SID=marker-id2
C1=$(git -C "$R" rev-parse HEAD~2)
seed_tree_base "$R" "$GATE_SID"
seed_green_done "$R" "$MARK_SID" "$C1"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
printf 'd\n' > "$R/d.js"; git -C "$R" add -A; git -C "$R" commit -qm c4
OUT=$(run_gate "$R" "$GATE_SID")
if is_block "$OUT"; then
  ok "F2 marker fallback still BLOCKS when the evidence no longer describes HEAD"
else
  bad "F2 marker fallback let a stale verification through. out=[$OUT]"
fi
rm -rf "$R"

# F3 — THE CASE-2 TRAP, marker edition. The marker names a session whose base
#      EQUALS HEAD (an empty changeset) and whose verification is stale. If the
#      gate adopted that base as its anchor, Step 3's quiet-exit would fire and
#      an entire unverified session would be waved through with EMPTY stdout.
#      The recovered anchor never reaches HC_BASE, so it must block instead.
R=$(make_repo); GATE_SID=gate-trap; MARK_SID=marker-trap
seed_tree_base "$R" "$GATE_SID"
OLD_HEAD=$(git -C "$R" rev-parse HEAD)
seed_green_done "$R" "$MARK_SID" "$OLD_HEAD"       # base_sha == the head it verified
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
printf 'e\n' > "$R/e.js"; git -C "$R" add -A; git -C "$R" commit -qm c5   # unverified work
OUT=$(run_gate "$R" "$GATE_SID")
if is_block "$OUT"; then
  ok "F3 marker base == its HEAD does NOT quiet-exit an unverified session"
else
  bad "F3 CASE-2 TRAP: marker anchor waved an unverified session through. out=[$OUT]"
fi
rm -rf "$R"

# F4 — a marker state with NO usable base_sha must NOT be adopted. Adopting it
#      would give a pass route with coverage SKIPped — strictly weaker than the
#      anchored path. No anchor → honest no-anchor block.
R=$(make_repo); GATE_SID=gate-noanchor2; MARK_SID=marker-noanchor
seed_tree_base "$R" "$GATE_SID"
seed_green_done "$R" "$MARK_SID" ""                # green, but no base_sha stamped
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT" && printf '%s' "$RSN" | grep -qi "$NOANCHOR_PHRASE"; then
  ok "F4 anchorless marker state is not adopted; the honest no-anchor block stands"
else
  bad "F4 adopted an anchorless marker state (coverage would be off). out=[$OUT]"
fi
rm -rf "$R"

# F5 — the marker is a FILE whose contents are untrusted for filename purposes.
#      A traversal payload must be rejected outright, not turned into a path.
R=$(make_repo); GATE_SID=gate-trav
seed_tree_base "$R" "$GATE_SID"
printf '../../../../etc/passwd\n' > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT" && printf '%s' "$RSN" | grep -qi "$NOANCHOR_PHRASE"; then
  ok "F5 a non-filename marker value is rejected (no path traversal)"
else
  bad "F5 traversal marker was not rejected. out=[$OUT]"
fi
rm -rf "$R"

# ============================================================================
# G — THE NO-ANCHOR REASON MUST NOT DISPLACE A MORE SPECIFIC ONE.
#
# An anchorless done-state is the normal shape of a LEGACY state (written before
# base_sha existed, 2b740c9). If the no-anchor wording applied wherever COVER_BASE
# is empty, a legacy state that is merely STALE would be blamed on a missing
# baseline and the agent sent off to restart the session — the same class of false
# claim commit 1 exists to remove. The no-anchor reason belongs to Step 4 alone.
# ============================================================================
R=$(make_repo); SID=legacy-stale
seed_tree_base "$R" "$SID"
seed_green_done "$R" "$SID" ""                  # legacy: green, but no base_sha
printf 'f\n' > "$R/f.js"; git -C "$R" add -A; git -C "$R" commit -qm c6   # HEAD moves on
OUT=$(run_gate "$R" "$SID"); RSN=$(reason "$OUT")
if is_block "$OUT"; then
  ok "G stale legacy state + no anchor BLOCKS"
else
  bad "G stale legacy state did not block. out=[$OUT]"
fi
if printf '%s' "$RSN" | grep -qi "$NOANCHOR_PHRASE"; then
  bad "G blamed a stale done-state on the missing baseline. reason=$RSN"
else
  ok "G the stale state gets its own reason, not the no-anchor wording"
fi
case "$RSN" in
  *"$MISDIAGNOSIS"*) ok "G the reason is the generic re-run-/done instruction (Step 5)" ;;
  *) bad "G unexpected reason for a stale state: $RSN" ;;
esac
rm -rf "$R"

# ============================================================================
# H — THE CASE-2 INSTANCE AS OBSERVED: the marker names a session whose base
#     equals the CURRENT HEAD, green, with a review-log at HEAD.
#
#     F3 covers the neighbouring shape (base == an OLD head, HEAD since moved).
#     This is the literal one. It ALLOWS, and that is the correct outcome, not a
#     bypass: the evidence is pinned to the exact commit at HEAD (verified_sha ==
#     HEAD, its own review-log, green outcomes), and an empty changeset AT that
#     commit genuinely is nothing to verify. The dangerous reading of case 2 —
#     the marker's base reaching HC_BASE and quiet-exiting at Step 3 WITHOUT that
#     evidence — is closed structurally and asserted by C and F3. H2 pins the
#     distinction by stripping the review-log: same anchor, no evidence → BLOCK.
# ============================================================================
R=$(make_repo); GATE_SID=gate-h; MARK_SID=marker-h
HEADS=$(git -C "$R" rev-parse HEAD)
seed_tree_base "$R" "$GATE_SID"
seed_green_done "$R" "$MARK_SID" "$HEADS"        # base_sha == verified_sha == HEAD
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID")
if [ -z "$OUT" ]; then
  ok "H1 marker base == HEAD allows only on HEAD-pinned evidence (verified at this exact commit)"
else
  bad "H1 blocked a verification pinned to the exact current HEAD. out=$OUT"
fi
rm -rf "$R"

# H2 — identical fixture minus the review-log: the anchor alone must buy nothing.
R=$(make_repo); GATE_SID=gate-h2; MARK_SID=marker-h2
HEADS=$(git -C "$R" rev-parse HEAD)
seed_tree_base "$R" "$GATE_SID"
seed_green_done "$R" "$MARK_SID" "$HEADS"
rm -f "$R/.claude/.harness/review-log/$HEADS.json"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT" && printf '%s' "$RSN" | grep -q "independent code review"; then
  ok "H2 same anchor without a review-log still BLOCKS (the anchor buys nothing on its own)"
else
  bad "H2 marker anchor waved a session through without a review. out=[$OUT]"
fi
rm -rf "$R"

# ============================================================================
# I — MARKER BASELINE recovery (Step 2a-0). The gate's own baselines/<sid>.sha is
#     absent, but the current-session marker names a session whose baseline .sha
#     exists. That file is written by SessionStart alone, from live HEAD, before
#     any edit — the same producer and meaning as the anchor the resolver missed
#     — so it IS adopted as HC_BASE (unlike the done-state recovery, which is
#     kept out of HC_BASE). This is what unblocks a session that changed nothing.
# ============================================================================

# I1 — marker baseline == HEAD, clean tree: nothing was committed, nothing is
#      dirty. Must take the Step-3 quiet exit instead of the no-anchor block.
#      The gate id gets NO baseline of its own — seeding one would hand-repair
#      the very disagreement under test.
R=$(make_repo); GATE_SID=gate-i1; MARK_SID=marker-i1
HEADS=$(git -C "$R" rev-parse HEAD)
seed_tree_base "$R" "$MARK_SID"
printf '%s\n' "$HEADS" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID")
if is_block "$OUT"; then
  bad "I1 empty changeset still blocked despite a recoverable marker baseline. out=[$OUT]"
else
  ok "I1 marker baseline recovers the anchor → empty changeset takes the quiet exit"
fi
rm -rf "$R"

# I2 — same recovery, but the marker baseline is C1 while HEAD is C3: a real
#      unverified changeset. Recovery must not forge a pass.
R=$(make_repo); GATE_SID=gate-i2; MARK_SID=marker-i2
C1=$(git -C "$R" rev-parse HEAD~2)
seed_tree_base "$R" "$GATE_SID"
printf '%s\n' "$C1" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID")
if is_block "$OUT"; then
  ok "I2 recovered anchor with real commits still BLOCKS (no forged pass)"
else
  bad "I2 recovery waved an unverified changeset through. out=[$OUT]"
fi
rm -rf "$R"

# I3 — the marker baseline names a commit that is NOT an ancestor of HEAD (here:
#      a well-formed sha from an unrelated history). Judging emptiness against
#      another line of history is meaningless → not adopted → no-anchor block.
R=$(make_repo); GATE_SID=gate-i3; MARK_SID=marker-i3
FOREIGN=$(mktemp -d)
git -C "$FOREIGN" init -q -b main
git -C "$FOREIGN" config user.email t@t; git -C "$FOREIGN" config user.name t
printf 'z\n' > "$FOREIGN/z.js"; git -C "$FOREIGN" add -A; git -C "$FOREIGN" commit -qm z
FOREIGN_SHA=$(git -C "$FOREIGN" rev-parse HEAD)
rm -rf "$FOREIGN"
seed_tree_base "$R" "$GATE_SID"
printf '%s\n' "$FOREIGN_SHA" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT" && printf '%s' "$RSN" | grep -qi "$NOANCHOR_PHRASE"; then
  ok "I3 non-ancestor marker baseline is NOT adopted (honest no-anchor block)"
else
  bad "I3 adopted a baseline from another history. out=[$OUT]"
fi
rm -rf "$R"

# I4 — the tree anchor must move with the changeset anchor. Same disagreement,
#      but the repo has PRE-EXISTING dirt. Recovering only the .sha would leave
#      HC_TREE_BASE_FILE pointing at the gate id's missing .dirty → empty
#      baseline → every entry "introduced" → Step 3b "finish the slice". The
#      task changed nothing, so it must still take the quiet exit.
R=$(make_repo); GATE_SID=gate-i4; MARK_SID=marker-i4
HEADS=$(git -C "$R" rev-parse HEAD)
printf 'pre-existing\n' > "$R/untracked-note.txt"
# SessionStart's capture under the MARKER id, recorded while that dirt was
# already there — i.e. the real pre-edit snapshot, not a hand-repair.
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$MARK_SID.dirty"
printf '%s\n' "$HEADS" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT"; then
  bad "I4 pre-existing dirt blocked a zero-file task — tree anchor not recovered. reason=[$RSN]"
else
  ok "I4 marker .dirty recovers the TREE anchor too (pre-existing dirt does not block)"
fi
rm -rf "$R"

# I5 — the recovery must not whitelist the session's OWN uncommitted work: dirt
#      absent from the marker's snapshot is still introduced and still blocks.
R=$(make_repo); GATE_SID=gate-i5; MARK_SID=marker-i5
HEADS=$(git -C "$R" rev-parse HEAD)
: > "$R/.claude/.harness/baselines/$MARK_SID.dirty"   # clean at snapshot time
printf '%s\n' "$HEADS" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
printf 'new work\n' > "$R/introduced.js"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT" && printf '%s' "$RSN" | grep -q "finish the slice"; then
  ok "I5 introduced dirt still BLOCKS after tree-anchor recovery"
else
  bad "I5 recovered tree anchor whitelisted the session's own work. out=[$OUT]"
fi
rm -rf "$R"

# I6 — REGRESSION GUARD for the interaction between 2a-0 and Step 2a. The full
#      disagreement: the marker session has BOTH a baseline (so 2a-0 adopts an
#      anchor) AND the green done-state + review-log for real committed work.
#      Step 2a's done-state redirect must still fire. It used to live inside the
#      `[ -z "$HC_BASE" ]` recovery block, which 2a-0 falsifies — leaving /done
#      writing under the marker key and the gate reading the gate key forever.
R=$(make_repo); GATE_SID=gate-i6; MARK_SID=marker-i6
C2=$(git -C "$R" rev-parse HEAD~1)
seed_tree_base "$R" "$MARK_SID"
printf '%s\n' "$C2" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
seed_green_done "$R" "$MARK_SID" "$C2"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT"; then
  bad "I6 2a-0 shadowed the Step-2a done-state redirect (deadlock is back). reason=[$RSN]"
else
  ok "I6 anchor recovery and done-state redirect coexist (verified marker state honoured)"
fi
rm -rf "$R"

# I7 — the redirect still buys nothing on its own: same fixture, review-log
#      removed. A redirected key must not skip the review requirement.
R=$(make_repo); GATE_SID=gate-i7; MARK_SID=marker-i7
C2=$(git -C "$R" rev-parse HEAD~1)
HEADS=$(git -C "$R" rev-parse HEAD)
seed_tree_base "$R" "$MARK_SID"
printf '%s\n' "$C2" > "$R/.claude/.harness/baselines/$MARK_SID.sha"
seed_green_done "$R" "$MARK_SID" "$C2"
rm -f "$R/.claude/.harness/review-log/$HEADS.json"
printf '%s\n' "$MARK_SID" > "$R/.claude/.harness/current-session"
OUT=$(run_gate "$R" "$GATE_SID"); RSN=$(reason "$OUT")
if is_block "$OUT" && printf '%s' "$RSN" | grep -q "independent code review"; then
  ok "I7 redirected key without a review-log still BLOCKS"
else
  bad "I7 the redirect waved a session through without a review. out=[$OUT]"
fi
rm -rf "$R"

echo
echo "test-anchor-recovery: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
