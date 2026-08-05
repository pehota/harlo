#!/bin/bash
#
# Integration test — the REAL producer/consumer chain.
#
# The unit tests exercise each script in isolation with hand-crafted state.
# This test instead drives the ACTUAL scripts in sequence against one throwaway
# git repo with a CONSISTENT session_id and CLAUDE_PROJECT_DIR, so the format
# baseline-snapshot.sh PRODUCES is the format done-gate.sh CONSUMES, and the
# done-state done-write-state.sh writes is the one the gate reads back.
#
# Scripts under test: the BUNDLE copies (source of truth). The installed copies
# are verified byte-identical to these by the caller's diff check.

BUNDLE="$(cd "$(dirname "$0")/../scripts" && pwd)"
BASELINE="$BUNDLE/baseline-snapshot.sh"
GATE="$BUNDLE/done-gate.sh"
WRITE="$BUNDLE/done-write-state.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

# Classify a gate run by its stdout: block if stdout carries decision:"block",
# else allow. Exit code must be 0 either way (crash otherwise).
# gate_is <block|allow> <stdin_json>
gate_is() {
  local expect="$1" stdin_json="$2" out code is_block=0
  out=$(printf '%s' "$stdin_json" | CLAUDE_PROJECT_DIR="$REPO" bash "$GATE" 2>/dev/null)
  code=$?
  [ "$code" -eq 0 ] || { echo "  (gate crashed: exit $code)"; return 1; }
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 && is_block=1
  if [ "$expect" = "block" ]; then
    [ "$is_block" -eq 1 ] && return 0
    echo "  (expected block, got: ${out:-<empty allow>})"; return 1
  else
    { [ "$is_block" -eq 0 ] && [ -z "$out" ]; } && return 0
    echo "  (expected allow, got: $out)"; return 1
  fi
}

SID="S"

echo "== test-chain (integration: baseline-snapshot -> gate -> write-state -> gate) =="

# --- throwaway repo mirroring the trial fixture -----------------------------
REPO=$(mktemp -d)
trap 'rm -rf "$REPO"' EXIT
git -C "$REPO" init -q
git -C "$REPO" config user.email "test@test.local"
git -C "$REPO" config user.name "test"
# gitignore .claude/ so the harness's own writes never dirty the tree — commit
# it in the INITIAL commit (mirror test-gate.sh). Without this, steps 2 & 6
# ALLOW expectations flip to BLOCK.
printf '.claude/\n' > "$REPO/.gitignore"
cat > "$REPO/package.json" <<'JSON'
{
  "name": "chain-fixture",
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "test": "node --test",
    "start": "node src/index.js"
  }
}
JSON
git -C "$REPO" add -A
git -C "$REPO" commit -qm "initial"
INITIAL_SHA=$(git -C "$REPO" rev-parse HEAD)

# ============================================================================
# Step 1 — baseline-snapshot.sh records the baseline SHA
# ============================================================================
printf '{"session_id":"%s"}' "$SID" | CLAUDE_PROJECT_DIR="$REPO" bash "$BASELINE" >/dev/null 2>&1
SHA_FILE="$REPO/.claude/.harness/baselines/${SID}.sha"
if [ -f "$SHA_FILE" ]; then
  ok "step1: baseline .sha written"
else
  bad "step1: baseline .sha NOT written at $SHA_FILE"
fi
RECORDED=$(cat "$SHA_FILE" 2>/dev/null)
if [ "$RECORDED" = "$INITIAL_SHA" ]; then
  ok "step1: recorded baseline == git rev-parse HEAD (format matches gate's reader)"
else
  bad "step1: baseline '$RECORDED' != HEAD '$INITIAL_SHA'"
fi

# ============================================================================
# Step 2 — gate at HEAD==baseline, clean tree → ALLOW
# ============================================================================
if gate_is allow "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"; then
  ok "step2: gate ALLOWs at HEAD==baseline, clean tree"
else
  bad "step2: gate did not allow at baseline"
fi

# ============================================================================
# Step 3 — make a change + commit (advance HEAD past the baseline)
# ============================================================================
echo "export const x = 1;" > "$REPO/change.js"
git -C "$REPO" add -A
git -C "$REPO" commit -qm "advance HEAD"
NEW_SHA=$(git -C "$REPO" rev-parse HEAD)
if [ "$NEW_SHA" != "$INITIAL_SHA" ]; then
  ok "step3: HEAD advanced ($NEW_SHA)"
else
  bad "step3: HEAD did not advance"
fi

# ============================================================================
# Step 4 — gate after commit, no done-state → BLOCK
# ============================================================================
if gate_is block "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"; then
  ok "step4: gate BLOCKs after commit with no done-state"
else
  bad "step4: gate did not block after commit"
fi

# ============================================================================
# Seed an independent review-log for the current HEAD — mirrors what the Step-4
# review subagent produces in a real /done. done-write-state.sh (and the gate)
# refuse a green payload unless a review-log for HEAD exists with
# open_findings == 0, so without this the write below would correctly fail.
# files_reviewed covers the changeset (baseline..HEAD == change.js) so the
# STRUCTURAL coverage check passes too — a real Step-4 log attests it.
# ============================================================================
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)
mkdir -p "$REPO/.claude/.harness/review-log"
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["change.js"],"findings":[],"open_findings":0}\n' "$HEAD_SHA" \
  > "$REPO/.claude/.harness/review-log/$HEAD_SHA.json"

# ============================================================================
# Step 5 — done-write-state.sh with a GREEN payload → writes done-state
# (Fix-2 refuses non-green payloads, so the payload must be genuinely green.)
# ============================================================================
GREEN='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok","newly_red":[],"pre_existing_red":[]},"app_started":true,"review":{"findings":1,"addressed":1},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
WROTE=$(printf '%s' "$GREEN" | CLAUDE_PROJECT_DIR="$REPO" bash "$WRITE" "$SID" 2>&1)
RC=$?
# Done-state is now keyed by HC_TASK_KEY. This fixture's repo is on `main` (its
# trunk) → session mode → task_key = "session-<session_id>".
DONE_STATE="$REPO/.claude/.harness/done-state/session-${SID}.json"
if [ "$RC" -eq 0 ] && [ -f "$DONE_STATE" ]; then
  ok "step5: green payload wrote done-state"
else
  bad "step5: done-state not written (rc=$RC, out=$WROTE)"
fi
if jq -e --arg s "$NEW_SHA" '.verified_sha == $s and .tree_clean == true' "$DONE_STATE" >/dev/null 2>&1; then
  ok "step5: done-state carries live verified_sha==HEAD + tree_clean"
else
  bad "step5: done-state git facts wrong"
fi

# ============================================================================
# Step 6 — gate with matching green done-state → ALLOW
# ============================================================================
if gate_is allow "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"; then
  ok "step6: gate ALLOWs with matching green done-state"
else
  bad "step6: gate did not allow with green done-state"
fi

echo
echo "test-chain: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
