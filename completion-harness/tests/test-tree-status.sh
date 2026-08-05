#!/bin/bash
#
# Tests for the P0 fixes: baseline-relative tree classifier (hc_tree_status),
# the deadlock resolution + not-easier-to-pass invariants at the GATE and the
# WRITER, untracked_policy=strict, done-preflight.sh, and baseline-snapshot's
# .dirty recording + inert marker + systemMessage.
#
# Runs against the source-tree scripts (completion-harness/scripts/, resolved
# relative to this test) — no install needed. Each case builds an isolated
# throwaway git repo with CLAUDE_PROJECT_DIR pointed at it.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"

GATE="$SCRIPTS/done-gate.sh"
WRITER="$SCRIPTS/done-write-state.sh"
PREFLIGHT="$SCRIPTS/done-preflight.sh"
SNAPSHOT="$SCRIPTS/baseline-snapshot.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

# is_block <stdout> → 0 if the gate stdout is a block decision.
is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# Build a fresh repo on `main` (trunk → session mode, task_key=session-<sid>),
# on top of the shared fixture's root commit, PLUS a tracked a.js (some cases
# below modify it in place to exercise the "modified tracked file" path).
# Echoes the repo path.
make_repo() {
  local r; r=$(hc__test_make_repo)
  # This suite overwrites .claude/done-config.json directly (uncommitted) at
  # many call sites to exercise config variants. Untrack it and gitignore the
  # whole .claude/ dir (not just .harness/, the shared fixture's default) so
  # those edits are never mistaken for a dirty tree.
  git -C "$r" rm -q --cached .claude/done-config.json
  printf '.claude/\n' > "$r/.gitignore"
  printf 'a\n' > "$r/a.js"
  git -C "$r" add -A
  git -C "$r" commit -qm c1
  printf '%s' "$r"
}

# Seed a green done-state + review-log for HEAD (session-keyed), so the gate
# reaches Step 6 (tree check) and, if that passes, ALLOWS.
seed_green_done() {
  local r="$1" sid="$2"
  local head; head=$(git -C "$r" rev-parse HEAD)
  printf '%s\n' "$head" > "$r/.claude/.harness/baselines/$sid.sha"
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":[],"open_findings":0}\n' "$head" \
    > "$r/.claude/.harness/review-log/$head.json"
  printf '{"contract_version":1,"session_id":"%s","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$sid" "$head" \
    > "$r/.claude/.harness/done-state/session-$sid.json"
}

# run_gate <repo> <session_id> — feed the session id on stdin like test-gate.sh
# so the gate resolves the same baseline/.dirty and done-state this suite seeds.
run_gate() {
  printf '{"session_id":"%s","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null
}

echo "== test-tree-status =="

# ============================================================================
# INVARIANT 1 — DEADLOCK RESOLVED.
# A pre-existing untracked file present at baseline must NOT block the gate once
# a valid green done-state exists. (verified_sha==HEAD, tree has ONLY the
# pre-existing untracked file → baseline-relative → warning, not blocker.)
# ============================================================================
R=$(make_repo); SID=deadlock
# pre-existing untracked file (top-level, NOT under .claude/)
printf 'pre\n' > "$R/preexisting.js"
# baseline .dirty records it as present at session start
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"
seed_green_done "$R" "$SID"
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  bad "DEADLOCK: pre-existing untracked file blocked the gate (should ALLOW). out=$OUT"
else
  ok "DEADLOCK RESOLVED: pre-existing untracked file at baseline → gate ALLOWs"
fi
# NEW: the ALLOW output must not mention the pre-existing file (never surfaced).
if printf '%s' "$OUT" | grep -q "preexisting.js"; then
  bad "ALLOW output surfaced the pre-existing file (should be silent). out=$OUT"
else
  ok "NO-SURFACE: ALLOW output makes no mention of the pre-existing file"
fi
rm -rf "$R"

# ============================================================================
# NO-SURFACE (DISCRIMINATING) — an INTRODUCED blocker AND a pre-existing entry
# coexist. The gate BLOCKs (introduced blocker) and the block reason must name
# the introduced file but must NOT mention the pre-existing entry. This is the
# case that exercises hc_tree_remediation's dropped "(pre-existing...)" clause:
# it FAILS on the old code (clause present) and PASSES on the new.
# ============================================================================
R=$(make_repo); SID=nosurface
printf 'pre\n' > "$R/preexisting.js"                        # pre-existing untracked
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"  # recorded at baseline
seed_green_done "$R" "$SID"
printf 'introduced\n' > "$R/introduced.js"                  # introduced blocker (after baseline)
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT" && printf '%s' "$OUT" | grep -q "introduced.js"; then
  ok "NO-SURFACE: gate BLOCKs and block reason names the introduced file"
else
  bad "gate did not block/name introduced file with a coexisting pre-existing entry. out=$OUT"
fi
if printf '%s' "$OUT" | grep -qi "pre-existing\|only warned\|preexisting.js"; then
  bad "block reason surfaced the pre-existing entry (should be silent). out=$OUT"
else
  ok "NO-SURFACE: block reason makes NO mention of the pre-existing entry"
fi
rm -rf "$R"

# ============================================================================
# INVARIANT 2a — NOT EASIER: a NEW untracked file (created after baseline) BLOCKS
# ============================================================================
R=$(make_repo); SID=newuntracked
# baseline recorded CLEAN (no changes at session start)
: > "$R/.claude/.harness/baselines/$SID.dirty"
seed_green_done "$R" "$SID"
# agent introduces a new untracked file AFTER baseline
printf 'new\n' > "$R/introduced.js"
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  ok "NOT EASIER: new untracked file (introduced this session) → gate BLOCKs"
else
  bad "new untracked file did NOT block (invariant 2 violated). out=$OUT"
