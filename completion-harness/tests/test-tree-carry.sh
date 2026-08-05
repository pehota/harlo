#!/bin/bash
#
# BEHAVIOURAL test — carrying verification across a TREE-IDENTICAL HEAD move.
#
# A HEAD move does not always change the code. `reset --soft` + recommit to
# reword a message, or a `pull --rebase` that replays the same patches, leaves
# every blob and every mode byte-identical. The gate used to demand a fresh
# independent review and a rewritten done-state for exactly that; a human would
# have pushed. Now Step 5 compares TREES and carries the verification when they
# are equal, and Step 8 keeps admitting the review-log the done-state anchors to.
#
# The guarantee is TREE EQUALITY, not ancestry — cases 2 and 3 pin that any real
# content change (a byte, or a mode) still blocks. Case 4 pins the regression the
# review_anchor_sha field exists to prevent: the /done run that FOLLOWS a carry
# must not re-block. Case 5 pins backward compatibility with done-states written
# before head_tree existed.
#
# Runs against the source-tree scripts; each case builds an isolated throwaway
# git repo. No install, no set -e.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
GATE="$SCRIPTS/done-gate.sh"
WRITER="$SCRIPTS/done-write-state.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-tree-carry =="

if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot build done-state fixtures"
  echo; echo "test-tree-carry: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

CLEANUP=()
cleanup() { for d in "${CLEANUP[@]}"; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null; done; }
trap cleanup EXIT

SID=carry

# mk_verified — a repo on trunk `main` (session mode, task_key=session-$SID)
# with a REAL changeset (base..HEAD touches a.js) and a green, HEAD-exact
# verification: baseline .sha at base, clean .dirty, a review-log attesting
# a.js, and a done-state carrying head_tree + review_anchor_sha exactly as the
# writer produces them. Sets REPO, BASE, HEAD0, TREE0, HDIR.
mk_verified() {
  REPO=$(mktemp -d 2>/dev/null); CLEANUP+=("$REPO")
  git -C "$REPO" init -q -b main 2>/dev/null
  git -C "$REPO" config user.email "test@example.com" >/dev/null 2>&1
  git -C "$REPO" config user.name  "Test" >/dev/null 2>&1
  printf '.claude/\n' > "$REPO/.gitignore"
  mkdir -p "$REPO/.claude"
  printf '{"trunk":"main","detected":{"test":"true"},"overrides":{},"baseline_snapshot":false}\n' \
    > "$REPO/.claude/done-config.json"
  printf 'a1\n' > "$REPO/a.js"
  printf 'b1\n' > "$REPO/b.js"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm base >/dev/null 2>&1
  BASE=$(git -C "$REPO" rev-parse HEAD)

  HDIR="$REPO/.claude/.harness"
  mkdir -p "$HDIR/baselines" "$HDIR/done-state" "$HDIR/review-log"
  printf '%s\n' "$BASE" > "$HDIR/baselines/$SID.sha"
  : > "$HDIR/baselines/$SID.dirty"
  printf '%s\n' "$SID" > "$HDIR/current-session"

  printf 'a2\n' > "$REPO/a.js"
  git -C "$REPO" add -A >/dev/null 2>&1
  git -C "$REPO" commit -qm "the work" >/dev/null 2>&1
  HEAD0=$(git -C "$REPO" rev-parse HEAD)
  TREE0=$(git -C "$REPO" rev-parse 'HEAD^{tree}')

  write_review_log "$HEAD0" "$HEAD0"
  write_done_state "$HEAD0" "$TREE0" "$HEAD0"
}

# write_review_log <basename_sha> <reviewed_sha> — attests a.js, no findings.
write_review_log() {
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["a.js"],"findings":[],"open_findings":0}\n' \
    "$2" > "$HDIR/review-log/$1.json"
}

# write_done_state <verified_sha> <head_tree|""> <review_anchor_sha|"">
# An empty head_tree/anchor omits the field — that is a LEGACY state.
write_done_state() {
  jq -n --arg sid "$SID" --arg sha "$1" --arg tree "$2" --arg anchor "$3" '
    {contract_version:1, session_id:$sid, verified_sha:$sha, tree_clean:true,
     dod:{sources:["base"], items:["tests green"]},
     tests:{exit_code:0, command:"t", output_tail:"ok"},
     task_checks:[{desc:"x", status:"passed"}], escalation:null}
    | (if $tree   != "" then .head_tree = $tree           else . end)
    | (if $anchor != "" then .review_anchor_sha = $anchor else . end)
  ' > "$HDIR/done-state/session-$SID.json"
}

