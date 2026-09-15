#!/bin/bash
#
# Tests for the CLAIM-DRIVEN Stop gate and its three sibling hooks:
# dod-complete-task.sh (arms the latch), dod-user-turn.sh (UserPromptSubmit —
# reminder ONLY; it must never touch the latch) and lib-log.sh (the
# observe-only decision log).
#
# THE MECHANISM UNDER TEST. dod-gate.sh is SILENT until the agent claims it is
# finished. The latch task-dod/claim-<task_key> is that claim. The gate's seven
# steps, each with a case below:
#   1  no latch                                   → silent (exit 0, no stdout)
#   2  latched, no contract and no result         → block dod-no-contract
#   3  latched, no result for HEAD                → block dod-no-verify
#   4  latched, malformed result                  → block dod-no-verify
#   5  latched, result with failing requirements  → block dod-verify-failed
#   6  verified at HEAD, product dirt in the tree → block dod-uncommitted
#   7  covered                                    → disarm, archive, allow
#
# THE COVERED PATH IS THE ONLY DISARM. `UserPromptSubmit` used to clear the
# latch on the theory that it means "the user took the turn back". It does not:
# it also fires on subagent hand-backs, background-task notifications and
# cross-session messages, so that disarm was an AGENT-reachable release of the
# gate. It is gone, and this suite asserts it stays gone.
#
# THE ASYMMETRY RULE is what the whole design rests on and what most of the
# rest of this suite attacks: an AGENT-authored signal may only make the gate
# STRICTER. Arming the latch must clear NOTHING; skipping it must buy NOTHING;
# and neither an agent-writable config layer nor an agent-writable baseline
# file may talk the classifier out of seeing the changeset.
#
# Runs against the source-tree scripts (dod/scripts), resolved relative to this
# test — no install needed. PASS/FAIL family (ok/bad/eq), matching siblings.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$ROOT/scripts"

GATE="$SCRIPTS/dod-gate.sh"
CLAIM="$SCRIPTS/dod-complete-task.sh"
USER_TURN="$SCRIPTS/dod-user-turn.sh"
WRITE="$SCRIPTS/dod-write.sh"
STUB="$SCRIPTS/dod-stub-done.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

export CLAUDE_PLUGIN_ROOT="$ROOT"

echo "== test-dod-claim =="

# ---------------------------------------------------------------------------
# Invocation helpers.
# ---------------------------------------------------------------------------

is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# make_repo [mode] — tidy fixture repo + the task-dod state dirs.
make_repo() {
  local r; r=$(hc__test_make_repo "$1")
  mkdir -p "$r/.claude/.harness/task-dod/archive" "$r/.claude/.harness/task-dod/verified"
  printf '%s' "$r"
}

# run_gate <repo> <session_id> [stop_hook_active] — sets G_OUT and G_RC.
# Every gate call in this suite goes through here so the fail-safe invariants
# (exit 0; stdout is either empty or valid JSON) can be asserted on ALL of
# them, not only the cases that bother to check.
G_OUT=""; G_RC=0
run_gate() {
  G_OUT=$(printf '{"session_id":"%s","hook_event_name":"Stop","stop_hook_active":%s}' \
            "$2" "${3:-false}" | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null)
  G_RC=$?
  GATE_OUTPUTS="$GATE_OUTPUTS
$G_OUT"
  if [ "$G_RC" -ne 0 ]; then
    FAILSAFE_RC_VIOLATIONS=$((FAILSAFE_RC_VIOLATIONS + 1))
  fi
  if [ -n "$G_OUT" ] && ! printf '%s' "$G_OUT" | jq empty >/dev/null 2>&1; then
    FAILSAFE_JSON_VIOLATIONS=$((FAILSAFE_JSON_VIOLATIONS + 1))
  fi
  printf '%s' "$G_OUT"
}
GATE_OUTPUTS=""
FAILSAFE_RC_VIOLATIONS=0
FAILSAFE_JSON_VIOLATIONS=0

# arm_claim <repo> <session_id> — the REAL claim script, never a hand-written
# latch file: writer and gate must agree on the task key or this suite is a lie.
arm_claim() { CLAUDE_PROJECT_DIR="$1" bash "$CLAIM" "$2" >/dev/null 2>&1; }

# run_user_turn <repo> <session_id> [prompt] — the UserPromptSubmit hook;
# echoes stdout. The prompt defaults to an ordinary human turn; pass one of the
# harness wrapper shapes to exercise the automated-turn predicate.
REMINDER_OUTPUTS=""
run_user_turn() {
  local out
  out=$(jq -nc --arg s "$2" --arg p "${3:-next}" \
          '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:$p}' \
          | CLAUDE_PROJECT_DIR="$1" bash "$USER_TURN" 2>/dev/null)
  REMINDER_OUTPUTS="$REMINDER_OUTPUTS
$out"
  printf '%s' "$out"
}

latch()      { printf '%s/.claude/.harness/task-dod/claim-%s' "$1" "$2"; }
dodfile()    { printf '%s/.claude/.harness/task-dod/%s.json' "$1" "$2"; }
lastblock()  { cat "$1/.claude/.harness/last-block/dod-$2" 2>/dev/null | tr -d '\r\n'; }

# write_dod <repo> <session_id> — a one-requirement contract under the key the
# repo's current branch implies.
write_dod() {
  printf '{"__session_id":"%s","created_at":"2026-01-01T00:00:00Z","blast_radius":{"tier":"low","reason":"r"},"requirements":[{"text":"does X","origin":"prompt","added_at":"t"}]}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$WRITE" >/dev/null 2>&1
}