fi
rm -rf "$R"

# ============================================================================
# INVARIANT 2b — NOT EASIER: a tracked file MODIFIED since baseline BLOCKS
# ============================================================================
R=$(make_repo); SID=trackedmod
: > "$R/.claude/.harness/baselines/$SID.dirty"   # clean at baseline
seed_green_done "$R" "$SID"
printf 'modified\n' > "$R/a.js"                 # modify a tracked file now
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  ok "NOT EASIER: tracked-modified-since-baseline file → gate BLOCKs"
else
  bad "tracked-modified file did NOT block (invariant 2 violated). out=$OUT"
fi
rm -rf "$R"

# ============================================================================
# untracked_policy = "strict" → ANY untracked file blocks even if pre-existing
# ============================================================================
R=$(make_repo); SID=strict
printf 'pre\n' > "$R/preexisting.js"
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"  # recorded at baseline
# set strict policy
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{},"overrides":{},"baseline_snapshot":false,"untracked_policy":"strict"}
JSON
seed_green_done "$R" "$SID"
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  ok "STRICT: pre-existing untracked file blocks under untracked_policy=strict"
else
  bad "strict policy did NOT block pre-existing untracked file. out=$OUT"
fi
rm -rf "$R"

# ============================================================================
# WRITER PARITY — refuses on introduced blocker, writes when only pre-existing.
# The writer runs the SOURCE script path via the installed copy; use the
# installed WRITER against a controlled repo. It requires a green review-log +
# green payload to reach the tree decision.
# ============================================================================
GREEN_PAYLOAD='{"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}'

# 5a — writer REFUSES when there is an introduced blocker (new untracked file).
R=$(make_repo); SID=wr-block
HEAD=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$HEAD" > "$R/.claude/.harness/baselines/$SID.sha"
: > "$R/.claude/.harness/baselines/$SID.dirty"    # clean at baseline
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":[],"open_findings":0}\n' "$HEAD" > "$R/.claude/.harness/review-log/$HEAD.json"
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{},"overrides":{},"baseline_snapshot":false,"untracked_policy":"baseline"}
JSON
printf 'introduced\n' > "$R/new.js"              # introduced blocker
ERR=$(printf '%s' "$GREEN_PAYLOAD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITER" "$SID" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && [ ! -f "$R/.claude/.harness/done-state/session-$SID.json" ] && echo "$ERR" | grep -qi "dirty"; then
  ok "WRITER: refuses (nonzero, no write, 'dirty' msg) on introduced blocker"
else
  bad "writer did not refuse on introduced blocker (rc=$RC, err=$ERR)"
fi
rm -rf "$R"

# 5b — writer WRITES when only a pre-existing (warned) entry is present.
R=$(make_repo); SID=wr-ok
printf 'pre\n' > "$R/preexisting.js"             # pre-existing untracked file
HEAD=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$HEAD" > "$R/.claude/.harness/baselines/$SID.sha"
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"  # recorded at baseline
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":[],"open_findings":0}\n' "$HEAD" > "$R/.claude/.harness/review-log/$HEAD.json"
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{},"overrides":{},"baseline_snapshot":false,"untracked_policy":"baseline"}
JSON
OUTP=$(printf '%s' "$GREEN_PAYLOAD" | CLAUDE_PROJECT_DIR="$R" bash "$WRITER" "$SID" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && [ -f "$R/.claude/.harness/done-state/session-$SID.json" ]; then
  ok "WRITER: writes when only a pre-existing (warned) entry is present"
  if jq -e '.tree_clean == true' "$R/.claude/.harness/done-state/session-$SID.json" >/dev/null 2>&1; then
    ok "WRITER: tree_clean=true when only warnings (no blockers)"
  else
    bad "tree_clean not true when only pre-existing warnings"
  fi
else
  bad "writer refused despite only pre-existing warning (rc=$RC, out=$OUTP)"
fi
rm -rf "$R"

# ============================================================================
# PREFLIGHT — non-zero + names the problem when baseline_snapshot:true & no test.
# ============================================================================
R=$(make_repo); SID=pf-hard
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/$SID.sha"
: > "$R/.claude/.harness/baselines/$SID.dirty"
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{},"overrides":{},"baseline_snapshot":true,"untracked_policy":"baseline"}
JSON
OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$PREFLIGHT" "$SID" 2>&1)
RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "baseline_snapshot enabled but no test command"; then
  ok "PREFLIGHT: nonzero + names the inert-snapshot problem"
else
  bad "preflight did not fail/name problem (rc=$RC): $OUT"
fi
rm -rf "$R"

# PREFLIGHT — winnable (exit 0) on a clean fixture with a test command.
R=$(make_repo); SID=pf-ok
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/$SID.sha"
: > "$R/.claude/.harness/baselines/$SID.dirty"
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{"test":"true"},"overrides":{},"baseline_snapshot":true,"untracked_policy":"baseline"}
JSON
OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$PREFLIGHT" "$SID" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qi "winnable"; then
  ok "PREFLIGHT: exit 0 (winnable) on a clean fixture with a test command"
else
  bad "preflight not winnable on clean fixture (rc=$RC): $OUT"
fi
rm -rf "$R"