run_gate() {
  printf '{"session_id":"%s","stop_hook_active":false}' "$SID" \
    | CLAUDE_PROJECT_DIR="$REPO" bash "$GATE" 2>/dev/null
}

# ===========================================================================
# 0. SANITY — the fixture as built must ALLOW, or nothing below means anything.
# ===========================================================================
mk_verified
OUT=$(run_gate)
if is_block "$OUT"; then
  bad "0 SANITY: the HEAD-exact verified fixture BLOCKed. out=$OUT"
else
  ok "0 SANITY: HEAD-exact verification allows"
fi

# ===========================================================================
# 1. MESSAGE-ONLY AMEND — new sha, identical tree. Must ALLOW with NO new
#    review-log written for the new HEAD.
# ===========================================================================
git -C "$REPO" commit -q --amend -m "the work, reworded" >/dev/null 2>&1
HEAD1=$(git -C "$REPO" rev-parse HEAD)
TREE1=$(git -C "$REPO" rev-parse 'HEAD^{tree}')
if [ "$HEAD1" != "$HEAD0" ] && [ "$TREE1" = "$TREE0" ]; then
  ok "1 setup: amend moved HEAD but the tree is identical"
else
  bad "1 setup broken (head $HEAD0->$HEAD1, tree $TREE0->$TREE1)"
fi
if [ -f "$HDIR/review-log/$HEAD1.json" ]; then
  bad "1 setup: a review-log for the new HEAD exists — the case would be vacuous"
fi
OUT=$(run_gate)
if is_block "$OUT"; then
  bad "1 message-only amend BLOCKed — a human would have pushed. out=$OUT"
else
  ok "1 message-only amend ALLOWs (verification carried, no new review-log)"
fi

# ===========================================================================
# 4. POST-CARRY /done — the regression review_anchor_sha exists to prevent.
#    After the carry above, run the REAL writer, then re-gate. The new
#    done-state sits at the new HEAD (so Step 5 takes the sha-EQUAL path, with
#    no carry), and there is still no HEAD-exact review-log: only the recorded
#    anchor keeps it green. Runs here so it reuses case 1's carried repo.
# ===========================================================================
PAYLOAD='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
WOUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" 2>&1)
WRC=$?
if [ "$WRC" -eq 0 ]; then
  ok "4 writer accepts the carried anchor as the validated review-log"
else
  bad "4 writer REFUSED after a carry (rc=$WRC): $WOUT"
fi
NEW_ANCHOR=$(jq -r '.review_anchor_sha // ""' "$HDIR/done-state/session-$SID.json" 2>/dev/null)
NEW_SHA=$(jq -r '.verified_sha // ""' "$HDIR/done-state/session-$SID.json" 2>/dev/null)
NEW_TREE=$(jq -r '.head_tree // ""' "$HDIR/done-state/session-$SID.json" 2>/dev/null)
if [ "$NEW_SHA" = "$HEAD1" ] && [ "$NEW_ANCHOR" = "$HEAD0" ] && [ "$NEW_TREE" = "$TREE1" ]; then
  ok "4 new done-state: verified_sha=HEAD, head_tree injected, anchor kept at the old log"
else
  bad "4 new done-state fields wrong (sha=$NEW_SHA anchor=$NEW_ANCHOR tree=$NEW_TREE)"
fi
OUT=$(run_gate)
if is_block "$OUT"; then
  bad "4 the /done run FOLLOWING a carry re-BLOCKed. out=$OUT"
else
  ok "4 post-carry /done does NOT re-block (anchor admitted on the sha-equal path)"
fi

