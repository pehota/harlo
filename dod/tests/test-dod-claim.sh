#!/bin/bash
#
# Tests for the CLAIM-DRIVEN Stop gate and its three sibling hooks:
# dod-complete-task.sh (arms the latch), dod-user-turn.sh (UserPromptSubmit —
# disarms it, then reminds), dod-task-log.sh (TaskCompleted — observe-only).
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
TASK_LOG="$SCRIPTS/dod-task-log.sh"
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

# run_user_turn <repo> <session_id> — the UserPromptSubmit hook; echoes stdout.
REMINDER_OUTPUTS=""
run_user_turn() {
  local out
  out=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":"next"}' "$2" \
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
  && ok "step 6: a BLOCK leaves the latch armed (only coverage or a new user turn disarms)" \
  || bad "step 6: latch still armed after a block"
# artifact-only dirt on top of the same state must NOT block — the classifier
# is what distinguishes them, not the mere fact the tree is dirty.
rm -f "$R/later.py"
mkdir -p "$R/docs"; echo "notes" > "$R/docs/notes.md"
OUT=$(run_gate "$R" g6)
[ -z "$OUT" ] && ok "step 6: artifact-only tree dirt (docs/**) → still allowed" \
  || bad "step 6: artifact-only dirt allowed" "$OUT"

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
# LATCH LIFECYCLE — armed by the claim, disarmed by a user turn.
# ===========================================================================
R=$(make_repo task)
echo "code" > "$R/src.py"; git -C "$R" add -A; git -C "$R" commit -qm feat >/dev/null
write_dod "$R" l1
[ ! -f "$(latch "$R" br-feature-x)" ] && ok "lifecycle: no latch before the claim" \
  || bad "lifecycle: no latch before the claim"
arm_claim "$R" l1
[ -f "$(latch "$R" br-feature-x)" ] && ok "lifecycle: dod-complete-task.sh arms the latch" \
  || bad "lifecycle: claim arms the latch"
run_user_turn "$R" l1 >/dev/null
[ ! -f "$(latch "$R" br-feature-x)" ] \
  && ok "lifecycle: the user taking the turn back disarms the latch" \
  || bad "lifecycle: user turn disarms the latch"
OUT=$(run_gate "$R" l1)
[ -z "$OUT" ] && ok "lifecycle: after the disarm the gate is silent again" \
  || bad "lifecycle: silent after disarm" "$OUT"

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
# TaskCompleted audit trail — writes the record, says nothing, exits 0.
# ===========================================================================
R=$(make_repo task)
OUT=$(printf '{"task_id":"t-42","task_description":"do the thing","task_state":"completed"}' \
        | CLAUDE_PROJECT_DIR="$R" bash "$TASK_LOG" 2>&1)
RC=$?
eq "task-log: exits 0" "0" "$RC"
eq "task-log: stays silent" "" "$OUT"
LOG="$R/.claude/.harness/task-log/t-42.json"
[ -f "$LOG" ] && ok "task-log: record written under the task id" || bad "task-log: record written"
eq "task-log: task_id recorded"          "t-42"         "$(jq -r '.task_id' "$LOG" 2>/dev/null)"
eq "task-log: task_description recorded" "do the thing" "$(jq -r '.task_description' "$LOG" 2>/dev/null)"
eq "task-log: task_state recorded"       "completed"    "$(jq -r '.task_state' "$LOG" 2>/dev/null)"
printf '%s' "$(jq -r '.recorded_at' "$LOG" 2>/dev/null)" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' \
  && ok "task-log: recorded_at is a UTC timestamp" \
  || bad "task-log: recorded_at is a UTC timestamp" "$(jq -r '.recorded_at' "$LOG" 2>/dev/null)"
# Absent fields are recorded empty, not dropped; the record is still kept.
printf '{"task_id":"t-43"}' | CLAUDE_PROJECT_DIR="$R" bash "$TASK_LOG" >/dev/null 2>&1
eq "task-log: absent task_state recorded empty" "" \
  "$(jq -r '.task_state' "$R/.claude/.harness/task-log/t-43.json" 2>/dev/null)"
# It must never influence the gate: the record exists, the gate is still silent.
OUT=$(run_gate "$R" t1)
[ -z "$OUT" ] && ok "task-log: writing a completion record is not a claim (gate stays silent)" \
  || bad "task-log: record must not arm anything" "$OUT"

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