# PREFLIGHT NO-SURFACE (DISCRIMINATING) — a pre-existing entry at baseline must
# NOT be surfaced in the report. Winnable, and output has NO "pre-existing" /
# "warned" line. FAILS on old code (it printed the warning line), PASSES on new.
R=$(make_repo); SID=pf-nosurface
printf 'pre\n' > "$R/preexisting.js"                        # pre-existing untracked
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/$SID.sha"
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"  # recorded at baseline
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{"test":"true"},"overrides":{},"baseline_snapshot":false,"untracked_policy":"baseline"}
JSON
OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$PREFLIGHT" "$SID" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qi "winnable"; then
  ok "PREFLIGHT: winnable with a pre-existing entry at baseline"
else
  bad "preflight not winnable with pre-existing entry (rc=$RC): $OUT"
fi
if echo "$OUT" | grep -qi "pre-existing\|warned\|preexisting.js"; then
  bad "PREFLIGHT surfaced the pre-existing entry (should be silent). out=$OUT"
else
  ok "PREFLIGHT NO-SURFACE: report makes NO mention of pre-existing entries"
fi
rm -rf "$R"

# PREFLIGHT — does NOT seed the tree baseline when absent; reports + says restart.
# (Regression guard for Invariant 2: preflight can run after edits, so seeding
# live porcelain here would whitelist the agent's own work. Only SessionStart
# may pin the baseline.)
R=$(make_repo); SID=pf-seed
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/$SID.sha"
# NOTE: no .dirty file present (session mode → baselines/<sid>.dirty)
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{"test":"true"},"overrides":{},"baseline_snapshot":true,"untracked_policy":"baseline"}
JSON
OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$PREFLIGHT" "$SID" 2>&1)
RC=$?
if [ ! -f "$R/.claude/.harness/baselines/$SID.dirty" ] \
   && echo "$OUT" | grep -qi "Restart the session" \
   && ! echo "$OUT" | grep -qi "SEEDED"; then
  ok "PREFLIGHT: does NOT seed tree baseline when absent; tells user to restart"
else
  bad "preflight seeded or did not report missing baseline correctly: $OUT"
fi
# Defect B: a missing tree baseline is a guaranteed deadlock, so preflight must
# BLOCK (nonzero + NOT WINNABLE), not merely warn.
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -qi "NOT WINNABLE"; then
  ok "PREFLIGHT: missing tree baseline is BLOCKING (nonzero + NOT WINNABLE)"
else
  bad "preflight did not BLOCK on missing tree baseline (rc=$RC): $OUT"
fi
rm -rf "$R"

# PREFLIGHT DIVERGED BASELINE (P2-a, #6) — session mode, HEAD moved past the
# baseline but 0 commits are session-authored → WARN loudly + author list, yet
# still WINNABLE (non-blocking). Build a FOREIGN commit atop the baseline so the
# Chunk-A attribution counts 0 authored this session.
R=$(make_repo); SID=pf-diverged
PF_BASE=$(git -C "$R" rev-parse HEAD)          # baseline = c1
# Foreign commit (different committer identity) atop the baseline.
GIT_COMMITTER_EMAIL="foreign@other.test" GIT_COMMITTER_NAME="Foreign Dev" \
  GIT_AUTHOR_EMAIL="foreign@other.test" GIT_AUTHOR_NAME="Foreign Dev" \
  bash -c "cd '$R' && echo x > foreign.js && git add foreign.js && git commit -qm foreign"
printf '%s\n' "$PF_BASE" > "$R/.claude/.harness/baselines/$SID.sha"
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"   # clean baseline
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{"test":"true"},"overrides":{},"baseline_snapshot":false,"untracked_policy":"baseline"}
JSON
OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$PREFLIGHT" "$SID" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -qi "winnable"; then
  ok "PREFLIGHT DIVERGED: verdict stays winnable (non-blocking)"
else
  bad "preflight diverged-baseline blocked unexpectedly (rc=$RC): $OUT"
fi
if echo "$OUT" | grep -qi "DIVERGED BASELINE"; then
  ok "PREFLIGHT DIVERGED: emits the divergence warning"
else
  bad "preflight did not warn on diverged baseline: $OUT"
fi
if echo "$OUT" | grep -qi "Foreign Dev"; then
  ok "PREFLIGHT DIVERGED: warning names the foreign author"
else
  bad "preflight divergence warning missing author list: $OUT"
fi
rm -rf "$R"

# ============================================================================
# BASELINE-SNAPSHOT — records <sid>.dirty; when enabled-but-no-test → inert
# marker + systemMessage. Uses a repo where done-detect finds NO test command.
# ============================================================================
R=$(make_repo)
# config: snapshot enabled, no test cmd, and NO detectable project (no
# package.json/Cargo/etc), so detection cannot seed a test command → inert.
cat > "$R/.claude/done-config.json" <<'JSON'
{"source_fingerprint":"x","detected":{},"overrides":{},"baseline_snapshot":true,"untracked_policy":"baseline"}
JSON
HEAD=$(git -C "$R" rev-parse HEAD)
OUT=$(printf '{"session_id":"snap1"}' | CLAUDE_PROJECT_DIR="$R" bash "$SNAPSHOT" 2>/dev/null)
# background test snapshot is not forked in the inert path, so it is synchronous.
if [ -f "$R/.claude/.harness/baselines/snap1.dirty" ]; then
  ok "BASELINE-SNAPSHOT: records <sid>.dirty"
else
  bad "baseline-snapshot did not record <sid>.dirty"
