#!/bin/bash
#
# Tests for done-write-state.sh (Step 7 done-state writer).
# Runs in a throwaway git repo in a tmpdir so it never pollutes the trial's
# history and can freely exercise both the clean-tree and dirty-tree branches.

SCRIPT="$(cd "$(dirname "$0")/../scripts" && pwd)/done-write-state.sh"
# Source harness-common.sh for hc_validate + HC_CONTRACTS_DIR (used by the plan-
# fold cases to validate the extended done-state schema).
# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")/../scripts" && pwd)/harness-common.sh" 2>/dev/null
# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

TMP=$(hc__test_mktemp_d)
trap 'rm -rf "$TMP"' EXIT

git -C "$TMP" init -q
git -C "$TMP" config user.email "test@test.local"
git -C "$TMP" config user.name "test"
mkdir -p "$TMP/.claude/.harness/baselines" "$TMP/.claude/.harness/review-log"
# Mirror the real install: harness state is gitignored, so seeding baselines
# does not make the tree "dirty".
echo ".claude/.harness/" > "$TMP/.gitignore"
echo "hello" > "$TMP/file.txt"

# done-config.json WITH a lint command — so the writer's lint-when-configured
# refusal branch is exercised (effective lint = overrides.lint ?? detected.lint).
# Committed in the SAME initial commit (mirroring the real install: done-config
# is tracked, only .claude/.harness/ is gitignored) so the tree stays clean and
# REAL_SHA (captured after) is the live HEAD the writer sees.
mkdir -p "$TMP/.claude"
cat > "$TMP/.claude/done-config.json" <<'JSON'
{"source_fingerprint":null,"detected":{"lint":"echo lint"},"overrides":{},"max_fix_attempts":3,"baseline_snapshot":true,"deploy_check_cmd":null}
JSON
git -C "$TMP" add -A
git -C "$TMP" commit -qm "initial"

REAL_SHA=$(git -C "$TMP" rev-parse HEAD)
SESSION="sess-abc123"
# seed a baseline .sha so the resolver can find the session id without an arg
echo "$REAL_SHA" > "$TMP/.claude/.harness/baselines/${SESSION}.sha"

# The writer now REJECTS a session-mode id with no baselines/<id>.sha (dead-id
# backstop: prevents writing a done-state under a key the gate never reads). This
# fixture repo is on `main` (its trunk) → session mode, so EVERY explicit session
# id below must have a matching baseline .sha, exactly as SessionStart records in
# reality. Seed one for each id these cases pass. (The dead-id refusal itself is
# asserted directly in cases 13a/13b below.)
seed_sha() { echo "$REAL_SHA" > "$TMP/.claude/.harness/baselines/${1}.sha"; }
# The other explicit-id seeds are added AFTER case 1 (see below), so case 1's
# no-arg `ls -t` resolution has sess-abc123 as the ONLY .sha — deterministic, no
# reliance on sub-second mtime ordering.

# Independent review-log for the live HEAD with no open findings — required by
# the writer (mirrors the gate). Keyed by REAL_SHA (the writer reads the log for
# git rev-parse HEAD, which equals REAL_SHA while the tree is at "initial").
# Schema-valid review-log with an EMPTY findings[] (green review). The <n> arg is
# retained for call-site compatibility and mirrored into open_findings, but the
# authoritative signal is the empty findings array. files_reviewed is empty here
# because the writer's cases (until the coverage cases) have base==HEAD → empty
# changeset → coverage trivially satisfied.
write_review_log() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":[],"open_findings":%s}\n' "$REAL_SHA" "$1" > "$TMP/.claude/.harness/review-log/$REAL_SHA.json"; }
clear_review_log() { rm -f "$TMP/.claude/.harness/review-log/$REAL_SHA.json"; }
# severity-tagged log; self-reported open_findings=0 to prove the writer
# recomputes the blocking count structurally (like the gate) and does not trust it.
write_review_findings() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":%s,"open_findings":0}\n' "$REAL_SHA" "$1" > "$TMP/.claude/.harness/review-log/$REAL_SHA.json"; }
write_review_log 0