# ===========================================================================
# 4b. FORGERY — head_tree / review_anchor_sha are writer-injected FACTS. A
#     payload that supplies them must not have them survive into the state.
# ===========================================================================
FORGED='{"head_tree":"'"$(printf '0%.0s' $(seq 40))"'","review_anchor_sha":"'"$(printf 'f%.0s' $(seq 40))"'","dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
printf '%s' "$FORGED" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" >/dev/null 2>&1
F_TREE=$(jq -r '.head_tree // ""' "$HDIR/done-state/session-$SID.json" 2>/dev/null)
F_ANCHOR=$(jq -r '.review_anchor_sha // ""' "$HDIR/done-state/session-$SID.json" 2>/dev/null)
# Assert EQUALITY with the anchor the writer must actually derive, not mere
# inequality with the forged value. "!= fff…f" is also satisfied by an EMPTY
# anchor or an unrelated one, so it would pass even if the facts were dropped
# rather than overwritten. At this fixture point HEAD is HEAD1, no HEAD-exact
# review-log exists for it, and the prior done-state (written by case 4) records
# head_tree=TREE1 with anchor=HEAD0 — so the writer's carry must re-derive
# exactly HEAD0.
if [ "$F_TREE" = "$TREE1" ] && [ "$F_ANCHOR" = "$HEAD0" ]; then
  ok "4b payload-supplied head_tree/review_anchor_sha are overwritten by the facts"
else
  bad "4b forged fields survived (tree=$F_TREE want=$TREE1; anchor=$F_ANCHOR want=$HEAD0)"
fi