fi
# Defect A: SessionStart writes the authoritative current-session marker (the id
# the gate also derives from) so the /done skill/writer/preflight need not guess
# it via ls -t.
if [ "$(cat "$R/.claude/.harness/current-session" 2>/dev/null)" = "snap1" ]; then
  ok "BASELINE-SNAPSHOT: writes current-session marker with the real session id"
else
  bad "baseline-snapshot did not write current-session marker: $(cat "$R/.claude/.harness/current-session" 2>/dev/null)"
fi
if jq -e '.status == "inert"' "$R/.claude/.harness/baselines/$HEAD.tests.json" >/dev/null 2>&1; then
  ok "BASELINE-SNAPSHOT: writes inert marker when enabled but no test command"
else
  bad "no inert marker written: $(cat "$R/.claude/.harness/baselines/$HEAD.tests.json" 2>/dev/null)"
fi
if printf '%s' "$OUT" | jq -e '.systemMessage | test("could not run"; "i")' >/dev/null 2>&1; then
  ok "BASELINE-SNAPSHOT: emits a systemMessage about the inert snapshot"
else
  bad "no inert systemMessage emitted: $OUT"
fi
# stdout must be a single valid JSON object (not two concatenated).
if printf '%s' "$OUT" | jq -e . >/dev/null 2>&1; then
  ok "BASELINE-SNAPSHOT: stdout is a single valid JSON object"
else
  bad "baseline-snapshot stdout is not valid JSON: $OUT"
fi
rm -rf "$R"

# ============================================================================
# FRESH SESSION (session mode) — SessionStart ALWAYS records both the
# current-session marker AND a .dirty for the resolved baseline, before any edit,
# even when the tree is clean. (Defect A marker + Defect B unconditional .dirty.)
# A missing .dirty would make hc_tree_status treat every pre-existing file as
# introduced → deadlock; a missing marker would force the ls -t id heuristic.
# ============================================================================
R=$(make_repo)
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{"test":"true"},"overrides":{},"baseline_snapshot":false,"untracked_policy":"baseline"}
JSON
printf '{"session_id":"%s"}' "fresh1" | CLAUDE_PROJECT_DIR="$R" bash "$SNAPSHOT" >/dev/null 2>&1
if [ -f "$R/.claude/.harness/baselines/fresh1.dirty" ]; then
  ok "FRESH SESSION: .dirty captured for the resolved baseline (session mode)"
else
  bad "fresh session: no .dirty captured (deadlock risk)"
fi
if [ -f "$R/.claude/.harness/baselines/fresh1.sha" ]; then
  ok "FRESH SESSION: baseline .sha recorded"
else
  bad "fresh session: no .sha recorded"
fi
if [ "$(cat "$R/.claude/.harness/current-session" 2>/dev/null)" = "fresh1" ]; then
  ok "FRESH SESSION: current-session marker == this session's id"
else
  bad "fresh session: current-session marker wrong: $(cat "$R/.claude/.harness/current-session" 2>/dev/null)"
fi
rm -rf "$R"

# ============================================================================
# TASK-MODE INVARIANT 2 (reviewer's carryover scenario) — an agent's OWN
# uncommitted file introduced after the task fork must BLOCK the gate, even in a
# LATER session whose SessionStart snapshots that file into its live porcelain.
#
# The tree baseline is pinned ONCE per task (tree-base/br-<branch>.dirty) at the
# first session on the branch and is NEVER re-seeded by later sessions — so a
# session-B SessionStart cannot whitelist foo.js as "pre-existing".
#
# OLD (buggy) code keyed .dirty by raw session id and re-seeded it every
# SessionStart → session B's snapshot recorded `?? foo.js` as pre-existing →
# WARNING → gate ALLOWED. This case FAILS on the old code and PASSES on the new.
# ============================================================================
# make_task_repo: fresh repo, trunk main + confident-trunk config, on branch feat
# (branch != trunk → task mode). Echoes the repo path.
make_task_repo() {
  local r; r=$(hc__test_mktemp_d)
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  printf '.claude/\n' > "$r/.gitignore"
  printf 'a\n' > "$r/a.js"
  git -C "$r" add -A
  git -C "$r" commit -qm c1
  mkdir -p "$r/.claude/.harness/baselines" "$r/.claude/.harness/done-state" "$r/.claude/.harness/review-log"
  # Confident trunk so hc_resolve picks TASK mode on a non-trunk branch.
  cat > "$r/.claude/done-config.json" <<'JSON'
{"detected":{},"overrides":{},"baseline_snapshot":false,"trunk":"main","untracked_policy":"baseline"}
JSON
  git -C "$r" checkout -q -b feat
  printf '%s' "$r"
}

# run_snapshot <repo> <session_id> — drive the real SessionStart hook so pinning
# (and, on old code, re-seeding) is exercised end-to-end rather than hand-faked.
run_snapshot() {
  printf '{"session_id":"%s"}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$SNAPSHOT" >/dev/null 2>&1
}

# seed_green_done_task: green done-state keyed by the TASK key (br-feat, what the
# gate reads in task mode) + a HEAD-keyed review-log, so the gate reaches Step 6.
seed_green_done_task() {
  local r="$1" sid="$2"
  local head; head=$(git -C "$r" rev-parse HEAD)
  printf '{"reviewed_sha":"%s","findings":[],"open_findings":0}\n' "$head" \
    > "$r/.claude/.harness/review-log/$head.json"
  printf '{"session_id":"%s","verified_sha":"%s","tree_clean":true,"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$sid" "$head" \
    > "$r/.claude/.harness/done-state/br-feat.json"
}

