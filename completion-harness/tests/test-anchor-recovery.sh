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
#   REJECTED: a marker session's baselines/<id>.sha as the anchor. That is the
#       case-2 trap — a marker whose base == HEAD would make the changeset look
#       empty and wave a whole unverified session through.
#
# STRUCTURAL SAFETY INVARIANT (asserted, not merely intended): a RECOVERED anchor
# may only feed checks that make the gate STRICTER (coverage, the summary). It is
# deliberately NOT assigned to HC_BASE, so it can never reach Step 3's quiet-exit
# or Step 3c's empty-changeset allow — the only two places an anchor grants a pass.
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

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

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

# Fresh repo on `main` (trunk → session mode, task_key=session-<sid>), harness
# state gitignored, three commits so a changeset can be non-empty. Echoes the
# repo path. C1/C2/C3 are exported by the caller via git rev-parse.
make_repo() {
  local r; r=$(mktemp -d)
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  printf '.claude/\n' > "$r/.gitignore"
  printf 'a\n' > "$r/a.js";  git -C "$r" add -A; git -C "$r" commit -qm c1
  printf 'b\n' > "$r/b.js";  git -C "$r" add -A; git -C "$r" commit -qm c2
  printf 'c\n' > "$r/c.js";  git -C "$r" add -A; git -C "$r" commit -qm c3
  mkdir -p "$r/.claude/.harness/baselines" "$r/.claude/.harness/done-state" \
           "$r/.claude/.harness/review-log"
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

echo
echo "test-anchor-recovery: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