# ===========================================================================
# 2. ONE BYTE CHANGED — different tree → must still BLOCK.
# ===========================================================================
mk_verified
printf 'a3\n' > "$REPO/a.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q --amend -m "the work" >/dev/null 2>&1
if [ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" = "$TREE0" ]; then
  bad "2 setup broken: the tree did not change"
fi
OUT=$(run_gate)
if is_block "$OUT"; then
  ok "2 a one-byte content change still BLOCKs"
else
  bad "2 a one-byte content change was carried — tree equality not enforced. out=$OUT"
fi

# ===========================================================================
# 3. MODE CHANGE — chmod +x on a tracked file is a TREE ENTRY change, so the
#    tree differs even though every blob is identical → must still BLOCK.
# ===========================================================================
mk_verified
chmod +x "$REPO/a.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q --amend -m "the work" >/dev/null 2>&1
if [ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" = "$TREE0" ]; then
  bad "3 setup broken: chmod did not change the tree (core.fileMode off?)"
else
  OUT=$(run_gate)
  if is_block "$OUT"; then
    ok "3 a mode-only change still BLOCKs (mode is part of the tree)"
  else
    bad "3 a mode-only change was carried. out=$OUT"
  fi
fi

# ===========================================================================
# 5. LEGACY DONE-STATE — written before head_tree existed. The carry must work
#    on the session that installs the fix, via the live recompute from
#    verified_sha, not one /done later.
# ===========================================================================
mk_verified
write_done_state "$HEAD0" "" ""                 # no head_tree, no anchor
git -C "$REPO" commit -q --amend -m "reworded again" >/dev/null 2>&1
HEAD5=$(git -C "$REPO" rev-parse HEAD)
if [ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" != "$TREE0" ]; then
  bad "5 setup broken: the amend changed the tree"
fi
if jq -e 'has("head_tree")' "$HDIR/done-state/session-$SID.json" >/dev/null 2>&1; then
  bad "5 setup broken: the legacy fixture still has head_tree"
fi
OUT=$(run_gate)
if is_block "$OUT"; then
  bad "5 legacy done-state (no head_tree) did not carry. out=$OUT"
else
  ok "5 legacy done-state carries via the live rev-parse recompute"
fi
# The WRITER must apply the same legacy recompute, or it refuses the very write
# the gate just accepted and the churn is back on the installing session.
WOUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" 2>&1)
WRC=$?
W_ANCHOR=$(jq -r '.review_anchor_sha // ""' "$HDIR/done-state/session-$SID.json" 2>/dev/null)
if [ "$WRC" -eq 0 ] && [ "$W_ANCHOR" = "$HEAD0" ]; then
  ok "5 writer applies the same legacy recompute (rc=0, anchor kept at the old log)"
else
  bad "5 writer/gate DIVERGE on a legacy state (rc=$WRC anchor=$W_ANCHOR): $WOUT"
fi

# 5b. …and the legacy state must still BLOCK on a real content change (the
#     recompute is a fallback, not a bypass).
mk_verified
write_done_state "$HEAD0" "" ""
printf 'a9\n' > "$REPO/a.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q --amend -m "the work" >/dev/null 2>&1
OUT=$(run_gate)
if is_block "$OUT"; then
  ok "5b legacy done-state still BLOCKs on a content change"
else
  bad "5b legacy recompute became a bypass. out=$OUT"
fi

# ===========================================================================
# 6. REAPER — hc_live_review_shas must keep the anchored log alive, or the next
#    SessionStart deletes it and the whole mechanism expires silently.
# ===========================================================================
mk_verified
git -C "$REPO" commit -q --amend -m "reworded" >/dev/null 2>&1
write_done_state "$(git -C "$REPO" rev-parse HEAD)" "$TREE0" "$HEAD0"
(
  # shellcheck source=/dev/null
  . "$SCRIPTS/harness-common.sh" 2>/dev/null
  PROJECT_DIR="$REPO"; HARNESS_DIR="$HDIR"
  hc_live_review_shas "$REPO" 2>/dev/null
) > "$REPO/.keep.out" 2>/dev/null
if grep -Fxq -- "$HEAD0" "$REPO/.keep.out" 2>/dev/null; then
  ok "6 the anchored (now-unreachable) review-log sha is in the keep-set"
else
  bad "6 anchored sha $HEAD0 NOT kept — the next SessionStart would reap it"
fi

# ===========================================================================
# 7. THE NEXT REAL COMMIT — the carry must not expire one commit later.
#
#    BASE -> A (a.js) -> tree-identical amend to B -> real commit C touching
#    ONLY b.js, with a fresh delta review-log attesting only b.js.
#
#    The amend orphaned log A: its sha is no longer an ancestor of C, so the
#    coverage chain's ancestry test cannot see it, and a.js — whose content NO
#    commit has touched since A reviewed it — falls into the gap. The writer
#    then refuses, demanding a pointless re-review of an unchanged file, and the
#    gate refuses the same changeset. Admitting the recorded anchor to the chain
#    (resolved at its OWN sha) fixes both.
#
#    7b is the negative control WITHOUT which 7 would also pass for a
#    self-validating implementation: if C had actually CHANGED a.js, the orphaned
#    anchor must NOT cover it.
# ===========================================================================
# write_log <basename_sha> <reviewed_sha> <files_json>
write_log() {
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[],"open_findings":0}\n' \
    "$2" "$3" > "$HDIR/review-log/$1.json"
}

mk_verified
git -C "$REPO" commit -q --amend -m "reworded" >/dev/null 2>&1   # A -> B, same tree
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" >/dev/null 2>&1
printf 'b2\n' > "$REPO/b.js"                                     # real commit C
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "C touches only b.js" >/dev/null 2>&1
C=$(git -C "$REPO" rev-parse HEAD)
write_log "$C" "$C" '["b.js"]'
if git -C "$REPO" merge-base --is-ancestor "$HEAD0" "$C" 2>/dev/null; then
  bad "7 setup: log A is still an ancestor of C — the case would be vacuous"
else
  ok "7 setup: the amend orphaned log A (not an ancestor of C)"
fi
if [ "$(git -C "$REPO" rev-parse "$HEAD0:a.js")" = "$(git -C "$REPO" rev-parse "$C:a.js")" ]; then
  ok "7 setup: a.js holds exactly the content log A attested"
else
  bad "7 setup: a.js content differs from what log A attested"
fi
WOUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" 2>&1)
WRC=$?
if [ "$WRC" -eq 0 ]; then
  ok "7 writer accepts at C: the orphaned anchor still covers the unchanged a.js"
else
  bad "7 writer REFUSED at C — the carry expired at the next real commit (rc=$WRC): $WOUT"
fi
if [ "$(jq -r '.review_anchor_sha // ""' "$HDIR/done-state/session-$SID.json")" = "$HEAD0" ]; then
  ok "7 the orphaned anchor is RECORDED, so the gate admits the same log"
else
  bad "7 anchor not recorded (got $(jq -r '.review_anchor_sha // ""' "$HDIR/done-state/session-$SID.json"), want $HEAD0)"
fi
OUT=$(run_gate)
if is_block "$OUT"; then
  bad "7 gate BLOCKed at C though the writer accepted — writer/gate DIVERGE. out=$OUT"
else
  ok "7 gate ALLOWs at C (writer and gate resolve the same candidate set)"
fi

# 7b. NEGATIVE CONTROL — C also CHANGES a.js. The orphaned anchor attested the
#     OLD content, so it must NOT cover it: blobs resolve at the anchor's own
#     sha, never at HEAD (which would self-validate every path it ever listed).
mk_verified
git -C "$REPO" commit -q --amend -m "reworded" >/dev/null 2>&1
printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" >/dev/null 2>&1
printf 'b2\n' > "$REPO/b.js"
printf 'a-CHANGED\n' > "$REPO/a.js"                              # C changes a.js too
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm "C touches b.js AND a.js" >/dev/null 2>&1
C=$(git -C "$REPO" rev-parse HEAD)
write_log "$C" "$C" '["b.js"]'                                   # still attests only b.js
WOUT=$(printf '%s' "$PAYLOAD" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITER" "$SID" 2>&1)
WRC=$?
if [ "$WRC" -ne 0 ] && printf '%s' "$WOUT" | grep -q 'a\.js'; then
  ok "7b writer REFUSES when C actually changed a.js (anchor cannot self-validate)"
else
  bad "7b writer accepted a CHANGED a.js on the orphaned anchor (rc=$WRC): $WOUT"
fi
OUT=$(run_gate)
if is_block "$OUT"; then
  ok "7b gate BLOCKs the changed-but-unattested a.js"
else
  bad "7b gate ALLOWed a changed, unattested a.js. out=$OUT"
fi

# ===========================================================================
# 8. hc_state PARITY — the harness must not contradict itself.
#
#    hc_state classified the S2-vs-S5 boundary by SHA equality alone, so after a
#    tree-identical HEAD move the Stop gate ALLOWed (Step 5 carried) while the
#    next SessionStart still classified S2 and steered "run /done" for a
#    changeset already verified. The classifier now applies the SAME tree test
#    the gate does — including the legacy recompute — and resolves the SAME
#    review-log candidate set, so the two agree on every carried state.
#
#    8b/8c pin the direction: the widening must not turn a real content change,
#    or a genuinely unverified HEAD, into a silent S5.
# ===========================================================================
hc_state_of() {  # echoes HC_STATE for the current $REPO fixture
  (
    unset HC_MODE HC_BASE HC_TASK_KEY HC_STATE HARNESS_DIR HC_CONTRACTS_DIR PROJECT_DIR
    export CLAUDE_PROJECT_DIR="$REPO"
    # shellcheck source=/dev/null
    . "$SCRIPTS/harness-common.sh" 2>/dev/null
    hc_state "$SID" >/dev/null 2>&1
    printf '%s' "$HC_STATE"
  )
}

# 8 — tree-identical amend: gate allows, so hc_state must be S5 (not S2).
mk_verified
git -C "$REPO" commit -q --amend -m "reworded for parity" >/dev/null 2>&1
OUT=$(run_gate)
ST=$(hc_state_of)
if is_block "$OUT"; then
  bad "8 setup: the gate BLOCKed the tree-identical amend, so parity is untestable"
elif [ "$ST" = "S5" ]; then
  ok "8 hc_state agrees with the gate after a tree-identical move (S5, allow)"
else
  bad "8 harness contradicts itself: gate ALLOWs but hc_state=$ST steers /done"
fi

# 8b — LEGACY done-state (no head_tree): the recompute must apply here too, or
#      the classifier and the gate diverge on exactly the states case 5 covers.
mk_verified
write_done_state "$HEAD0" "" ""
git -C "$REPO" commit -q --amend -m "reworded legacy" >/dev/null 2>&1
OUT=$(run_gate)
ST=$(hc_state_of)
if is_block "$OUT"; then
  bad "8b setup: the gate BLOCKed the legacy carry"
elif [ "$ST" = "S5" ]; then
  ok "8b hc_state applies the same legacy recompute as the gate (S5)"
else
  bad "8b legacy carry: gate ALLOWs but hc_state=$ST"
fi

# 8c — NEGATIVE CONTROL: a real content change must still be S2, and the gate
#      must still block. The tree test is a carry, never a bypass.
mk_verified
printf 'a-real-change\n' > "$REPO/a.js"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -q --amend -m "the work" >/dev/null 2>&1
OUT=$(run_gate)
ST=$(hc_state_of)
if is_block "$OUT" && [ "$ST" = "S2" ]; then
  ok "8c content change: gate BLOCKs and hc_state stays S2 (no bypass)"
else
  bad "8c content change leaked through (gate blocked=$(is_block "$OUT" && echo yes || echo no), hc_state=$ST)"
fi

echo
echo "test-tree-carry: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