R=$(make_task_repo)
# Session A: SessionStart pins the task tree-base (clean tree at fork), then the
# agent creates foo.js (its own work) and leaves it uncommitted.
run_snapshot "$R" sessA
printf 'foo\n' > "$R/foo.js"
# Session B: a DIFFERENT session id runs SessionStart AFTER foo.js exists. On
# old code this re-seeds sessB.dirty with `?? foo.js`; on new code the pinned
# tree-base/br-feat.dirty is untouched.
run_snapshot "$R" sessB
# The pin must remain task-scoped and must NOT contain foo.js.
if [ -f "$R/.claude/.harness/tree-base/br-feat.dirty" ] \
   && ! grep -q 'foo.js' "$R/.claude/.harness/tree-base/br-feat.dirty" 2>/dev/null; then
  ok "TASK PIN: tree-base/br-feat.dirty pinned once at fork, does NOT contain foo.js"
else
  bad "task tree-base missing or re-seeded with foo.js: $(cat "$R/.claude/.harness/tree-base/br-feat.dirty" 2>/dev/null)"
fi
# Session B commits some REAL work (moves HEAD past the fork so the gate reaches
# Step 6), writes a green done-state under br-feat + a HEAD review-log, and
# leaves foo.js uncommitted.
printf 'real\n' > "$R/real.js"
git -C "$R" add real.js
git -C "$R" commit -qm "real work"
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/sessB.sha"
seed_green_done_task "$R" sessB
# The gate MUST block on the agent's own uncommitted foo.js.
OUT=$(run_gate "$R" sessB)
if is_block "$OUT"; then
  ok "TASK INVARIANT 2: agent's own uncommitted foo.js (introduced after fork) BLOCKS across sessions"
else
  bad "CARRYOVER BUG: foo.js whitelisted by session B → gate ALLOWED. out=$OUT"
fi
rm -rf "$R"

# ============================================================================
# TASK PIN NOT RE-SEEDED — a second session must not overwrite the task pin.
# Pin content recorded at session A must be byte-identical after session B runs
# SessionStart with a different, dirtier tree.
# ============================================================================
R=$(make_task_repo)
run_snapshot "$R" sA
PIN="$R/.claude/.harness/tree-base/br-feat.dirty"
BEFORE=$(cat "$PIN" 2>/dev/null)
# Dirty the tree, then run a second session's SessionStart.
printf 'x\n' > "$R/introduced-later.js"
run_snapshot "$R" sB
AFTER=$(cat "$PIN" 2>/dev/null)
if [ "$BEFORE" = "$AFTER" ]; then
  ok "TASK PIN: not re-seeded by a second session (content unchanged)"
else
  bad "task pin was re-seeded by session B (before='$BEFORE' after='$AFTER')"
fi
rm -rf "$R"

# ============================================================================
# AUTO-BRANCH INVARIANT 2 (the auto_branch:true path — opt-in since the default flip) — a session that
# starts on trunk, then auto-branches mid-session on the first edit, must pin
# its CLEAN pre-edit tree baseline at checkout time. Otherwise a later session's
# first task-mode SessionStart would seed the pin from live porcelain (already
# holding session A's WIP) and whitelist it → Invariant 2 violated.
#
# Drives the REAL hooks (baseline-snapshot + auto-branch) end-to-end. FAILS on
# code that only pins in baseline-snapshot.sh; PASSES once auto-branch.sh pins.
# ============================================================================
PRE_HOOK="$SCRIPTS/auto-branch.sh"

R=$(make_repo)   # on trunk `main`; the fixture declares auto_branch:true
# Confident trunk + auto_branch true (defaults, but be explicit).
cat > "$R/.claude/done-config.json" <<'JSON'
{"detected":{},"overrides":{},"baseline_snapshot":false,"trunk":"main","auto_branch":true,"branch_prefix":"task/","untracked_policy":"baseline"}
JSON
# Session A: SessionStart runs on trunk (session mode) → clean baselines/sidA.dirty.
run_snapshot "$R" sidA
# Sanity: the session-mode clean snapshot exists and is empty (clean fork).
if [ -f "$R/.claude/.harness/baselines/sidA.dirty" ] && [ ! -s "$R/.claude/.harness/baselines/sidA.dirty" ]; then
  ok "AUTO-BRANCH: session A recorded a clean pre-edit baseline (session mode)"
else
  bad "session A did not record a clean session baseline: $(cat "$R/.claude/.harness/baselines/sidA.dirty" 2>/dev/null)"
fi
# First edit fires the PreToolUse auto-branch hook (still pre-edit → clean tree).
printf '{"session_id":"sidA"}' | CLAUDE_PROJECT_DIR="$R" bash "$PRE_HOOK" >/dev/null 2>&1
BR=$(git -C "$R" branch --show-current)
KEY="br-$(printf '%s' "$BR" | sed 's#[^A-Za-z0-9_.-]#-#g')"
# The task tree-base must now be pinned CLEAN (copied from sidA's snapshot).
if [ -f "$R/.claude/.harness/tree-base/$KEY.dirty" ] && [ ! -s "$R/.claude/.harness/tree-base/$KEY.dirty" ]; then
  ok "AUTO-BRANCH: pinned tree-base/$KEY.dirty CLEAN at checkout time"
else
  bad "auto-branch did not pin a clean task tree-base ($KEY): $(cat "$R/.claude/.harness/tree-base/$KEY.dirty" 2>/dev/null)"