# classify_changeset / classify_tree <repo> <session_id> — call the classifier
# directly (source the real libs, resolve, ask). Exit 0 == product surface
# present. Used where the black-box hooks would hide WHICH half fired.
classify_changeset() {
  CLAUDE_PROJECT_DIR="$1" bash -c '
    . "$1/scripts/harness-common.sh" 2>/dev/null
    . "$1/scripts/lib-classify.sh" 2>/dev/null
    hc_resolve "$2" 2>/dev/null
    dod_changeset_has_product "$2"
  ' _ "$ROOT" "$2"
}
classify_tree() {
  CLAUDE_PROJECT_DIR="$1" bash -c '
    . "$1/scripts/harness-common.sh" 2>/dev/null
    . "$1/scripts/lib-classify.sh" 2>/dev/null
    hc_resolve "$2" 2>/dev/null
    dod_tree_has_product "$2"
  ' _ "$ROOT" "$2"
}

# ===========================================================================
# GATE STEP 1 — no latch → SILENT. The most important case in the suite: this
# is the entire reason the gate stopped blocking at the end of every turn.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g1
OUT=$(run_gate "$R" g1)
[ -z "$OUT" ] && ok "step 1: no claim latch → gate silent, even with an unverified contract and product work" \
  || bad "step 1: no claim latch → gate silent" "$OUT"
eq "step 1: gate exits 0 with no latch" "0" "$G_RC"

# ===========================================================================
# GATE STEP 2 — latched, no contract, no result → block dod-no-contract.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
arm_claim "$R" g2
OUT=$(run_gate "$R" g2)
is_block "$OUT" && ok "step 2: latched with no contract and no result → blocks" \
  || bad "step 2: latched, no contract → blocks" "$OUT"
eq "step 2: block category" "dod-no-contract" "$(lastblock "$R" br-feature-x)"
printf '%s' "$OUT" | jq -e '.reason | test("Definition of Done")' >/dev/null 2>&1 \
  && ok "step 2: reason says no Definition of Done was ever recorded" \
  || bad "step 2: reason names the missing contract" "$OUT"

# ===========================================================================
# GATE STEP 3 — latched, contract present, no result for HEAD → dod-no-verify.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g3
arm_claim "$R" g3
OUT=$(run_gate "$R" g3)
is_block "$OUT" && ok "step 3: latched, contract present, no verification result → blocks" \
  || bad "step 3: latched, no verification result → blocks" "$OUT"
eq "step 3: block category" "dod-no-verify" "$(lastblock "$R" br-feature-x)"

# ===========================================================================
# GATE STEP 4 — malformed verification result → dod-no-verify.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g4
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
printf 'not json at all' > "$R/.claude/.harness/task-dod/verified/br-feature-x-${HEAD_SHA}.json"
arm_claim "$R" g4
OUT=$(run_gate "$R" g4)
is_block "$OUT" && ok "step 4: malformed verification result → blocks" \
  || bad "step 4: malformed verification result → blocks" "$OUT"
eq "step 4: block category" "dod-no-verify" "$(lastblock "$R" br-feature-x)"

# ===========================================================================
# GATE STEP 5 — result with failing requirements → dod-verify-failed.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g5
HEAD_SHA=$(git -C "$R" rev-parse HEAD)
printf '{"task_key":"br-feature-x","verified_sha":"%s","checked_at":"t","results":[{"requirement_index":0,"status":"fail","evidence":"broke"}]}' "$HEAD_SHA" \
  > "$R/.claude/.harness/task-dod/verified/br-feature-x-${HEAD_SHA}.json"
arm_claim "$R" g5
OUT=$(run_gate "$R" g5)
is_block "$OUT" && ok "step 5: verification result with a failing requirement → blocks" \
  || bad "step 5: failing requirement → blocks" "$OUT"
eq "step 5: block category" "dod-verify-failed" "$(lastblock "$R" br-feature-x)"

# ===========================================================================
# GATE STEP 6 — verified at HEAD but the tree still carries product dirt.
# Verified-at-HEAD alone is NOT coverage: uncommitted product changes are by
# construction changes the verification at HEAD could not have seen.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g6
CLAUDE_PROJECT_DIR="$R" bash "$STUB" g6 >/dev/null 2>&1
echo "uncommitted product edit" > "$R/later.py"
arm_claim "$R" g6
OUT=$(run_gate "$R" g6)
is_block "$OUT" && ok "step 6: verified at HEAD but product dirt in the tree → blocks" \
  || bad "step 6: uncommitted product dirt → blocks" "$OUT"
eq "step 6: block category" "dod-uncommitted" "$(lastblock "$R" br-feature-x)"
[ -f "$(latch "$R" br-feature-x)" ] \
  && ok "step 6: a BLOCK leaves the latch armed (only the covered path disarms)" \
  || bad "step 6: latch still armed after a block"
# artifact-only dirt on top of the same state must NOT block — the classifier
# is what distinguishes them, not the mere fact the tree is dirty.
rm -f "$R/later.py"
mkdir -p "$R/docs"; echo "notes" > "$R/docs/notes.md"
OUT=$(run_gate "$R" g6)
[ -z "$OUT" ] && ok "step 6: artifact-only tree dirt (docs/**) → still allowed" \
  || bad "step 6: artifact-only dirt allowed" "$OUT"

# ===========================================================================
# GATE STEP 6 — a RENAME OUT OF PRODUCT SURFACE. `git mv src/prod.py
# docs/prod.py` produces the single porcelain line
# "R  src/prod.py -> docs/prod.py". Classifying that on the DESTINATION alone
# matches docs/** and reads as no product change at all — so verify at HEAD,
# move production code into docs/, and the gate ALLOWED with uncommitted
# product code out of sight. Both sides of a rename must count.
# ===========================================================================
R=$(make_repo task)
mkdir -p "$R/src" "$R/docs"
echo "code" > "$R/src/prod.py"; echo "notes" > "$R/docs/a.md"
git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g6r
CLAUDE_PROJECT_DIR="$R" bash "$STUB" g6r >/dev/null 2>&1
git -C "$R" mv src/prod.py docs/prod.py
eq "rename: porcelain really does report one line with both sides" \
   "R  src/prod.py -> docs/prod.py" "$(git -C "$R" status --porcelain | head -1)"