export CLAUDE_PROJECT_DIR="$TMP"
# Done-state is now keyed by HC_TASK_KEY. This fixture's repo is on `main` (its
# trunk) → session mode → task_key = "session-<session_id>". The injected
# .session_id JSON field stays the RAW id ($SESSION); only the FILENAME changes.
DONE_STATE="$TMP/.claude/.harness/done-state/session-${SESSION}.json"

# Green payload: tests green, lint green (lint IS configured), no review field.
PAYLOAD='{"dod":{"sources":["base"],"items":["tests green","lint green","app starts"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok","newly_red":[],"pre_existing_red":[]},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"app_started":true,"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'

echo "== test-write-state =="

# --- 1. clean tree, session resolved from baseline → writes ------------------
OUTPATH=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$DONE_STATE" ]; then
  ok "clean tree: wrote done-state, exit 0"
else
  bad "clean tree write failed (rc=$RC, out=$OUTPATH)"
fi
if [ "$OUTPATH" = "$DONE_STATE" ]; then
  ok "printed the path written"
else
  bad "did not print correct path; got: $OUTPATH"
fi

# --- 2. injected verified_sha is the REAL rev-parse HEAD (not a literal) -----
WROTE_SHA=$(jq -r '.verified_sha' "$DONE_STATE")
if [ "$WROTE_SHA" = "$REAL_SHA" ] && [ ${#WROTE_SHA} -eq 40 ]; then
  ok "injected verified_sha == real git rev-parse HEAD ($WROTE_SHA)"
else
  bad "verified_sha wrong: wrote '$WROTE_SHA' expected '$REAL_SHA'"
fi

# --- 3. tree_clean set true on a clean tree ---------------------------------
if jq -e '.tree_clean == true' "$DONE_STATE" >/dev/null 2>&1; then
  ok "tree_clean == true on clean tree"
else
  bad "tree_clean not true on clean tree"
fi

# --- 4. session_id injected + judgment fields merged through -----------------
if jq -e --arg s "$SESSION" '.session_id == $s' "$DONE_STATE" >/dev/null 2>&1; then
  ok "session_id resolved from baseline + injected"
else
  bad "session_id wrong in output"
fi
if jq -e '.app_started == true and .lint.exit_code == 0 and (.dod.items | length == 3) and .escalation == null and (has("review") | not)' "$DONE_STATE" >/dev/null 2>&1; then
  ok "judgment fields (app_started/lint/dod/escalation) merged through, no review field"
else
  bad "judgment fields not merged correctly"
fi

# Now seed baseline .sha for every EXPLICIT session id the cases below pass. The
# writer's dead-id backstop rejects a session-mode id with no baselines/<id>.sha,
# and this fixture repo is on `main` (session mode), so each id needs one — as
# SessionStart records in reality. Done AFTER cases 1-4 so the no-arg `ls -t`
# above deterministically resolved sess-abc123 (the sole .sha at that point).
for s in sess-explicit sess-red sess-lint sess-nolog sess-blkfind sess-advfind sess-nonarr sess-esc sess-green sess-notrun-noesc sess-notrun-esc sess-noevidence; do seed_sha "$s"; done

# --- 5. dirty tree → REFUSE (nonzero, no new write) --------------------------
rm -f "$DONE_STATE"
echo "dirty change" >> "$TMP/file.txt"    # make tree dirty
ERR=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "dirty tree: refused with nonzero exit (rc=$RC)"
else
  bad "dirty tree: did NOT refuse (rc=$RC)"
fi
if echo "$ERR" | grep -qi "dirty"; then
  ok "dirty refusal prints a clear 'dirty' error"
else
  bad "dirty refusal error message unclear: $ERR"
fi
if [ ! -f "$DONE_STATE" ]; then
  ok "dirty tree: no done-state written"
else
  bad "dirty tree: done-state was written anyway"
fi
# restore clean tree for hygiene
git -C "$TMP" checkout -- file.txt 2>/dev/null

# --- 6. invalid JSON payload → nonzero ---------------------------------------
ERR=$(printf 'not json{' | bash "$SCRIPT" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$ERR" | grep -qi "json"; then
  ok "invalid JSON payload rejected with nonzero + clear message"
else
  bad "invalid JSON not rejected (rc=$RC, err=$ERR)"
fi

# --- 7. explicit session id arg overrides baseline resolution ----------------
OUTPATH=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" "sess-explicit")
if [ "$OUTPATH" = "$TMP/.claude/.harness/done-state/session-sess-explicit.json" ] && [ -f "$OUTPATH" ]; then
  ok "explicit session id arg honored"
else
  bad "explicit session id arg not honored; got: $OUTPATH"
fi

# --- 8. non-green payload (tests red), no escalation → REFUSE (no write) ------
# review-log is green (open:0) so the refusal is unambiguously on tests.
RED_PAYLOAD='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":1,"newly_red":[],"pre_existing_red":[]},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"app_started":true,"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT8="$TMP/.claude/.harness/done-state/session-sess-red.json"
rm -f "$OUT8"
ERR=$(printf '%s' "$RED_PAYLOAD" | bash "$SCRIPT" "sess-red" 2>&1)
RC=$?
if [ "$RC" -ne 0 ]; then
  ok "non-green (tests red) + no escalation: refused with nonzero exit (rc=$RC)"
else
  bad "non-green payload was NOT refused (rc=$RC)"
fi
if [ ! -f "$OUT8" ]; then
  ok "non-green refusal: no done-state written"
else
  bad "non-green refusal: done-state was written anyway"
fi
if echo "$ERR" | grep -qi "tests are not green"; then
  ok "non-green refusal names the failed outcome (tests)"
else
  bad "non-green refusal message unclear: $ERR"
fi

# --- 8b. lint configured + lint red, no escalation → REFUSE (no write) --------
# tests green, review-log green → the refusal is unambiguously on lint.
LINT_RED='{"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":1},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT8B="$TMP/.claude/.harness/done-state/session-sess-lint.json"
rm -f "$OUT8B"
ERR=$(printf '%s' "$LINT_RED" | bash "$SCRIPT" "sess-lint" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT8B" ] && echo "$ERR" | grep -qi "lint is configured but not green"; then
  ok "lint configured + lint red refused, no write, clear message"
else
  bad "lint-red refusal failed (rc=$RC, file=$( [ -f "$OUT8B" ] && echo present || echo absent ), err=$ERR)"
fi

# --- 8c. no review-log for HEAD, no escalation → REFUSE (no write) ------------
# tests green, lint green → the refusal is unambiguously on the missing log.
clear_review_log
NOLOG_PAYLOAD='{"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT8C="$TMP/.claude/.harness/done-state/session-sess-nolog.json"
rm -f "$OUT8C"
ERR=$(printf '%s' "$NOLOG_PAYLOAD" | bash "$SCRIPT" "sess-nolog" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT8C" ] && echo "$ERR" | grep -qi "no independent review-log"; then
  ok "no review-log for HEAD refused, no write, clear message"
else
  bad "no-review-log refusal failed (rc=$RC, file=$( [ -f "$OUT8C" ] && echo present || echo absent ), err=$ERR)"
fi
write_review_log 0   # restore green review-log for the remaining green cases

# --- 8d. blocking-severity finding at HEAD (default min=high), no escalation → REFUSE
# tests green, lint green → refusal is unambiguously on the review severity gate.
# self-reported open_findings=0 proves the writer recomputes structurally.
write_review_findings '[{"severity":"high","file":"a","line":1,"desc":"x"}]'
BLK_PAYLOAD='{"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT8D="$TMP/.claude/.harness/done-state/session-sess-blkfind.json"
rm -f "$OUT8D"
ERR=$(printf '%s' "$BLK_PAYLOAD" | bash "$SCRIPT" "sess-blkfind" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT8D" ] && echo "$ERR" | grep -qi "blocking"; then
  ok "blocking-severity finding (high, min=high) refused, no write, clear message"
else
  bad "blocking-severity refusal failed (rc=$RC, file=$( [ -f "$OUT8D" ] && echo present || echo absent ), err=$ERR)"
fi

# --- 8e. only ADVISORY findings at HEAD (low/medium, default min=high) → WRITES
# advisory findings never gate; tests+lint green → the writer must write.
write_review_findings '[{"severity":"low","file":"a","line":1,"desc":"nit"},{"severity":"medium","file":"a","line":2,"desc":"style"}]'
ADV_PAYLOAD='{"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT8E="$TMP/.claude/.harness/done-state/session-sess-advfind.json"
rm -f "$OUT8E"
OUTPATH=$(printf '%s' "$ADV_PAYLOAD" | bash "$SCRIPT" "sess-advfind")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT8E" ] && [ "$OUTPATH" = "$OUT8E" ]; then
  ok "advisory-only findings (low/medium, min=high): writes normally (advisory never gates)"
else
  bad "advisory-only write failed (rc=$RC, out=$OUTPATH)"
fi
write_review_log 0   # restore green review-log for the remaining green cases

# --- 8f. review-log with NON-ARRAY findings + self-reported open_findings:0 → REFUSE
# tests green, lint green → the refusal is unambiguously on the review gate.
# findings is an object, so the writer must NOT trust open_findings:0; it must
# fail toward block. The hard contract now catches this at the review-log SCHEMA
# gate (findings must be an array) BEFORE hc_review_blocking, so the refusal
# reason shifted from "blocking" to "contract (schema)"; the refuse+no-write
# outcome is preserved (anti-forgery holds).
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":{"severity":"critical"},"open_findings":0}\n' "$REAL_SHA" > "$TMP/.claude/.harness/review-log/$REAL_SHA.json"
NONARR_PAYLOAD='{"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT8F="$TMP/.claude/.harness/done-state/session-sess-nonarr.json"
rm -f "$OUT8F"
ERR=$(printf '%s' "$NONARR_PAYLOAD" | bash "$SCRIPT" "sess-nonarr" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT8F" ] && echo "$ERR" | grep -qi "contract (schema)"; then
  ok "non-array findings + open_findings:0 refused, no write (anti-forgery, via schema gate)"
else
  bad "non-array findings refusal failed (rc=$RC, file=$( [ -f "$OUT8F" ] && echo present || echo absent ), err=$ERR)"
fi
write_review_log 0   # restore green review-log for the remaining green cases

# --- 9. non-green payload WITH escalation present → WRITES (escape hatch) ------
# Red tests + lint AND no review-log — escalation must bypass every outcome
# check. Clear the review-log to prove the escape hatch is unconditional.
clear_review_log
ESC_PAYLOAD='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":1,"newly_red":[],"pre_existing_red":[]},"lint":{"exit_code":1},"app_started":false,"task_checks":[{"desc":"x","status":"failed"}],"escalation":{"type":"environment","command":"docker compose up","captured_error":"Cannot connect to the Docker daemon","exit_code":1}}'
OUT9="$TMP/.claude/.harness/done-state/session-sess-esc.json"
rm -f "$OUT9"
OUTPATH=$(printf '%s' "$ESC_PAYLOAD" | bash "$SCRIPT" "sess-esc")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT9" ] && [ "$OUTPATH" = "$OUT9" ]; then
  ok "non-green WITH escalation: wrote done-state (escape hatch), exit 0"
else
  bad "non-green + escalation did NOT write (rc=$RC, out=$OUTPATH)"
fi
if jq -e '.escalation.type == "environment" and .tests.exit_code == 1' "$OUT9" >/dev/null 2>&1; then
  ok "escalation payload merged through with red tests preserved"
else
  bad "escalation payload not merged correctly"
fi

# --- 10. green payload, no escalation → still WRITES normally -----------------
write_review_log 0   # Case 9 cleared it; green case needs it present
OUT10="$TMP/.claude/.harness/done-state/session-sess-green.json"
rm -f "$OUT10"
OUTPATH=$(printf '%s' "$PAYLOAD" | bash "$SCRIPT" "sess-green")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT10" ]; then
  ok "green payload, no escalation: writes normally"
else
  bad "green payload no-escalation write failed (rc=$RC, out=$OUTPATH)"
fi

# --- 10a. tests not_run, NO escalation → REFUSE (P1-c, #6) -------------------
# tests+lint would be green but tests were never run: without an escalation the
# writer must refuse (an unrun suite cannot masquerade as verified).
write_review_log 0
NOTRUN_NOESC='{"dod":{"sources":["base"],"items":["x"]},"tests":{"status":"not_run","reason":"docker down"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT10A="$TMP/.claude/.harness/done-state/session-sess-notrun-noesc.json"
rm -f "$OUT10A"
ERR=$(printf '%s' "$NOTRUN_NOESC" | bash "$SCRIPT" "sess-notrun-noesc" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT10A" ] && echo "$ERR" | grep -qi "not run"; then
  ok "tests not_run + no escalation: refused, no write, clear message"
else
  bad "not_run no-escalation refusal failed (rc=$RC, file=$( [ -f "$OUT10A" ] && echo present || echo absent ), err=$ERR)"
fi

# --- 10b. tests not_run, WITH escalation → WRITES (escape hatch) -------------
NOTRUN_ESC='{"dod":{"sources":["base"],"items":["x"]},"tests":{"status":"not_run","reason":"docker down"},"app_started":false,"task_checks":[{"desc":"x","status":"passed"}],"escalation":{"type":"environment","command":"npm test","captured_error":"no runtime","exit_code":1}}'
OUT10B="$TMP/.claude/.harness/done-state/session-sess-notrun-esc.json"
rm -f "$OUT10B"
OUTPATH=$(printf '%s' "$NOTRUN_ESC" | bash "$SCRIPT" "sess-notrun-esc")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT10B" ] && jq -e '.tests.status == "not_run"' "$OUT10B" >/dev/null 2>&1; then
  ok "tests not_run WITH escalation: writes (escape hatch), not_run preserved"
else
  bad "not_run + escalation did NOT write (rc=$RC, out=$OUTPATH)"
fi

# --- 10c. tests exit_code:0 but MISSING evidence, no escalation → REFUSE -----
# green claim without command/output_tail must be refused ("green must carry evidence").
NOEV_PAYLOAD='{"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT10C="$TMP/.claude/.harness/done-state/session-sess-noevidence.json"
rm -f "$OUT10C"
ERR=$(printf '%s' "$NOEV_PAYLOAD" | bash "$SCRIPT" "sess-noevidence" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT10C" ] && echo "$ERR" | grep -qi "evidence"; then
  ok "green tests WITHOUT evidence + no escalation: refused, no write, clear message"
else
  bad "no-evidence refusal failed (rc=$RC, file=$( [ -f "$OUT10C" ] && echo present || echo absent ), err=$ERR)"
fi

# --- 11/12. review COVERAGE contract (structural: files_reviewed ⊇ changed) ---
# All prior cases have base==HEAD (session baseline == HEAD) → EMPTY changeset →
# coverage trivially satisfied (that itself is the SKIP-adjacent no-regression
# path). To exercise the coverage refusal we must move HEAD past the seeded
# baseline so base(REAL_SHA)..HEAD is NON-empty. Commit two new files, then vary
# the review-log's files_reviewed. Session id sess-abc123 keeps base = REAL_SHA
# (its seeded baseline). Findings empty so coverage is the sole gating axis.
printf 'cov1\n' > "$TMP/cov1.txt"
printf 'cov2\n' > "$TMP/cov2.txt"
git -C "$TMP" add -A
git -C "$TMP" commit -qm "coverage changeset"
COV_HEAD=$(git -C "$TMP" rev-parse HEAD)
COV_DONE="$TMP/.claude/.harness/done-state/session-sess-abc123.json"
cov_payload='{"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
cov_log() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[]}\n' "$COV_HEAD" "$1" > "$TMP/.claude/.harness/review-log/$COV_HEAD.json"; }

# 11. files_reviewed MISSING a changed file → REFUSE (no write)
cov_log '["cov1.txt"]'
rm -f "$COV_DONE"
ERR=$(printf '%s' "$cov_payload" | bash "$SCRIPT" "sess-abc123" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$COV_DONE" ] && echo "$ERR" | grep -qi "did not cover"; then
  ok "coverage: files_reviewed missing a changed file refused, no write, clear message"
else
  bad "coverage-gap refusal failed (rc=$RC, file=$( [ -f "$COV_DONE" ] && echo present || echo absent ), err=$ERR)"
fi

# 12. files_reviewed covers ALL changed files → WRITES
cov_log '["cov1.txt","cov2.txt"]'
rm -f "$COV_DONE"
OUTPATH=$(printf '%s' "$cov_payload" | bash "$SCRIPT" "sess-abc123")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$COV_DONE" ] && [ "$OUTPATH" = "$COV_DONE" ]; then
  ok "coverage: files_reviewed covers all changed files writes normally"
else
  bad "coverage-full write failed (rc=$RC, out=$OUTPATH)"
fi

# --- 13a. SESSION mode, session id with NO baselines/<id>.sha → REFUSE --------
# The dead-id backstop (Defect A): in session mode the done-state key is
# session-<id>, the SAME key the gate reads. An id with no .sha is one the gate
# never keys off → silent forever-block. The writer must REFUSE (nonzero, no
# write) and name the fix. Tests+lint green + a HEAD review-log present, so the
# refusal is unambiguously on the dead id, not another gate.
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["cov1.txt","cov2.txt"],"findings":[],"open_findings":0}\n' "$COV_HEAD" > "$TMP/.claude/.harness/review-log/$COV_HEAD.json"
DEAD_PAYLOAD='{"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"lint":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'
OUT13A="$TMP/.claude/.harness/done-state/session-sess-dead.json"
rm -f "$OUT13A"
ERR=$(printf '%s' "$DEAD_PAYLOAD" | bash "$SCRIPT" "sess-dead" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$OUT13A" ] && echo "$ERR" | grep -qi "no baselines/sess-dead.sha"; then
  ok "dead id (session mode, no .sha) refused, no write, names the fix"
else
  bad "dead-id refusal failed (rc=$RC, file=$( [ -f "$OUT13A" ] && echo present || echo absent ), err=$ERR)"
fi

# --- 13b. same id, matching .sha present → WRITES ----------------------------
# Confirms the backstop only rejects DEAD ids: seed the .sha and the same id now
# writes (files_reviewed covers the changeset from cases 11/12).
echo "$COV_HEAD" > "$TMP/.claude/.harness/baselines/sess-dead.sha"
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["cov1.txt","cov2.txt"],"findings":[]}\n' "$COV_HEAD" > "$TMP/.claude/.harness/review-log/$COV_HEAD.json"
rm -f "$OUT13A"
OUTPATH=$(printf '%s' "$DEAD_PAYLOAD" | bash "$SCRIPT" "sess-dead")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$OUT13A" ] && [ "$OUTPATH" = "$OUT13A" ]; then
  ok "matching id (session mode, .sha present) writes normally"
else
  bad "matching-id write failed (rc=$RC, out=$OUTPATH)"
fi

# --- 14. plan fold: valid done-plan for the task_key → done-state gets .plan --
# Seed a valid done-plan keyed by the session task_key and confirm the writer
# folds it into the done-state as .plan (evidence). Uses sess-abc123 (base=REAL..
# well, COV_HEAD is HEAD now; its files_reviewed covers the changeset).
mkdir -p "$TMP/.claude/.harness/done-plan"
PLAN_TASK_KEY="session-sess-plan"
seed_sha "sess-plan"
echo "$COV_HEAD" > "$TMP/.claude/.harness/baselines/sess-plan.sha"
cat > "$TMP/.claude/.harness/done-plan/${PLAN_TASK_KEY}.json" <<JSON
{"contract_version":1,"task_key":"${PLAN_TASK_KEY}","steps":[{"id":"0","title":"Preflight","status":"applicable","ref":"dod-protocol.md#step-0"},{"id":"2-lint","title":"Lint","status":"excluded","ref":"dod-protocol.md#step-2-lint","reason":"no lint command configured"}]}
JSON
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["cov1.txt","cov2.txt"],"findings":[]}\n' "$COV_HEAD" > "$TMP/.claude/.harness/review-log/$COV_HEAD.json"
PLAN_DONE="$TMP/.claude/.harness/done-state/${PLAN_TASK_KEY}.json"
rm -f "$PLAN_DONE"
OUTPATH=$(printf '%s' "$cov_payload" | bash "$SCRIPT" "sess-plan")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$PLAN_DONE" ] && jq -e '.plan.contract_version == 1 and (.plan.steps|length==2)' "$PLAN_DONE" >/dev/null 2>&1; then
  ok "valid done-plan folded into done-state .plan"
else
  bad "plan fold failed (rc=$RC, out=$OUTPATH, plan=$(jq -c '.plan' "$PLAN_DONE" 2>/dev/null))"
fi
# the folded done-state still validates against the (extended) done-state schema.
if hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$PLAN_DONE" >/dev/null 2>&1; then
  ok "done-state WITH .plan validates against done-state schema"
else
  bad "done-state with plan failed schema: $(hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$PLAN_DONE" 2>&1)"
fi

# --- 15. NO plan file → writer succeeds, NO .plan (fail-safe) ---------------
seed_sha "sess-noplan"
echo "$COV_HEAD" > "$TMP/.claude/.harness/baselines/sess-noplan.sha"
rm -f "$TMP/.claude/.harness/done-plan/session-sess-noplan.json"
NOPLAN_DONE="$TMP/.claude/.harness/done-state/session-sess-noplan.json"
rm -f "$NOPLAN_DONE"
OUTPATH=$(printf '%s' "$cov_payload" | bash "$SCRIPT" "sess-noplan")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$NOPLAN_DONE" ] && jq -e 'has("plan") | not' "$NOPLAN_DONE" >/dev/null 2>&1; then
  ok "no plan file → writer succeeds, no .plan field (fail-safe)"
else
  bad "no-plan case failed (rc=$RC, has_plan=$(jq -c 'has("plan")' "$NOPLAN_DONE" 2>/dev/null))"
fi

# --- 16. malformed plan file → writer succeeds, NO .plan --------------------
seed_sha "sess-badplan"
echo "$COV_HEAD" > "$TMP/.claude/.harness/baselines/sess-badplan.sha"
printf 'not json{' > "$TMP/.claude/.harness/done-plan/session-sess-badplan.json"
BADPLAN_DONE="$TMP/.claude/.harness/done-state/session-sess-badplan.json"
rm -f "$BADPLAN_DONE"
OUTPATH=$(printf '%s' "$cov_payload" | bash "$SCRIPT" "sess-badplan")
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$BADPLAN_DONE" ] && jq -e 'has("plan") | not' "$BADPLAN_DONE" >/dev/null 2>&1; then
  ok "malformed plan file → writer succeeds, no .plan field (evidence, never precondition)"
else
  bad "malformed-plan case failed (rc=$RC, has_plan=$(jq -c 'has("plan")' "$BADPLAN_DONE" 2>/dev/null))"
fi

echo
echo "test-write-state: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