fi
# Agent now creates foo.js (its own work), uncommitted.
printf 'foo\n' > "$R/foo.js"
# Session B: a DIFFERENT session's first task-mode SessionStart. Must NOT re-seed
# the pin (it already exists) → foo.js stays absent from the pin.
run_snapshot "$R" sidB
if [ -f "$R/.claude/.harness/tree-base/$KEY.dirty" ] && ! grep -q 'foo.js' "$R/.claude/.harness/tree-base/$KEY.dirty" 2>/dev/null; then
  ok "AUTO-BRANCH: session B did NOT re-seed the pin with foo.js"
else
  bad "session B re-seeded the auto-branch pin with foo.js: $(cat "$R/.claude/.harness/tree-base/$KEY.dirty" 2>/dev/null)"
fi
# Commit real work (move HEAD past fork), seed green done-state keyed by the
# auto-branch KEY + a HEAD review-log, leave foo.js uncommitted.
printf 'real\n' > "$R/real.js"
git -C "$R" add real.js
git -C "$R" commit -qm "real work"
HEADB=$(git -C "$R" rev-parse HEAD)
printf '%s\n' "$HEADB" > "$R/.claude/.harness/baselines/sidB.sha"
printf '{"reviewed_sha":"%s","findings":[],"open_findings":0}\n' "$HEADB" \
  > "$R/.claude/.harness/review-log/$HEADB.json"
printf '{"session_id":"sidB","verified_sha":"%s","tree_clean":true,"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$HEADB" \
  > "$R/.claude/.harness/done-state/$KEY.json"
OUT=$(run_gate "$R" sidB)
if is_block "$OUT"; then
  ok "AUTO-BRANCH INVARIANT 2: agent's own uncommitted foo.js BLOCKS across sessions"
else
  bad "AUTO-BRANCH CARRYOVER BUG: foo.js whitelisted → gate ALLOWED. out=$OUT"
fi
rm -rf "$R"

# --- D1 regression: harness-managed .claude/done-config.json never blocks ----
# done-detect rewrites this file DURING /done (contract_version auto-upgrade),
# which must not count as introduced work (that caused a commit→re-review
# cascade). A TRACKED, modified done-config.json must classify as WARNING, not
# BLOCKER; a genuinely introduced file alongside it must still BLOCK.
R=$(mktemp -d)
git -C "$R" init -q -b main
git -C "$R" config user.email t@t; git -C "$R" config user.name t
printf '.claude/.harness/\n' > "$R/.gitignore"   # track .claude/done-config.json
mkdir -p "$R/.claude/.harness/baselines"
printf '{"untracked_policy":"baseline"}\n' > "$R/.claude/done-config.json"
printf 'a\n' > "$R/a.js"
git -C "$R" add -A; git -C "$R" commit -qm c1
: > "$R/.claude/.harness/baselines/sidC.dirty"                     # empty tree baseline
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/sidC.sha"
printf '{"untracked_policy":"baseline","contract_version":1}\n' > "$R/.claude/done-config.json"  # detect-style rewrite
(
  cd "$R"
  export CLAUDE_PROJECT_DIR="$R"
  source "$SCRIPTS/harness-common.sh"
  hc_resolve sidC
  hc_tree_status sidC
  printf '%s' "$HC_TREE_BLOCKERS" | grep -Fq 'done-config.json' && exit 3   # must NOT block
  printf '%s' "$HC_TREE_WARNINGS" | grep -Fq 'done-config.json' || exit 4   # should warn
  exit 0
)
case $? in
  0) ok "D1: modified tracked .claude/done-config.json → WARNING, not blocker" ;;
  3) bad "D1: done-config.json BLOCKED (cascade defect not fixed)" ;;
  *) bad "D1: done-config.json not classified as warning" ;;
esac
# a real introduced file still blocks even with done-config.json also dirty
printf 'new\n' > "$R/introduced.js"
(
  cd "$R"; export CLAUDE_PROJECT_DIR="$R"
  source "$SCRIPTS/harness-common.sh"
  hc_resolve sidC; hc_tree_status sidC
  printf '%s' "$HC_TREE_BLOCKERS" | grep -Fq 'introduced.js'
) && ok "D1: genuine introduced file STILL blocks (exemption is scoped)" \
   || bad "D1: introduced file no longer blocks (exemption too broad)"
rm -rf "$R"

# ============================================================================
# D2 — SELF-OWNED PATHS: the harness ignores its own files, tracked or not.
#
# D1 above covers one literal path. D2 covers the generalised rule
# (hc_is_harness_own_path) that every classifying site now shares: the state
# directory and everything under it, plus the config file — and NOTHING else
# under .claude/, which is shared ground with the user and other tools.
#
# NON-VACUITY. The other fixtures in this suite gitignore ALL of .claude/, so a
# path under it never reaches porcelain and an "does not block" assertion would
# pass for the wrong reason. Every D2 case therefore gitignores only what
# install.sh really adds (.claude/.harness/, or nothing at all) and ASSERTS the
# expected porcelain line is actually present before judging the verdict.
# ============================================================================
echo "-- D2: harness-owned paths --"