classify_tree "$R" g6r \
  && ok "rename: product → artifact move is seen as product-surface tree dirt" \
  || bad "rename: product → artifact move missed by the classifier" "no product seen"
arm_claim "$R" g6r
OUT=$(run_gate "$R" g6r)
is_block "$OUT" \
  && ok "rename: verified at HEAD, then a product file moved into docs/ → blocks" \
  || bad "rename: git mv of product into docs/ blocks" "$OUT"
eq "rename: block category" "dod-uncommitted" "$(lastblock "$R" br-feature-x)"

# Control, in its own repo (a block leaves the latch armed and HEAD must not
# move): an artifact → artifact rename is still artifact-only and still allows.
R=$(make_repo task)
mkdir -p "$R/docs"; echo "notes" > "$R/docs/a.md"
git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g6s
CLAUDE_PROJECT_DIR="$R" bash "$STUB" g6s >/dev/null 2>&1
git -C "$R" mv docs/a.md docs/b.md
arm_claim "$R" g6s
OUT=$(run_gate "$R" g6s)
[ -z "$OUT" ] && ok "rename: artifact → artifact move (docs/a.md → docs/b.md) → still allowed" \
  || bad "rename: artifact-only move allowed" "$OUT"

# ===========================================================================
# GATE STEP 7 — covered → disarm, archive at HEAD, allow.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" g7
CLAUDE_PROJECT_DIR="$R" bash "$STUB" g7 >/dev/null 2>&1
SHA=$(git -C "$R" rev-parse HEAD)
arm_claim "$R" g7
OUT=$(run_gate "$R" g7)
[ -z "$OUT" ] && ok "step 7: covered → allows (empty stdout)" || bad "step 7: covered allows" "$OUT"
eq "step 7: covered path exits 0" "0" "$G_RC"
[ ! -f "$(latch "$R" br-feature-x)" ] \
  && ok "step 7: the gate DISARMS the latch on the covered path" \
  || bad "step 7: latch disarmed on the covered path"
[ -f "$R/.claude/.harness/task-dod/archive/$SHA.json" ] \
  && ok "step 7: contract archived at HEAD_SHA" || bad "step 7: contract archived at HEAD_SHA"
[ ! -f "$(dodfile "$R" br-feature-x)" ] \
  && ok "step 7: no live contract remains after archiving" || bad "step 7: live contract removed"
# ...and the very next Stop is silent again (step 1), not a re-block.
OUT=$(run_gate "$R" g7)
[ -z "$OUT" ] && ok "step 7: the Stop immediately after coverage is silent (latch is gone)" \
  || bad "step 7: post-coverage Stop silent" "$OUT"

# ===========================================================================
# ASYMMETRY — arming clears NOTHING.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" a1
arm_claim "$R" a1
OUT=$(run_gate "$R" a1)
CAT1=$(lastblock "$R" br-feature-x)
is_block "$OUT" && ok "asymmetry: a claim on an already-failing state blocks" \
  || bad "asymmetry: claim on failing state blocks" "$OUT"
# Re-claiming is the obvious exploit: run it again and demand the SAME verdict.
arm_claim "$R" a1
OUT=$(run_gate "$R" a1)
CAT2=$(lastblock "$R" br-feature-x)
is_block "$OUT" && ok "asymmetry: re-claiming does not clear the block" \
  || bad "asymmetry: re-claiming does not clear the block" "$OUT"
eq "asymmetry: the block category is unchanged by claiming" "$CAT1" "$CAT2"
[ -z "$(ls "$R/.claude/.harness/task-dod/verified" 2>/dev/null)" ] \
  && ok "asymmetry: claiming wrote no verification result" \
  || bad "asymmetry: claim must not write a verification result"
[ -f "$(dodfile "$R" br-feature-x)" ] \
  && ok "asymmetry: claiming did not archive or remove the live contract" \
  || bad "asymmetry: live contract untouched by a claim"

# ===========================================================================
# ASYMMETRY — skipping the claim buys NOTHING. No latch means the Stop gate is
# quiet, but the user-turn reminder is not.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
OUT=$(run_gate "$R" a2)
[ -z "$OUT" ] && ok "asymmetry: no claim → Stop quiet" || bad "asymmetry: no claim → Stop quiet" "$OUT"
OUT=$(run_user_turn "$R" a2)
[ -n "$OUT" ] && ok "asymmetry: no claim, uncovered product work → the user-turn reminder still fires" \
  || bad "asymmetry: reminder fires without a claim" "(empty)"
printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"' >/dev/null 2>&1 \
  && ok "asymmetry: reminder is a well-formed UserPromptSubmit payload" \
  || bad "asymmetry: reminder payload shape" "$OUT"

# ===========================================================================
# LATCH LIFECYCLE — armed by the claim, cleared by the GATE'S COVERED PATH and
# by nothing else. A UserPromptSubmit turn (human or automated) must leave it
# exactly where it was: relaxing the gate on a prompt event is precisely the
# asymmetry violation this suite exists to catch.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" l1
[ ! -f "$(latch "$R" br-feature-x)" ] && ok "lifecycle: no latch before the claim" \
  || bad "lifecycle: no latch before the claim"
arm_claim "$R" l1
[ -f "$(latch "$R" br-feature-x)" ] && ok "lifecycle: dod-complete-task.sh arms the latch" \
  || bad "lifecycle: claim arms the latch"

# (a) an ordinary HUMAN turn must not clear it.
run_user_turn "$R" l1 >/dev/null
[ -f "$(latch "$R" br-feature-x)" ] \
  && ok "lifecycle: the latch SURVIVES a UserPromptSubmit (human turn)" \
  || bad "lifecycle: latch survives a human user turn"

# (b) neither may an AUTOMATED turn — the hole that made the disarm a bypass.
for AUTO_P in '<agent-message from="abc">hand-back</agent-message>' \
              '<task-notification><task-id>x</task-id></task-notification>' \
              '<cross-session-message from="s2">hi</cross-session-message>' \
              'Another Claude session sent a message: hello'; do
  run_user_turn "$R" l1 "$AUTO_P" >/dev/null
done
[ -f "$(latch "$R" br-feature-x)" ] \
  && ok "lifecycle: the latch SURVIVES every automated-turn payload" \
  || bad "lifecycle: latch survives automated turns"

# (c) with the latch still armed the gate still blocks — it was never released.
OUT=$(run_gate "$R" l1)
is_block "$OUT" \
  && ok "lifecycle: the gate still blocks after those turns (nothing relaxed it)" \
  || bad "lifecycle: gate still blocks after user turns" "$OUT"

# (d) ONLY the covered path clears it.
CLAUDE_PROJECT_DIR="$R" bash "$STUB" l1 >/dev/null 2>&1
OUT=$(run_gate "$R" l1)
[ -z "$OUT" ] && ok "lifecycle: the covered path allows" || bad "lifecycle: covered path allows" "$OUT"
[ ! -f "$(latch "$R" br-feature-x)" ] \
  && ok "lifecycle: the gate's covered path is the ONLY thing that clears the latch" \
  || bad "lifecycle: covered path clears the latch"
OUT=$(run_gate "$R" l1)
[ -z "$OUT" ] && ok "lifecycle: after the disarm the gate is silent again" \
  || bad "lifecycle: silent after disarm" "$OUT"

# ===========================================================================
# AUTOMATED-TURN PREDICATE — the reminder is silent on every known harness
# wrapper, and FAILS TOWARD FIRING on anything it does not recognise. That
# direction is mandatory: a missed automated turn costs one extra line of
# context, a missed HUMAN turn costs the reminder entirely.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
# Baseline: this changeset genuinely warrants a reminder on a human turn.
OUT=$(run_user_turn "$R" q1 "please continue")
[ -n "$OUT" ] && ok "automated: an ordinary human prompt still gets the reminder" \
  || bad "automated: human prompt gets the reminder" "(empty)"