# make_selfown_repo → a repo that TRACKS .claude/ content (only the state dir is
# ignored, exactly what install.sh adds), with a committed done-config.json and
# a session baseline recording a CLEAN tree. Echoes the repo path.
make_selfown_repo() {
  local r; r=$(hc__test_mktemp_d)
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t; git -C "$r" config user.name t
  printf '.claude/.harness/\n' > "$r/.gitignore"
  mkdir -p "$r/.claude/.harness/baselines" "$r/.claude/.harness/done-state" \
           "$r/.claude/.harness/review-log" "$r/.claude/scripts"
  printf '{"untracked_policy":"baseline"}\n' > "$r/.claude/done-config.json"
  printf 'echo gate\n' > "$r/.claude/scripts/done-gate.sh"
  printf 'a\n' > "$r/a.js"
  git -C "$r" add -A; git -C "$r" commit -qm c1
  : > "$r/.claude/.harness/baselines/$1.dirty"                  # clean at baseline
  printf '%s\n' "$(git -C "$r" rev-parse HEAD)" > "$r/.claude/.harness/baselines/$1.sha"
  printf '%s' "$r"
}

# classify <repo> <sid> <needle> → prints "BLOCK", "WARN" or "ABSENT".
classify() {
  (
    cd "$1"; export CLAUDE_PROJECT_DIR="$1"
    source "$SCRIPTS/harness-common.sh"
    hc_resolve "$2"; hc_tree_status "$2"
    if printf '%s' "$HC_TREE_BLOCKERS" | grep -Fq "$3"; then printf 'BLOCK'
    elif printf '%s' "$HC_TREE_WARNINGS" | grep -Fq "$3"; then printf 'WARN'
    else printf 'ABSENT'; fi
  )
}

# --- D2a: the predicate's matching rule, in isolation ------------------------
# Path shape only. The OWNED set is exactly two things; everything else under
# .claude/ — above all .claude/scripts/, which holds the gate itself — is NOT
# owned, or an agent could rewrite the gate without the gate noticing.
R=$(make_selfown_repo sidD2a)
PRED_OUT=$(
  cd "$R"; export CLAUDE_PROJECT_DIR="$R"
  source "$SCRIPTS/harness-common.sh"
  hc_resolve sidD2a
  for p in '.claude/done-config.json' '.claude/.harness' '.claude/.harness/' \
           '.claude/.harness/done-state/br-x.json' '.claude/.harness/baselines/s.dirty'; do
    hc_is_harness_own_path "$p" "$R" || printf 'NOTOWNED %s\n' "$p"
  done
  for p in '.claude/settings.local.json' '.claude/scripts/done-gate.sh' \
           '.claude/skills/done/SKILL.md' '.claude/contracts/shell-abi.json' \
           '.claude/dod/base-dod.md' '.claude/notes.json' '.claude' '.claude/' \
           'src/a.js' '.harness/x' 'x/.claude/.harness/y' ''; do
    hc_is_harness_own_path "$p" "$R" && printf 'OWNED %s\n' "$p"
  done
  printf 'DONE\n'
)
if printf '%s' "$PRED_OUT" | grep -q '^NOTOWNED '; then
  bad "D2a: predicate misses a harness path: $(printf '%s' "$PRED_OUT" | grep '^NOTOWNED ')"
else
  ok "D2a: predicate owns the state dir (incl. the collapsed '<dir>/' form) and the config"
fi
if printf '%s' "$PRED_OUT" | grep -q '^OWNED '; then
  bad "D2a: predicate WIDENED past what the harness owns: $(printf '%s' "$PRED_OUT" | grep '^OWNED ')"
else
  ok "D2a: predicate does NOT own .claude/scripts|skills|dod|contracts, user files, or .claude/ itself"
fi

# The verdict must not drift with ambient globals. A linked worktree lives UNDER
# the main checkout, so finish-worktree.sh asks about MAIN while HARNESS_DIR
# still points at the WORKTREE's state dir. Both state dirs are harness-owned;
# neither may be lost because of who the caller last resolved.
AMB_OUT=$(
  cd "$R"; export CLAUDE_PROJECT_DIR="$R"
  source "$SCRIPTS/harness-common.sh"
  HARNESS_DIR="$R/.worktrees/task-x/.claude/.harness"
  hc_is_harness_own_path '.claude/.harness/done-state/x.json' "$R" \
    || printf 'LOST own-state-dir\n'
  hc_is_harness_own_path '.worktrees/task-x/.claude/.harness/done-state/x.json' "$R" \
    || printf 'LOST nested-state-dir\n'
  HARNESS_DIR="$R/evil"
  hc_is_harness_own_path 'evil/x' "$R" && printf 'WIDENED evil\n'
  printf 'DONE\n'
)
case "$AMB_OUT" in
  DONE*) ok "D2a: verdict is stable under a foreign HARNESS_DIR (worktree nested in main)" ;;
  *)     bad "D2a: HARNESS_DIR drift: $(printf '%s' "$AMB_OUT" | grep -v '^DONE$')" ;;
esac
rm -rf "$R"

# --- D2b: UNTRACKED done-config.json → never a blocker -----------------------
R=$(make_selfown_repo sidD2b)
git -C "$R" rm -q --cached .claude/done-config.json >/dev/null 2>&1
git -C "$R" commit -qm untrack-config
git -C "$R" status --porcelain | grep -Fq '?? .claude/done-config.json' \
  && ok "D2b: fixture is non-vacuous (porcelain reports the untracked config)" \
  || bad "D2b: fixture VACUOUS — the untracked config never reaches porcelain"
: > "$R/.claude/.harness/baselines/sidD2b.dirty"
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/sidD2b.sha"
case "$(classify "$R" sidD2b 'done-config.json')" in
  WARN) ok "D2b: UNTRACKED .claude/done-config.json → not a blocker" ;;
  *)    bad "D2b: untracked .claude/done-config.json was classified $(classify "$R" sidD2b 'done-config.json')" ;;