# One case per known wrapper shape.
OUT=$(run_user_turn "$R" q1 '<agent-message from="a3c4be23cdd46d5a0">
[Subagent hand-back] report text
</agent-message>')
[ -z "$OUT" ] && ok "automated: <agent-message ...> (subagent hand-back) → silent" \
  || bad "automated: agent-message silent" "$OUT"
OUT=$(run_user_turn "$R" q1 '<task-notification>
<task-id>a3c4</task-id>
</task-notification>')
[ -z "$OUT" ] && ok "automated: <task-notification> (background task) → silent" \
  || bad "automated: task-notification silent" "$OUT"
OUT=$(run_user_turn "$R" q1 '<cross-session-message from="other">peer</cross-session-message>')
[ -z "$OUT" ] && ok "automated: <cross-session-message ...> (peer session) → silent" \
  || bad "automated: cross-session-message silent" "$OUT"
OUT=$(run_user_turn "$R" q1 'Another Claude session sent a message: look at this')
[ -z "$OUT" ] && ok "automated: 'Another Claude session sent a message:' → silent" \
  || bad "automated: plain peer-message form silent" "$OUT"
# Leading whitespace must not defeat the match.
OUT=$(run_user_turn "$R" q1 '
   <task-notification><task-id>a</task-id></task-notification>')
[ -z "$OUT" ] && ok "automated: leading whitespace before the wrapper → still silent" \
  || bad "automated: lenient leading-whitespace match" "$OUT"
# FAIL TOWARD FIRING: an UNRECOGNISED wrapper is treated as a human turn.
OUT=$(run_user_turn "$R" q1 '<some-future-wrapper>text</some-future-wrapper>')
[ -n "$OUT" ] && ok "automated: an UNRECOGNISED wrapper still fires (fail toward firing)" \
  || bad "automated: unrecognised wrapper must still fire" "(empty)"
# A wrapper marker that merely APPEARS mid-prompt is a human turn quoting it.
OUT=$(run_user_turn "$R" q1 'see this: <task-notification> — what does it mean?')
[ -n "$OUT" ] && ok "automated: a marker mid-prompt is a human quoting it → still fires" \
  || bad "automated: mid-prompt marker must still fire" "(empty)"
# The skip is recorded in the decision log, so the human:automated ratio is
# measurable from dod-log/ rather than guessed at.
run_user_turn "$R" q1 '<task-notification><task-id>b</task-id></task-notification>' >/dev/null
grep -qF 'quiet:automated-turn' "$(find "$R/.claude/.harness/dod-log" -maxdepth 1 -name '*.jsonl' 2>/dev/null | head -1)" 2>/dev/null \
  && ok "automated: the skip is recorded as quiet:automated-turn in the decision log" \
  || bad "automated: skip recorded in the decision log"

# ===========================================================================
# REMINDER — no dedup marker, deliberately. Three identical turns, three
# reminders. A once-per-task nudge is exactly the thing an agent can outlast.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
N=0
for _ in 1 2 3; do
  OUT=$(run_user_turn "$R" r1)
  [ -n "$OUT" ] && N=$((N + 1))
done
eq "reminder: fires on all 3 turns over an unchanged, unverified changeset (no dedup)" "3" "$N"
printf '%s' "$OUT" | grep -qF '"decision":"block"' \
  && bad "reminder: must never emit a block decision" "$OUT" \
  || ok "reminder: never emits a block decision (UserPromptSubmit cannot block)"
# ...and it goes quiet once the changeset is genuinely covered.
write_dod "$R" r1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" r1 >/dev/null 2>&1
OUT=$(run_user_turn "$R" r1)
[ -z "$OUT" ] && ok "reminder: silent once a verification result covers HEAD and the tree is clean" \
  || bad "reminder: silent when covered" "$OUT"

# ===========================================================================
# DECISION LOG — observe-only. It must record EVERY terminal path (including
# the silent ones, which are the paths that were previously unobservable) and
# must be incapable of changing what the gate decides or prints.
# ===========================================================================
LOGLIB="$SCRIPTS/lib-log.sh"
[ -f "$LOGLIB" ] && ok "log: lib-log.sh ships" || bad "log: lib-log.sh ships"
[ -f "$SCRIPTS/dod-task-log.sh" ] \
  && bad "log: the TaskCompleted audit script is gone" "dod-task-log.sh still present" \
  || ok "log: the TaskCompleted audit script is gone"
grep -qF 'TaskCompleted' "$ROOT/hooks/hooks.json" 2>/dev/null \
  && bad "log: TaskCompleted is unregistered" "$(grep -F TaskCompleted "$ROOT/hooks/hooks.json")" \
  || ok "log: TaskCompleted is unregistered"

logfile() { find "$1/.claude/.harness/dod-log" -maxdepth 1 -name '*.jsonl' 2>/dev/null | head -1; }
logdec()  { jq -r '.decision' "$(logfile "$1")" 2>/dev/null; }

# A SILENT gate invocation still leaves a record — the whole point.
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
OUT=$(run_gate "$R" d1)
eq "log: a silent gate invocation stays silent" "" "$OUT"
LF=$(logfile "$R")
[ -n "$LF" ] && ok "log: a silent gate invocation still writes a record" \
  || bad "log: silent gate invocation writes a record" "(no jsonl)"
printf '%s' "$(logdec "$R")" | grep -q '^silent:no-claim' \
  && ok "log: the silent no-claim exit is recorded as such" \
  || bad "log: no-claim exit recorded" "$(logdec "$R")"
# One JSON object per line, carrying the full record shape.
eq "log: the record is one valid JSON object per line" "1" \
  "$(jq -s 'length' "$LF" 2>/dev/null)"
eq "log: the record carries ts/hook/decision/task_key/mode/head/detail" "true" \
  "$(jq -r 'has("ts") and has("hook") and has("decision") and has("task_key") and has("mode") and has("head") and has("detail")' "$LF" 2>/dev/null)"
eq "log: the record names the hook event" "Stop" "$(jq -r '.hook' "$LF" 2>/dev/null)"
eq "log: the record carries the resolved task key" "br-feature-x" "$(jq -r '.task_key' "$LF" 2>/dev/null)"
eq "log: the record carries HC_MODE" "task" "$(jq -r '.mode' "$LF" 2>/dev/null)"
printf '%s' "$(jq -r '.head' "$LF" 2>/dev/null)" | grep -qE '^[0-9a-f]{7,}$' \
  && ok "log: the record carries a short HEAD sha" \
  || bad "log: record carries a short HEAD sha" "$(jq -r '.head' "$LF" 2>/dev/null)"

# APPEND-ONLY: successive invocations accumulate, never overwrite.
run_gate "$R" d1 >/dev/null
run_gate "$R" d1 >/dev/null
eq "log: successive invocations append rather than rewrite" "3" \
  "$(jq -s 'length' "$(logfile "$R")" 2>/dev/null)"

# A BLOCK is recorded with its category.
arm_claim "$R" d1
OUT=$(run_gate "$R" d1)
is_block "$OUT" && ok "log: the blocking path still blocks" || bad "log: blocking path still blocks" "$OUT"
jq -s -r '.[-1].decision' "$(logfile "$R")" 2>/dev/null | grep -qF 'block:dod-no-contract' \
  && ok "log: a block is recorded with its category" \
  || bad "log: block recorded with its category" "$(jq -s -r '.[-1].decision' "$(logfile "$R")" 2>/dev/null)"

# THE GATE'S STDOUT IS A PROTOCOL: byte-identical with and without the log.
# The comparison runs the REAL gate from a plugin-root copy with lib-log.sh
# removed — the fallback stub path — against the shipped one.
PLUGIN_COPY=$(mktemp -d 2>/dev/null)
if [ -n "$PLUGIN_COPY" ] && cp -R "$ROOT/." "$PLUGIN_COPY/" 2>/dev/null; then
  rm -f "$PLUGIN_COPY/scripts/lib-log.sh"
  R2=$(make_repo task)
  echo "code" > "$R2/src.py"; git -C "$R2" add -A; git -C "$R2" commit -qm feat >/dev/null
  arm_claim "$R2" d2
  WITH=$(run_gate "$R2" d2)
  R3=$(make_repo task)
  echo "code" > "$R3/src.py"; git -C "$R3" add -A; git -C "$R3" commit -qm feat >/dev/null
  CLAUDE_PLUGIN_ROOT="$PLUGIN_COPY" CLAUDE_PROJECT_DIR="$R3" bash "$PLUGIN_COPY/scripts/dod-complete-task.sh" d3 >/dev/null 2>&1
  WITHOUT=$(printf '{"session_id":"d3","hook_event_name":"Stop","stop_hook_active":false}' \
    | CLAUDE_PLUGIN_ROOT="$PLUGIN_COPY" CLAUDE_PROJECT_DIR="$R3" bash "$PLUGIN_COPY/scripts/dod-gate.sh" 2>/dev/null)
  WRC=$?
  eq "log: the gate exits 0 with lib-log.sh absent" "0" "$WRC"
  eq "log: gate stdout is byte-identical with and without the decision log" "$WITHOUT" "$WITH"
  [ -z "$(find "$R3/.claude/.harness/dod-log" -type f 2>/dev/null)" ] \
    && ok "log: with lib-log.sh absent nothing is written (the stub is a true no-op)" \
    || bad "log: absent lib-log writes nothing"
  rm -rf "$PLUGIN_COPY"
else
  bad "log: could not stage a plugin-root copy for the identical-stdout check"
fi

# A LOGGING FAILURE MUST NOT BREAK THE GATE. dod-log/ is replaced by a regular
# file so mkdir -p cannot succeed and every append must fail.
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
mkdir -p "$R/.claude/.harness"
printf 'not a directory\n' > "$R/.claude/.harness/dod-log"
OUT=$(run_gate "$R" d4)
eq "log: an unwritable log leaves the silent gate silent" "" "$OUT"
eq "log: an unwritable log still exits 0" "0" "$G_RC"
arm_claim "$R" d4
OUT=$(run_gate "$R" d4)
is_block "$OUT" && ok "log: an unwritable log does not change the block decision" \
  || bad "log: unwritable log keeps the block" "$OUT"
eq "log: an unwritable log still exits 0 on the blocking path" "0" "$G_RC"

# dod_log itself: never stdout, always 0 — asserted directly on the function.
LOG_STDOUT=$(cd "$R" && HARNESS_DIR="$R/.claude/.harness" PROJECT_DIR="$R" bash -c \
  '. "$1/scripts/lib-log.sh"; dod_log Stop "allow" "direct call"' _ "$ROOT" 2>/dev/null)
LOG_RC=$?
eq "log: dod_log writes nothing to stdout" "" "$LOG_STDOUT"
eq "log: dod_log always returns 0" "0" "$LOG_RC"

# The user-turn hook logs its quiet paths and captures the raw payload.
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
run_user_turn "$R" d5 >/dev/null
jq -s -r '[.[] | select(.hook == "UserPromptSubmit")] | length' "$(logfile "$R")" 2>/dev/null | grep -qv '^0$' \
  && ok "log: the user-turn hook records its decision" \
  || bad "log: user-turn records its decision" "$(cat "$(logfile "$R")" 2>/dev/null)"
[ -n "$(find "$R/.claude/.harness/dod-log/payloads" -name '*.json' 2>/dev/null)" ] \
  && ok "log: the raw UserPromptSubmit payload is captured (temporary diagnostic)" \
  || bad "log: raw payload captured"
# ...and the capture is BOUNDED. 25 turns must leave at most 20 files behind.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
  run_user_turn "$R" d5 >/dev/null
done
PCOUNT=$(find "$R/.claude/.harness/dod-log/payloads" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "${PCOUNT:-0}" -le 20 ] \
  && ok "log: the payload capture is capped at the 20 most recent files ($PCOUNT)" \
  || bad "log: payload capture capped at 20" "$PCOUNT files"

# ===========================================================================
# REMINDER TEXT — it must INSTRUCT, in order, and it must TRACK STATE. The
# shipped text did neither: it named dod-complete-task.sh only in a trailing
# caveat about what the script does not do, so nothing ever told the agent to
# arm the claim and the latch-driven Stop gate never engaged at all.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
M1=$(run_user_turn "$R" x1 | jq -r '.systemMessage // ""' 2>/dev/null)
printf '%s' "$M1" | grep -qF 'dod-complete-task.sh' \
  && ok "reminder: names dod-complete-task.sh" || bad "reminder: names the claim script" "$M1"
printf '%s' "$M1" | grep -qF 'dod-verify' \
  && ok "reminder: names the dod-verify skill" || bad "reminder: names dod-verify" "$M1"
printf '%s' "$M1" | grep -qF 'clears nothing' \
  && ok "reminder: still carries the asymmetry rule, as a clause inside step 1" \
  || bad "reminder: carries the asymmetry clause" "$M1"
printf '%s' "$M1" | grep -qiF 'subagents run no dod script' \
  && ok "reminder: says only the orchestrator runs dod" || bad "reminder: orchestrator-only" "$M1"
# State-aware: recording the contract must visibly change the text.
write_dod "$R" x1
M2=$(run_user_turn "$R" x1 | jq -r '.systemMessage // ""' 2>/dev/null)
[ "$M1" != "$M2" ] && ok "reminder: the text changes when a DoD contract appears" \
  || bad "reminder: text tracks contract state" "$M2"
# ...and so must uncommitted work appearing on top of committed work.
echo "more" >> "$R/src.py"
M3=$(run_user_turn "$R" x1 | jq -r '.systemMessage // ""' 2>/dev/null)
[ "$M2" != "$M3" ] && ok "reminder: the text changes when uncommitted product work appears" \
  || bad "reminder: text tracks tree state" "$M3"
# Honest, not artificially varied: unchanged state -> unchanged text.
M4=$(run_user_turn "$R" x1 | jq -r '.systemMessage // ""' 2>/dev/null)
eq "reminder: unchanged state leaves the text unchanged (it tracks reality, not a counter)" "$M3" "$M4"

# ===========================================================================
# RECURSION BRAKE — category-scoped, under the latch. Same category twice under
# stop_hook_active releases; a DIFFERENT category still blocks.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
arm_claim "$R" b1
run_gate "$R" b1 >/dev/null                       # turn 1 → dod-no-contract
eq "brake: turn 1 category" "dod-no-contract" "$(lastblock "$R" br-feature-x)"
OUT=$(run_gate "$R" b1 true)
[ -z "$OUT" ] && ok "brake: the SAME category under stop_hook_active releases" \
  || bad "brake: same category releases" "$OUT"
write_dod "$R" b1                                  # category now flips
OUT=$(run_gate "$R" b1 true)
is_block "$OUT" && ok "brake: a DIFFERENT category still blocks under stop_hook_active" \
  || bad "brake: different category still blocks" "$OUT"
eq "brake: the new category is recorded" "dod-no-verify" "$(lastblock "$R" br-feature-x)"

# ===========================================================================
# BYPASS — {"artifact_paths":["*"]} in the AGENT-WRITABLE session config must
# not silence classification. hc_cfg reads that layer first, so artifact_paths
# has to come from the REPO config only.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
hc__test_write_session_config "$R" '{"artifact_paths":["*"]}'
classify_changeset "$R" x1 \
  && ok "bypass: session-config artifact_paths ['*'] does NOT reclassify product as artifact" \
  || bad "bypass: session-config artifact_paths ['*'] silenced the classifier" "no product seen"
OUT=$(run_user_turn "$R" x1)
[ -n "$OUT" ] && ok "bypass: the reminder still fires under the ['*'] session config" \
  || bad "bypass: reminder silenced by session config" "(empty)"
# ...and the gate's own tree check is not silenced either.
write_dod "$R" x1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" x1 >/dev/null 2>&1
echo "uncommitted" > "$R/later.py"
arm_claim "$R" x1
OUT=$(run_gate "$R" x1)
eq "bypass: the gate still sees uncommitted product dirt under ['*']" \
   "dod-uncommitted" "$(lastblock "$R" br-feature-x)"
is_block "$OUT" && ok "bypass: the gate still blocks under the ['*'] session config" \
  || bad "bypass: gate blocks under ['*']" "$OUT"

# ===========================================================================
# BYPASS — a planted refname in the AGENT-WRITABLE baselines/<sid>.sha.
# `git rev-parse -q --verify` resolves ANY refname, so the literal "HEAD" used
# to collapse HC_BASE_ORIG..HEAD to the empty range and make the entire
# committed half of the changeset disappear. Session mode, CLEAN tree, so the
# committed range is the only thing that can report product surface.
# ===========================================================================
for PLANT in HEAD main refs/heads/main; do
  R=$(make_repo)
  hc__test_seed_session_baseline "$R" p1
  echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
  hc__test_plant_base_sha "$R" p1 "$PLANT"
  classify_tree "$R" p1 \
    && bad "bypass: control — the tree must be clean for the '$PLANT' plant to mean anything" "tree dirty" \
    || ok "bypass: control — tree clean, so only the committed range can report product ($PLANT)"
  classify_changeset "$R" p1 \
    && ok "bypass: a planted '$PLANT' in baselines/<sid>.sha does not collapse the changeset" \
    || bad "bypass: planted '$PLANT' collapsed the committed range" "no product seen"
  OUT=$(run_user_turn "$R" p1)
  [ -n "$OUT" ] && ok "bypass: the reminder still fires with a planted '$PLANT'" \
    || bad "bypass: reminder silenced by a planted '$PLANT'" "(empty)"
done

# ===========================================================================
# UNTIDY — .claude/ wholly untracked and not gitignored. Porcelain collapses it
# to the single line "?? .claude/", so the harness's own state dir must still
# be recognised as harness-owned rather than read as manufactured product dirt.
# ===========================================================================
R=$(hc__test_make_repo_untracked_claude)
hc__test_seed_session_baseline "$R" u1
eq "untidy: porcelain really does collapse the untracked dir" "?? .claude/" \
   "$(git -C "$R" status --porcelain | head -1)"
classify_tree "$R" u1 \
  && bad "untidy: untracked .claude/ holding only harness state must NOT read as product dirt" "product seen" \
  || ok "untidy: untracked .claude/ holding only harness state is not product dirt"
OUT=$(run_user_turn "$R" u1)
[ -z "$OUT" ] && ok "untidy: no reminder in a repo whose only 'change' is its own untracked state dir" \
  || bad "untidy: reminder fired on harness-own dirt" "$OUT"
# A real untracked product file in the SAME collapsed-.claude repo must be seen.
mkdir -p "$R/src"; echo "print(1)" > "$R/src/app.py"
classify_tree "$R" u1 \
  && ok "untidy: a real untracked product file alongside it IS seen" \
  || bad "untidy: real product file missed next to a collapsed .claude/" "no product seen"
OUT=$(run_user_turn "$R" u1)
[ -n "$OUT" ] && ok "untidy: the reminder fires once real product work appears" \
  || bad "untidy: reminder fires on real product work" "(empty)"

# ===========================================================================
# UNTIDY — CLAUDE_PROJECT_DIR is a SUBDIRECTORY of the git toplevel. Porcelain
# paths are repo-root-relative ("app/src.py") while the harness's own path
# literals are project-relative, and any pathspec built from the former must be
# ':/'-anchored or it silently matches nothing.
# ===========================================================================
P=$(hc__test_make_repo_subdir task)
mkdir -p "$P/.claude/.harness/task-dod/archive" "$P/.claude/.harness/task-dod/verified"
classify_tree "$P" s1 \
  && bad "subdir: control — a clean subdir project must report no tree dirt" "product seen" \
  || ok "subdir: control — clean tree reports no product dirt"
echo "print(1)" > "$P/src.py"
classify_tree "$P" s1 \
  && ok "subdir: an untracked product file under the subdir project IS seen" \
  || bad "subdir: product file under a subdir project missed" "no product seen"
# Full gate round trip in the untidy layout.
git -C "$P" add -A; git -C "$P" commit -qm feat >/dev/null
write_dod "$P" s1
arm_claim "$P" s1
OUT=$(run_gate "$P" s1)
is_block "$OUT" && ok "subdir: latched + unverified → blocks (task key derived correctly)" \
  || bad "subdir: latched + unverified blocks" "$OUT"
CLAUDE_PROJECT_DIR="$P" bash "$STUB" s1 >/dev/null 2>&1
SHA=$(git -C "$P" rev-parse HEAD)
OUT=$(run_gate "$P" s1)
[ -z "$OUT" ] && ok "subdir: covered → allows" || bad "subdir: covered allows" "$OUT"
[ -f "$P/.claude/.harness/task-dod/archive/$SHA.json" ] \
  && ok "subdir: contract archived under the subdir state dir" \
  || bad "subdir: contract archived under the subdir state dir"

# ===========================================================================
# UNTIDY — an AMENDED commit. The pre-amend sha still RESOLVES (it survives in
# the object db) but is no longer HEAD, so every HEAD-keyed artefact goes stale.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" m1
CLAUDE_PROJECT_DIR="$R" bash "$STUB" m1 >/dev/null 2>&1
OLD_SHA=$(git -C "$R" rev-parse HEAD)
arm_claim "$R" m1
OUT=$(run_gate "$R" m1)
[ -z "$OUT" ] && ok "amend: control — verified at HEAD, gate allows before the amend" \
  || bad "amend: control allows before the amend" "$OUT"
hc__test_amend_head "$R" "feat, reworded"
NEW_SHA=$(git -C "$R" rev-parse HEAD)
[ "$OLD_SHA" != "$NEW_SHA" ] && ok "amend: HEAD moved" || bad "amend: HEAD moved"
git -C "$R" rev-parse -q --verify "$OLD_SHA^{commit}" >/dev/null 2>&1 \
  && ok "amend: the pre-amend sha still RESOLVES (it is just no longer HEAD)" \
  || bad "amend: pre-amend sha still resolves"
# The contract was archived by the allow above, so re-collect and re-claim: the
# verification result now names a sha that is not HEAD → not coverage.
write_dod "$R" m1
arm_claim "$R" m1
OUT=$(run_gate "$R" m1)
is_block "$OUT" && ok "amend: a verification result keyed to the pre-amend sha is not coverage → blocks" \
  || bad "amend: stale-by-amend verification blocks" "$OUT"
eq "amend: block category" "dod-no-verify" "$(lastblock "$R" br-feature-x)"

# ===========================================================================
# UNTIDY — two task keys in one repo. A latch, contract or result under one key
# must be invisible to the other.
# ===========================================================================
R=$(hc__test_make_repo_two_keys)
mkdir -p "$R/.claude/.harness/task-dod/archive" "$R/.claude/.harness/task-dod/verified"
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat-a >/dev/null
write_dod "$R" k1
arm_claim "$R" k1
OUT=$(run_gate "$R" k1)
is_block "$OUT" && ok "keys: feature/a latched + unverified → blocks" \
  || bad "keys: feature/a blocks" "$OUT"
eq "keys: the latch is keyed to feature/a" "1" \
   "$([ -f "$(latch "$R" br-feature-a)" ] && echo 1 || echo 0)"
git -C "$R" checkout -q feature/b
OUT=$(run_gate "$R" k1)
[ -z "$OUT" ] && ok "keys: the SAME session on feature/b sees no latch → silent" \
  || bad "keys: feature/b silent" "$OUT"
[ -f "$(latch "$R" br-feature-a)" ] \
  && ok "keys: feature/a's latch survives a gate run on feature/b" \
  || bad "keys: feature/a's latch survives"
arm_claim "$R" k1
OUT=$(run_gate "$R" k1)
is_block "$OUT" && ok "keys: claiming on feature/b blocks on ITS own (absent) contract" \
  || bad "keys: feature/b blocks on its own contract" "$OUT"
eq "keys: feature/b blocks with its own category" "dod-no-contract" "$(lastblock "$R" br-feature-b)"
[ -f "$(dodfile "$R" br-feature-a)" ] \
  && ok "keys: feature/a's contract is untouched by the feature/b cycle" \
  || bad "keys: feature/a's contract untouched"

# ===========================================================================
# NO AGENT-FACING TEXT MAY NAME dod-stub-done.sh. Naming the stub in a block
# reason or a reminder would instruct the agent to fake its own verification.
# Asserted over EVERY gate and reminder output this suite produced.
# ===========================================================================
printf '%s' "$GATE_OUTPUTS" | grep -qF 'dod-stub-done' \
  && bad "text: no gate output may name dod-stub-done.sh" "$(printf '%s' "$GATE_OUTPUTS" | grep -F 'dod-stub-done' | head -1)" \
  || ok "text: no gate output names dod-stub-done.sh"
printf '%s' "$REMINDER_OUTPUTS" | grep -qF 'dod-stub-done' \
  && bad "text: no reminder output may name dod-stub-done.sh" "$(printf '%s' "$REMINDER_OUTPUTS" | grep -F 'dod-stub-done' | head -1)" \
  || ok "text: no reminder output names dod-stub-done.sh"
# The claim script's own agent-facing pointer must not name it either.
R=$(make_repo task)
CLAIM_OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$CLAIM" n1 2>&1)
printf '%s' "$CLAIM_OUT" | grep -qF 'dod-stub-done' \
  && bad "text: the claim script must not name dod-stub-done.sh" "$CLAIM_OUT" \
  || ok "text: the claim script does not name dod-stub-done.sh"
printf '%s' "$CLAIM_OUT" | grep -qF 'dod-verify' \
  && ok "text: the claim script points at the dod-verify skill instead" \
  || bad "text: claim script points at dod-verify" "$CLAIM_OUT"

# ===========================================================================
# FAIL-SAFE, over every gate invocation in this file: exit 0 always, stdout
# either empty or valid JSON — never a bare string, never a nonzero exit.
# ===========================================================================
eq "fail-safe: no gate invocation exited non-zero" "0" "$FAILSAFE_RC_VIOLATIONS"
eq "fail-safe: every non-empty gate stdout was valid JSON" "0" "$FAILSAFE_JSON_VIOLATIONS"
# Unreadable state must still release rather than trap: a latch armed over a
# corrupt contract file.
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
printf 'garbage{' > "$(dodfile "$R" br-feature-x)"
arm_claim "$R" f1
OUT=$(run_gate "$R" f1)
eq "fail-safe: a corrupt contract still exits 0" "0" "$G_RC"
if [ -z "$OUT" ] || is_block "$OUT"; then
  ok "fail-safe: a corrupt contract yields either silence or a well-formed block"
else
  bad "fail-safe: corrupt contract yields silence or a block" "$OUT"
fi

echo
echo "test-dod-claim: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