esac
rm -rf "$R"

# --- D2c: the STATE DIR, untracked and collapsed, under untracked_policy=strict
# The exemption must be evaluated BEFORE the strict-policy branch, or the very
# repos this fix is for (no install.sh run → .harness/ not gitignored) block
# forever on the harness's own bookkeeping.
R=$(make_selfown_repo sidD2c)
printf '.claude/other/\n' > "$R/.gitignore"          # .harness/ NO LONGER ignored
printf '{"untracked_policy":"strict"}\n' > "$R/.claude/done-config.json"
# Stage the two edited files BY NAME: `add -A` here would track the whole
# now-unignored .harness/ tree and the case would test nothing.
git -C "$R" add .gitignore .claude/done-config.json; git -C "$R" commit -qm strict
: > "$R/.claude/.harness/baselines/sidD2c.dirty"
printf '%s\n' "$(git -C "$R" rev-parse HEAD)" > "$R/.claude/.harness/baselines/sidD2c.sha"
git -C "$R" status --porcelain | grep -Fq '?? .claude/.harness/' \
  && ok "D2c: fixture is non-vacuous (porcelain reports the collapsed '?? .claude/.harness/')" \
  || bad "D2c: fixture VACUOUS — the state dir never reaches porcelain"
case "$(classify "$R" sidD2c '.claude/.harness/')" in
  WARN) ok "D2c: untracked state dir → not a blocker even at untracked_policy=strict" ;;
  *)    bad "D2c: state dir classified $(classify "$R" sidD2c '.claude/.harness/') at policy=strict (exemption ran after the strict branch?)" ;;
esac
rm -rf "$R"

# --- D2d: NEGATIVE — a real user file elsewhere under .claude/ STILL blocks ---
# Deliberately a .json, and deliberately NOT settings.local.json:
#   - *.md is in the default noncode_globs, so a markdown-only changeset makes
#     the gate stand down for a reason that has nothing to do with this rule;
#   - `**/.claude/settings.local.json` is a common entry in a developer's GLOBAL
#     core.excludesfile (and install.sh adds it to the repo .gitignore), so it
#     may never reach porcelain at all — the case would pass vacuously.
R=$(make_selfown_repo sidD2d)
printf '{"user":true}\n' > "$R/.claude/user-notes.json"
git -C "$R" status --porcelain | grep -Fq '?? .claude/user-notes.json' \
  && ok "D2d: fixture is non-vacuous (porcelain reports the user file)" \
  || bad "D2d: fixture VACUOUS — the user file never reaches porcelain"
case "$(classify "$R" sidD2d 'user-notes.json')" in
  BLOCK) ok "D2d: a user file under .claude/ STILL blocks (exemption is not all of .claude/)" ;;
  *)     bad "D2d: user file under .claude/ classified $(classify "$R" sidD2d 'user-notes.json') — exemption widened" ;;
esac
# and the shipped gate script itself, which install.sh mirrors into .claude/
printf 'echo pwned\n' >> "$R/.claude/scripts/done-gate.sh"
case "$(classify "$R" sidD2d 'scripts/done-gate.sh')" in
  BLOCK) ok "D2d: a modified .claude/scripts/done-gate.sh STILL blocks (green stays unforgeable)" ;;
  *)     bad "D2d: .claude/scripts/done-gate.sh classified $(classify "$R" sidD2d 'scripts/done-gate.sh') — the gate could be rewritten unnoticed" ;;
esac
rm -rf "$R"

# --- D2e: WRITER AND GATE AGREE on a self-owned path -------------------------
# Both classify tree state; divergence here has caused a silent forever-block
# twice. With ONLY harness-owned dirt present the gate must ALLOW and the writer
# must not refuse for dirt; the tracked config is modified, so this exercises
# the tracked case end to end.
R=$(make_selfown_repo sidD2e)
seed_green_done "$R" sidD2e
printf '{"untracked_policy":"baseline","contract_version":1}\n' > "$R/.claude/done-config.json"
git -C "$R" status --porcelain | grep -Eq '^.M \.claude/done-config\.json$|^ M \.claude/done-config\.json$' \
  && ok "D2e: fixture is non-vacuous (the TRACKED config is modified in porcelain)" \
  || bad "D2e: fixture VACUOUS — tracked config not reported modified: $(git -C "$R" status --porcelain)"
OUT=$(run_gate "$R" sidD2e)
if is_block "$OUT"; then
  bad "D2e: GATE blocked on harness-owned dirt alone. out=$OUT"
else
  ok "D2e: GATE allows with only harness-owned dirt"
fi
WOUT=$(printf '%s' '{"contract_version":1,"session_id":"sidD2e","dod":{"sources":["base"],"items":["tests green"]},"tests":{"status":"passed","exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}' \
  | CLAUDE_PROJECT_DIR="$R" bash "$WRITER" sidD2e 2>&1)
if printf '%s' "$WOUT" | grep -q 'working tree dirty'; then
  bad "D2e: WRITER refused for dirt the GATE allows (writer/gate divergence): $WOUT"
elif [ -f "$R/.claude/.harness/done-state/session-sidD2e.json" ]; then
  ok "D2e: WRITER wrote the done-state despite harness-owned dirt (agrees with the gate)"
else
  bad "D2e: WRITER produced no done-state — it refused for some other reason: $WOUT"
fi
rm -rf "$R"

echo
echo "test-tree-status: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
