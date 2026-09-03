#!/bin/bash
#
# Deterministic tests for done-gate.sh — exercises every branch by crafting
# stdin JSON and pre-writing the matching .harness state, with CLAUDE_PROJECT_DIR
# pointed at a controlled directory. Live Stop-hook interception is NOT tested
# here (it needs a real Claude session); this validates the gate's decision
# logic in isolation.

GATE="$(cd "$(dirname "$0")/../scripts" && pwd)/done-gate.sh"

PASS=0
FAIL=0

# --- assertion helper -------------------------------------------------------
# run_case <name> <expect:block|allow> <stdin_json> [project_dir]
#
# Under the exit-0 block contract, exit code no longer distinguishes block from
# allow — BOTH exit 0. Classification is by STDOUT content:
#   BLOCK = stdout contains "decision":"block"  (exit 0)
#   ALLOW = stdout has no block decision (empty)  (exit 0)
# The exit code is still sanity-checked: every gate path must exit 0, so a
# nonzero exit means the script crashed and the case fails.
run_case() {
  local name="$1" expect="$2" stdin_json="$3" proj="${4:-$PROJECT_DIR}"
  local out code
  out=$(printf '%s' "$stdin_json" | CLAUDE_PROJECT_DIR="$proj" bash "$GATE" 2>/dev/null)
  code=$?

  local ok=1 detail=""
  if [ "$code" -ne 0 ]; then
    ok=0; detail="nonzero exit $code (expected 0 — script crashed?)"
  fi

  local is_block=0
  printf '%s' "$out" | jq -e '.decision == "block"' >/dev/null 2>&1 && is_block=1

  if [ "$expect" = "block" ]; then
    if [ "$is_block" -ne 1 ]; then
      ok=0; detail="$detail; expected block JSON on stdout, got: ${out:-<empty>}"
    fi
  else
    if [ "$is_block" -eq 1 ] || [ -n "$out" ]; then
      ok=0; detail="$detail; expected allow (empty stdout), got: $out"
    fi
  fi

  if [ "$ok" -eq 1 ]; then
    printf 'PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL  %s  [%s]\n' "$name" "$detail"; FAIL=$((FAIL+1))
  fi
}

# ============================================================================
# Fixtures: an isolated throwaway git repo we fully control.
# ============================================================================
# mktemp_d — mktemp -d wrapper that guarantees a non-empty result. An empty
# result would make every `git -C "$dir"` below silently operate on the
# caller's cwd (the real repo checkout) instead of failing loudly. See
# hc__test_make_repo in test-helpers.sh for the incident this mirrors. This
# file does not source test-helpers.sh, so it keeps its own copy.
mktemp_d() {
  local d; d=$(mktemp -d)
  [ -n "$d" ] || d="/nonexistent-hc-test-mktemp-failed-$$"
  printf '%s' "$d"
}

PROJECT_DIR=$(mktemp_d)
NONGIT_DIR=$(mktemp_d)
trap 'rm -rf "$PROJECT_DIR" "$NONGIT_DIR"' EXIT

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.name t
git -C "$PROJECT_DIR" config user.email t@t
printf 'a\n' > "$PROJECT_DIR/a.js"
# Harness state is git-ignored in a real install; mirror that so the porcelain
# check does not see .harness state as a dirty/untracked tree.
printf '.claude/\n' > "$PROJECT_DIR/.gitignore"
git -C "$PROJECT_DIR" add -A
git -C "$PROJECT_DIR" commit -q -m c1
BASELINE_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)

# advance HEAD so HEAD != baseline for the "commits happened" cases
printf 'b\n' > "$PROJECT_DIR/b.js"
git -C "$PROJECT_DIR" add -A
git -C "$PROJECT_DIR" commit -q -m c2
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)

HDIR="$PROJECT_DIR/.claude/.harness"
mkdir -p "$HDIR/baselines" "$HDIR/done-state" "$HDIR/review-log"

# helper to set the baseline file for a session (still keyed by raw session id).
# P0-a attribution is now EMAIL-ONLY (M1 fix): the session commits here carry the
# repo identity (email t@t) so they are NOT confidently-foreign → base-advance
# STOPS at them → they stay in the changeset. The baseline .sha mtime is no
# longer consulted, so its value is irrelevant; we do not backdate it.
set_baseline() {
  printf '%s\n' "$2" > "$HDIR/baselines/$1.sha"
}
# Done-state is now keyed by HC_TASK_KEY. These fixtures run on `main` (the
# repo's trunk) → session mode → task_key = "session-<session_id>". So the
# done-state path for session id $1 is done-state/session-$1.json.
write_done() { printf '%s\n' "$2" > "$HDIR/done-state/session-$1.json"; }
clear_state() { rm -f "$HDIR/baselines/$1.sha" "$HDIR/done-state/session-$1.json"; }

# Review-log is keyed by HEAD SHA (shared across all step-8-reaching cases, so
# it must be set EXPLICITLY per case — clear_state does NOT touch it).
# write_review_log <n_blocking>  → writes a schema-valid review-log/$HEAD_SHA.json
# whose findings[] holds <n_blocking> fully-formed high-severity findings. n=0
# yields an empty findings[] (green review → allow); n>0 yields that many
# blocking findings (→ block on the severity gate). The hard contract now
# REQUIRES findings to be an array, so an old-style findings-absent log would
# fail schema and block; this helper therefore models "open findings" via the
# array itself, which is exactly how hc_review_blocking counts them.
# All review-log helpers include files_reviewed covering the main-repo
# changeset (BASELINE_SHA..HEAD == b.js) so the STRUCTURAL coverage check (gate
# Step 8) is satisfied and cases gate on the axis they mean to test (severity /
# outcomes), not on coverage. Cases that specifically exercise coverage set
# files_reviewed explicitly via write_raw_review_log.
write_review_log() {
  local findings
  findings=$(jq -cn --argjson n "$1" '[range(0;$n) | {severity:"high",file:"b.js",line:1,desc:"finding"}]')
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["b.js"],"findings":%s,"open_findings":%s}\n' "$HEAD_SHA" "$findings" "$1" > "$HDIR/review-log/$HEAD_SHA.json"
}
clear_review_log() { rm -f "$HDIR/review-log/$HEAD_SHA.json"; }
# write_review_findings <findings_json_array>  → severity-tagged review-log.
# open_findings is set to a dummy 0 to prove the gate recomputes structurally
# from findings[].severity and does NOT trust the self-reported open_findings.
# files_reviewed covers the changeset so coverage passes and the case gates on
# severity alone.
write_review_findings() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["b.js"],"findings":%s,"open_findings":0}\n' "$HEAD_SHA" "$1" > "$HDIR/review-log/$HEAD_SHA.json"; }
# write_raw_review_log <raw_json>  → write arbitrary (possibly malformed) content.
write_raw_review_log() { printf '%s\n' "$1" > "$HDIR/review-log/$HEAD_SHA.json"; }
# set_min_level <low|medium|high|critical>  → per-case done-config.json.
set_min_level() { mkdir -p "$PROJECT_DIR/.claude"; printf '{"min_review_level":"%s"}\n' "$1" > "$PROJECT_DIR/.claude/done-config.json"; }
clear_config() { rm -f "$PROJECT_DIR/.claude/done-config.json"; }

# Reset tracked files to HEAD but preserve untracked harness state (.claude).
ensure_clean() { git -C "$PROJECT_DIR" checkout -q -- . 2>/dev/null; git -C "$PROJECT_DIR" clean -fdq -e .claude 2>/dev/null; }

# ============================================================================
# Case 1 — stop_hook_active=true is NO LONGER a blanket allow.
# The loop guard is now reason-scoped (lives in block()): it brakes only when
# the category it is about to emit matches the last-block marker for this task.
# With no marker written yet, a stop_hook_active=true turn evaluates the gate
# fully. Session s1 has no baseline → no anchor → Step 4 blocks (no-anchor).
# The dedicated brake/transition behaviour is exercised in Chunk H below.
# ============================================================================
rm -rf "$HDIR/last-block"
run_case "1 stop_hook_active=true, no marker -> still evaluates (blocks)" block \
  '{"session_id":"s1","stop_hook_active":true}'

# ============================================================================
# Case 2 — non-git dir → exit 0
# ============================================================================
run_case "2 non-git dir -> allow" allow \
  '{"session_id":"s2","stop_hook_active":false}' "$NONGIT_DIR"

# ============================================================================
# Case 3 — missing done-state (HEAD advanced past baseline) → BLOCK
# ============================================================================
SID=s3; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
run_case "3 missing done-state (HEAD>baseline) -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 3-ledger — REGRESSION PIN (0.1.15). An empty-but-present commit ledger
# (the PostToolUse hook touched baselines/<sid>.own-commits but never swept a
# commit in — a first non-commit Bash call, a stale cursor, or a writer/reader
# session-id disagreement) must NOT let hc__resolve_session_base advance the
# base to HEAD and silently pass unverified committed work. Same fixture as
# Case 3 plus an empty ledger → still BLOCK.
SID=s3l; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
: > "$HDIR/baselines/$SID.own-commits"
run_case "3l missing done-state + EMPTY ledger -> block (0.1.15 silent-pass regression)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
rm -f "$HDIR/baselines/$SID.own-commits"

# ============================================================================
# Case 4 — valid done-state, verified_sha==HEAD, clean tree → exit 0
# ============================================================================
SID=s4; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "4 valid done-state, sha==HEAD, clean, green outcomes + review-log open:0 -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 5 — verified_sha != HEAD → BLOCK
# ============================================================================
SID=s5; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[],\"escalation\":null}"
run_case "5 verified_sha != HEAD -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 6 — dirty tree (sha matches) → BLOCK
# ============================================================================
SID=s6; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[],\"escalation\":null}"
printf 'dirty\n' > "$PROJECT_DIR/a.js"   # make tree dirty
run_case "6 dirty tree -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
ensure_clean

# ============================================================================
# Case 7 — escalation present, verified_sha==HEAD, clean tree → exit 0
# Escalation is honoured only for the exact changeset it was recorded against
# (sha matches HEAD, tree clean). Under the reordered gate this reaches exit 0.
# ============================================================================
SID=s7; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
run_case "7 escalation + sha==HEAD + clean -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 8 — HEAD == baseline (no session commits) + CLEAN tree → allow
# ensure_clean guarantees a clean tree, so Step 3's tree-clean condition holds.
# ============================================================================
SID=s8; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
run_case "8 HEAD == baseline (no commits) + clean -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 8b — HEAD == baseline + DIRTY tree + no done-state → BLOCK
# Proves the uncommitted-tree gap is closed: when HEAD==baseline but the tree
# is dirty, Step 3 does NOT quiet-exit; it falls through to Step 4 (missing
# done-state) which blocks. An uncommitted "done" is therefore gated.
# ============================================================================
SID=s8b; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
printf 'dirty\n' > "$PROJECT_DIR/a.js"   # make tree dirty, HEAD unchanged
run_case "8b HEAD == baseline + dirty + no done-state -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
ensure_clean

# ============================================================================
# Case 9 — escalation present BUT verified_sha stale (!= HEAD) → BLOCK
# Proves a stale escalation no longer disarms the gate: SHA mismatch is caught
# first, so the escalation never gets a chance to allow the stop.
# ============================================================================
SID=s9; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"deadbeef\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
run_case "9 escalation + stale sha -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 10 — escalation present + verified_sha==HEAD but DIRTY tree → BLOCK
# Proves the dirty-tree check is enforced before escalation is honoured.
# ============================================================================
SID=s10; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
printf 'dirty\n' > "$PROJECT_DIR/a.js"   # make tree dirty
run_case "10 escalation + sha==HEAD + dirty -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
ensure_clean

# ============================================================================
# Step-8 outcome cases. All reach step 8 (sha==HEAD, clean tree, no escalation
# — except case 14 which carries an escalation to prove the escape beats a red
# outcome). Classified by stdout "decision":"block" like every other case.
#
# Step-8 check order is: tests -> lint -> review-log -> task_checks. A case that
# means to block on a LATER check must make every EARLIER check green, else it
# blocks early and silently exercises the wrong branch. The review-log is shared
# state keyed by $HEAD_SHA, so it is set EXPLICITLY in every case that reaches
# the review check.
# ============================================================================

# Case 11 — recorded tests red (exit_code:1), no escalation → BLOCK (on tests)
SID=s11; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0   # green so the block is unambiguously on tests
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":1},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "11 tests exit_code=1, no escalation -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12a — NO review-log for HEAD (tests green) → BLOCK (missing review)
SID=s12a; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
clear_review_log
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12a no review-log for HEAD -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12b — review-log present with open_findings:2 → BLOCK (open findings)
SID=s12b; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 2
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12b review-log open_findings:2 -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12c — review-log present with open_findings:0 → ALLOW (green review)
SID=s12c; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12c review-log open_findings:0 -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12d — done-state lint.exit_code:1 (tests green, review green) → BLOCK
SID=s12d; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"lint\":{\"exit_code\":1},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12d lint exit_code:1 -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12e — lint field ABSENT (tests green, review green) → ALLOW (lint skipped)
SID=s12e; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12e lint absent -> allow (not blocked on lint)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 13 — a task_check with status "failed" → BLOCK (tests+lint+review green)
SID=s13; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"lint\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"},{\"desc\":\"y\",\"status\":\"failed\"}],\"escalation\":null}"
run_case "13 a task_check status=failed -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 14 — red state (tests red, no review-log) BUT escalation present → ALLOW
# Escalation short-circuits at step 7, before any step-8 outcome check. Clear
# the review-log to prove escalation truly bypasses the whole outcome block.
# Must have sha==HEAD + clean tree, else it blocks at step 5/6 first.
SID=s14; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
clear_review_log
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":1},\"lint\":{\"exit_code\":1},\"task_checks\":[{\"desc\":\"x\",\"status\":\"failed\"}],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
run_case "14 red state + no review-log BUT escalation present -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 15 — no tests field at all, no escalation → BLOCK (fail-direction check)
# The hard contract makes `tests` a REQUIRED done-state field, so a done-state
# without it now fails the Step-4b schema gate FIRST (before Step 8's tests
# check). Block outcome preserved; reason shifted from the Step-8 fail-direction
# to the schema gate — the contract enforces presence structurally.
SID=s15; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0   # green so the block is unambiguously on the missing tests
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"task_checks\":[],\"escalation\":null}"
run_case "15 no tests field, no escalation -> block (schema)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Severity-gating cases (min_review_level). The gate recomputes the BLOCKING
# count structurally from findings[].severity + config min_review_level; the
# self-reported open_findings is deliberately 0 in write_review_findings to prove
# it is not trusted. Each case reaches Step 8's review check (tests+lint green,
# task_checks passed, sha==HEAD, clean tree, no escalation). done-state is a
# shared green fixture; only the review-log + config vary.
# ============================================================================
GREEN_DONE() { write_done "$1" "{\"contract_version\":1,\"session_id\":\"$1\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0,\"command\":\"t\",\"output_tail\":\"ok\"},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"; }

# Case 17a — findings [{high}], min_review_level high → BLOCK (high blocks).
SID=s17a; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_review_findings '[{"severity":"high","file":"a","line":1,"desc":"x"}]'; GREEN_DONE "$SID"
run_case "17a findings[high], min=high -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17b — findings all low/medium, min high → ALLOW (advisory only).
SID=s17b; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_review_findings '[{"severity":"low","file":"a","line":1,"desc":"x"},{"severity":"medium","file":"a","line":2,"desc":"y"}]'; GREEN_DONE "$SID"
run_case "17b findings[low,medium], min=high -> allow (advisory)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17c — findings has a medium, min medium → BLOCK.
SID=s17c; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level medium; write_review_findings '[{"severity":"low","file":"a","line":1,"desc":"x"},{"severity":"medium","file":"a","line":2,"desc":"y"}]'; GREEN_DONE "$SID"
run_case "17c findings[low,medium], min=medium -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17d — findings [{high}], min critical → ALLOW (high < critical).
SID=s17d; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level critical; write_review_findings '[{"severity":"high","file":"a","line":1,"desc":"x"}]'; GREEN_DONE "$SID"
run_case "17d findings[high], min=critical -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17e — findings [{low}], min low → BLOCK (strictest: everything blocks).
SID=s17e; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level low; write_review_findings '[{"severity":"low","file":"a","line":1,"desc":"x"}]'; GREEN_DONE "$SID"
run_case "17e findings[low], min=low -> block (strictest)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17f — finding with UNKNOWN severity, min high → BLOCK (safe direction).
# The hard contract now catches this FIRST: "bogus" is outside the severity enum
# → review-log fails schema → block. (Reason shifted from hc_review_blocking ERR
# to the schema gate; the block outcome is preserved.)
SID=s17f; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_review_findings '[{"severity":"bogus","file":"a","line":1,"desc":"x"}]'; GREEN_DONE "$SID"
run_case "17f finding[unknown severity], min=high -> block (safe/schema)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17f2 — finding with MISSING severity field, min high → BLOCK (safe).
# The hard contract catches this FIRST: severity is a required finding field →
# review-log fails schema → block. (Reason shifted from hc_review_blocking ERR to
# the schema gate; the block outcome is preserved.)
SID=s17f2; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_review_findings '[{"file":"a","line":1,"desc":"no severity key"}]'; GREEN_DONE "$SID"
run_case "17f2 finding[missing severity], min=high -> block (safe/schema)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17g — malformed review-log (bad JSON) → BLOCK (hc_review_blocking -> ERR).
SID=s17g; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_raw_review_log 'not json {{{'; GREEN_DONE "$SID"
run_case "17g malformed review-log -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17h — schema-valid log, empty findings[] → ALLOW.
SID=s17h; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_review_log 0; GREEN_DONE "$SID"
run_case "17h findings[] empty -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17i — schema-valid log, 2 blocking findings[] → BLOCK.
SID=s17i; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_review_log 2; GREEN_DONE "$SID"
run_case "17i findings[] 2 blocking -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17j — findings PRESENT but an OBJECT (not array) + self-reported
# open_findings:0 → BLOCK. The hard contract now rejects this at the schema gate
# (findings must be an array) BEFORE hc_review_blocking; either way it must fail
# toward block. The security hole — an object findings with open_findings:0 —
# must never ALLOW.
SID=s17j; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_raw_review_log "{\"reviewed_sha\":\"$HEAD_SHA\",\"findings\":{\"severity\":\"critical\"},\"open_findings\":0}"; GREEN_DONE "$SID"
run_case "17j findings is OBJECT + open_findings:0 -> block (anti-forgery)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17k — findings PRESENT but a STRING (not array) + open_findings:0 → BLOCK.
SID=s17k; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_raw_review_log "{\"reviewed_sha\":\"$HEAD_SHA\",\"findings\":\"whatever\",\"open_findings\":0}"; GREEN_DONE "$SID"
run_case "17k findings is STRING + open_findings:0 -> block (anti-forgery)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 17l — findings PRESENT and an EMPTY array → ALLOW (reviewer found
# nothing; empty is a legitimate green, must NOT be forced to the fallback).
SID=s17l; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
set_min_level high; write_raw_review_log "{\"contract_version\":1,\"reviewed_sha\":\"$HEAD_SHA\",\"min_review_level\":\"high\",\"files_reviewed\":[\"b.js\"],\"findings\":[]}"; GREEN_DONE "$SID"
run_case "17l findings is EMPTY array -> allow (nothing found)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Coverage-contract cases (structural: files_reviewed ⊇ changed files).
# The main-repo changeset is BASELINE_SHA..HEAD, which touches exactly ONE file
# (b.js). To exercise the "missing one changed file" gap we need ≥2 changed
# files, so these cases run in a dedicated isolated repo whose base..HEAD touches
# TWO files (f1.js, f2.js). Findings are empty (severity passes) so the ONLY
# gating axis is coverage. done-state is branch-keyed (feature branch → task
# mode) so the pinned merge-base is the changeset base the gate diffs against.
# ============================================================================
COV_REPO=$(mktemp_d)
git -C "$COV_REPO" init -q -b main
git -C "$COV_REPO" config user.name t
git -C "$COV_REPO" config user.email t@t
printf '.claude/\n' > "$COV_REPO/.gitignore"
printf 'base\n' > "$COV_REPO/base.js"
git -C "$COV_REPO" add -A
git -C "$COV_REPO" commit -q -m base
git -C "$COV_REPO" checkout -q -b feat/cov
printf '1\n' > "$COV_REPO/f1.js"
printf '2\n' > "$COV_REPO/f2.js"      # TWO changed files in base..HEAD
git -C "$COV_REPO" add -A
git -C "$COV_REPO" commit -q -m work
COV_HEAD=$(git -C "$COV_REPO" rev-parse HEAD)
CHDIR="$COV_REPO/.claude/.harness"
mkdir -p "$CHDIR/done-state" "$CHDIR/review-log"
# branch-keyed green done-state (task_key = br-feat-cov)
printf '{"contract_version":1,"session_id":"c","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$COV_HEAD" \
  > "$CHDIR/done-state/br-feat-cov.json"
# cov_log <files_reviewed_json_array>  → review-log for COV_HEAD, empty findings
# (severity passes) so coverage is the sole gating axis.
cov_log() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[]}\n' "$COV_HEAD" "$1" > "$CHDIR/review-log/$COV_HEAD.json"; }

# Case COV-1 — files_reviewed covers ALL changed files → ALLOW.
cov_log '["f1.js","f2.js"]'
run_case "COV1 files_reviewed covers all changed -> allow" allow \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

# Case COV-2 — files_reviewed MISSING one changed file → BLOCK ("did not cover").
cov_log '["f1.js"]'
run_case "COV2 files_reviewed missing f2.js -> block (did not cover)" block \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

# Case COV-3 — review-log has NO files_reviewed field, changes exist → BLOCK.
# files_reviewed is a required contract field, so this now fails the schema gate
# FIRST (before the coverage check). Block outcome preserved; reason shifted from
# coverage-gap to schema.
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","findings":[]}\n' "$COV_HEAD" > "$CHDIR/review-log/$COV_HEAD.json"
run_case "COV3 no files_reviewed field, changes exist -> block (schema)" block \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

# Case COV-4 — files_reviewed is a SUPERSET (extra unchanged file) → ALLOW.
cov_log '["f1.js","f2.js","unrelated.js"]'
run_case "COV4 files_reviewed superset -> allow" allow \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

rm -rf "$COV_REPO"

clear_config

# ============================================================================
# Case 16 — CROSS-SESSION INHERITANCE (task mode, branch-keyed done-state)
# On a feature branch feat/x off main, the done-state is keyed by the BRANCH
# (task_key = br-feat-x), not the session id. So the SAME committed changeset,
# reviewed and recorded once, must ALLOW the gate for TWO DIFFERENT session ids
# (A then B) — proving multi-session resume works at the gate level.
#
# Built in an isolated repo so it never disturbs the main-branch fixture above.
# ============================================================================
FEAT_REPO=$(mktemp_d)
git -C "$FEAT_REPO" init -q -b main
git -C "$FEAT_REPO" config user.name t
git -C "$FEAT_REPO" config user.email t@t
printf '.claude/\n' > "$FEAT_REPO/.gitignore"
printf 'base\n' > "$FEAT_REPO/base.js"
git -C "$FEAT_REPO" add -A
git -C "$FEAT_REPO" commit -q -m base
# branch off main, commit feature work → HEAD moves past the fork base
git -C "$FEAT_REPO" checkout -q -b feat/x
printf 'work\n' > "$FEAT_REPO/work.js"
git -C "$FEAT_REPO" add -A
git -C "$FEAT_REPO" commit -q -m work
FEAT_HEAD=$(git -C "$FEAT_REPO" rev-parse HEAD)

FHDIR="$FEAT_REPO/.claude/.harness"
mkdir -p "$FHDIR/done-state" "$FHDIR/review-log"
# branch-keyed done-state (NOT session-keyed): br-feat-x
printf '{"contract_version":1,"session_id":"whatever","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$FEAT_HEAD" \
  > "$FHDIR/done-state/br-feat-x.json"
# independent review-log for the feature HEAD, no open findings. files_reviewed
# covers the feature changeset (merge-base(main,feat/x)..HEAD == work.js) so the
# STRUCTURAL coverage check passes and the cross-session-resume assertion holds.
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["work.js"],"findings":[],"open_findings":0}\n' "$FEAT_HEAD" \
  > "$FHDIR/review-log/$FEAT_HEAD.json"

run_case "16a feat/x branch-keyed state ALLOWs for session A" allow \
  '{"session_id":"A","stop_hook_active":false}' "$FEAT_REPO"
run_case "16b same state ALLOWs for a DIFFERENT session B (cross-session resume)" allow \
  '{"session_id":"B","stop_hook_active":false}' "$FEAT_REPO"

rm -rf "$FEAT_REPO"

# ============================================================================
# Reason-pinning cases — the S1/S2 boundary now matches hc_state.
#
# run_case only classifies block/allow; these capture the block JSON's .reason
# and pin its FAMILY, proving the reordered gate emits the S1 ("finish the
# slice") reason for an introduced-dirty tree and the S2 ("/done") reason for a
# committed-clean tree with no done-state — the exact boundary hc_state draws.
#
# gate_reason <stdin_json> [proj]  → echoes .reason from the block JSON (empty
# on allow). Same invocation shape as run_case.
gate_reason() {
  local stdin_json="$1" proj="${2:-$PROJECT_DIR}"
  printf '%s' "$stdin_json" | CLAUDE_PROJECT_DIR="$proj" bash "$GATE" 2>/dev/null \
    | jq -r '.reason // ""' 2>/dev/null
}
# assert_reason_prefix <name> <stdin_json> <prefix> [proj]
assert_reason_prefix() {
  local name="$1" stdin_json="$2" prefix="$3" proj="${4:-$PROJECT_DIR}"
  local r; r=$(gate_reason "$stdin_json" "$proj")
  case "$r" in
    "$prefix"*) printf 'PASS  %s\n' "$name"; PASS=$((PASS+1)) ;;
    *) printf 'FAIL  %s  [reason: %s; expected prefix: %s]\n' "$name" "${r:-<empty>}" "$prefix"; FAIL=$((FAIL+1)) ;;
  esac
}
# assert_reason_eq <name> <stdin_json> <exact> [proj]
assert_reason_eq() {
  local name="$1" stdin_json="$2" exact="$3" proj="${4:-$PROJECT_DIR}"
  local r; r=$(gate_reason "$stdin_json" "$proj")
  if [ "$r" = "$exact" ]; then
    printf 'PASS  %s\n' "$name"; PASS=$((PASS+1))
  else
    printf 'FAIL  %s  [reason: %s; expected: %s]\n' "$name" "${r:-<empty>}" "$exact"; FAIL=$((FAIL+1))
  fi
}

# R1 — introduced-dirty + no done-state → reason starts "finish the slice" (S1).
# Baseline pinned at HEAD, tree dirtied, NO done-state. Before the reorder the
# gate blocked with the S2 /done string (missing-done-state checked first); after,
# the tree-check fires first with the S1 reason.
SID=rp1; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
printf 'introduced\n' > "$PROJECT_DIR/a.js"
assert_reason_prefix "R1 introduced-dirty + no done-state -> reason 'finish the slice' (S1)" \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}" "finish the slice"
ensure_clean

# R2 — committed-clean + no done-state → S2 family reason. P1-a (#6) now PREPENDS
# a content-ful changeset summary to the bare /done string, so this asserts the
# reason CONTAINS both the /done instruction AND the summary's "authored this
# session" line (relaxed from the exact-string equality it used before).
SID=rp2; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
R2_REASON=$(gate_reason "{\"session_id\":\"$SID\",\"stop_hook_active\":false}")
case "$R2_REASON" in
  *"run /done to verify the changeset (owns the Step-5 review)"*)
    case "$R2_REASON" in
      *"authored this session"*)
        printf 'PASS  %s\n' "R2 committed-clean + no done-state -> /done reason + changeset summary (authored this session)"; PASS=$((PASS+1)) ;;
      *) printf 'FAIL  %s  [reason missing summary: %s]\n' "R2 summary" "$R2_REASON"; FAIL=$((FAIL+1)) ;;
    esac ;;
  *) printf 'FAIL  %s  [reason: %s]\n' "R2 /done family" "${R2_REASON:-<empty>}"; FAIL=$((FAIL+1)) ;;
esac
# Chunk D: the summary must also carry the changeset stat + an author list.
case "$R2_REASON" in
  *"changeset "*"files"*) ok=1 ;;
  *) printf 'FAIL  %s  [no changeset stat line: %s]\n' "R2 changeset stat" "$R2_REASON"; FAIL=$((FAIL+1)); ok=0 ;;
esac
[ "${ok:-0}" -eq 1 ] && { printf 'PASS  %s\n' "R2 block reason includes changeset stat + author list"; PASS=$((PASS+1)); }

# ============================================================================
# Floor↔steering PARITY — the gate's reason FAMILY must agree with hc_state's
# HC_STATE across the two boundary trees. Sources the REAL library, builds its
# own throwaway repos (self-contained; independent of the main fixture above).
#   {dirty + no-done-state}            → hc_state S1 ⇔ gate 'finish the slice'
#   {clean + no-done-state, HEAD>base} → hc_state S2 ⇔ gate '/done'
# ============================================================================
LIB="$(cd "$(dirname "$0")/../scripts" && pwd)/harness-common.sh"

# hc_state_for <dir> <sid>  → echoes HC_STATE (subshell: clean globals per call).
hc_state_for() {
  local dir="$1" sid="$2"
  (
    export CLAUDE_PROJECT_DIR="$dir"
    unset PROJECT_DIR
    . "$LIB"
    hc_state "$sid"
    printf '%s' "$HC_STATE"
  )
}

# Build a task-mode repo (feature branch off main). Echoes "<dir> <feat_head>".
parity_repo() {
  local d; d=$(mktemp_d)
  git -C "$d" init -q -b main
  git -C "$d" config user.name t; git -C "$d" config user.email t@t
  printf '.claude/\n' > "$d/.gitignore"
  printf 'root\n' > "$d/root.js"
  git -C "$d" add -A; git -C "$d" commit -q -m root
  git -C "$d" checkout -q -b feat/parity
  mkdir -p "$d/.claude/.harness/done-state" "$d/.claude/.harness/review-log" \
           "$d/.claude/.harness/baselines" "$d/.claude/.harness/tree-base"
  printf '%s' "$d"
}
parity_assert() {
  local name="$1" state="$2" reason="$3" expect_state="$4" expect_prefix="$5"
  local ok=1 detail=""
  [ "$state" = "$expect_state" ] || { ok=0; detail="hc_state=$state (want $expect_state)"; }
  # Substring (not prefix) match: P1-a (#6) prepends a changeset summary to the
  # S2 reason, so the /done family string is no longer at the START of the reason.
  case "$reason" in *"$expect_prefix"*) : ;; *) ok=0; detail="$detail; reason=${reason:-<empty>} (want substring $expect_prefix)";; esac
  if [ "$ok" -eq 1 ]; then printf 'PASS  %s\n' "$name"; PASS=$((PASS+1))
  else printf 'FAIL  %s  [%s]\n' "$name" "$detail"; FAIL=$((FAIL+1)); fi
}

# P1 — dirty + no-done-state → hc_state S1, gate 'finish the slice'.
PDIR=$(parity_repo)
# pin a clean tree baseline for this task key so the introduced file classifies
# as a blocker (not seeded as pre-existing).
: > "$PDIR/.claude/.harness/tree-base/br-feat-parity.dirty"
printf '%s\n' "$(git -C "$PDIR" merge-base main HEAD)" > "$PDIR/.claude/.harness/task-base/br-feat-parity.sha" 2>/dev/null \
  || { mkdir -p "$PDIR/.claude/.harness/task-base"; printf '%s\n' "$(git -C "$PDIR" merge-base main HEAD)" > "$PDIR/.claude/.harness/task-base/br-feat-parity.sha"; }
printf 'wip\n' > "$PDIR/wip.js"
P_STATE=$(hc_state_for "$PDIR" "p1")
P_REASON=$(gate_reason '{"session_id":"p1","stop_hook_active":false}' "$PDIR")
parity_assert "PARITY dirty+no-done-state: hc_state S1 == gate 'finish the slice'" \
  "$P_STATE" "$P_REASON" "S1" "finish the slice"
rm -rf "$PDIR"

# P2 — clean + no-done-state, HEAD>base → hc_state S2, gate '/done'.
PDIR=$(parity_repo)
mkdir -p "$PDIR/.claude/.harness/task-base"
printf '%s\n' "$(git -C "$PDIR" merge-base main HEAD)" > "$PDIR/.claude/.harness/task-base/br-feat-parity.sha"
printf 'work\n' > "$PDIR/work.js"; git -C "$PDIR" add -A; git -C "$PDIR" commit -q -m work
# pin the tree baseline AFTER committing so the tree is clean (no blockers).
: > "$PDIR/.claude/.harness/tree-base/br-feat-parity.dirty"
P_STATE=$(hc_state_for "$PDIR" "p2")
P_REASON=$(gate_reason '{"session_id":"p2","stop_hook_active":false}' "$PDIR")
parity_assert "PARITY clean+no-done-state(HEAD>base): hc_state S2 == gate '/done'" \
  "$P_STATE" "$P_REASON" "S2" "run /done"
rm -rf "$PDIR"

# ============================================================================
# Part B lock — PreToolUse no-deny invariant. auto-branch.sh must NEVER emit a
# deny/decision and must ALWAYS exit 0, whether driven on trunk or off-trunk.
# (Audit conclusion: no new PreToolUse-deny was added; this pins that.)
# ============================================================================
AUTOBRANCH="$(cd "$(dirname "$0")/../scripts" && pwd)/auto-branch.sh"

# assert_no_deny <name> <dir>  → runs the hook with a Write tool_input; asserts
# exit 0 AND stdout carries no deny/decision key.
assert_no_deny() {
  local name="$1" dir="$2" out code
  out=$(printf '{"session_id":"pb","tool_name":"Write","tool_input":{"file_path":"x.js","content":"y"}}' \
    | CLAUDE_PROJECT_DIR="$dir" bash "$AUTOBRANCH" 2>/dev/null)
  code=$?
  local ok=1 detail=""
  [ "$code" -eq 0 ] || { ok=0; detail="exit $code (expected 0)"; }
  case "$out" in
    *'"decision"'*|*'"deny"'*|*'"permissionDecision"'*) ok=0; detail="$detail; emitted a decision/deny: $out" ;;
  esac
  if [ "$ok" -eq 1 ]; then printf 'PASS  %s\n' "$name"; PASS=$((PASS+1))
  else printf 'FAIL  %s  [%s]\n' "$name" "$detail"; FAIL=$((FAIL+1)); fi
}

# PB1 — on trunk (main). The hook may auto-branch but must never deny.
PBDIR=$(mktemp_d)
git -C "$PBDIR" init -q -b main
git -C "$PBDIR" config user.name t; git -C "$PBDIR" config user.email t@t
printf 'root\n' > "$PBDIR/root.js"; git -C "$PBDIR" add -A; git -C "$PBDIR" commit -q -m root
mkdir -p "$PBDIR/.claude"; printf '{"trunk":"main"}\n' > "$PBDIR/.claude/done-config.json"
assert_no_deny "PB1 PreToolUse on trunk -> exit 0, no deny/decision" "$PBDIR"
rm -rf "$PBDIR"

# PB2 — off trunk (feature branch). Fast-path no-op; still no deny, exit 0.
PBDIR=$(mktemp_d)
git -C "$PBDIR" init -q -b main
git -C "$PBDIR" config user.name t; git -C "$PBDIR" config user.email t@t
printf 'root\n' > "$PBDIR/root.js"; git -C "$PBDIR" add -A; git -C "$PBDIR" commit -q -m root
git -C "$PBDIR" checkout -q -b feat/pb
mkdir -p "$PBDIR/.claude"; printf '{"trunk":"main"}\n' > "$PBDIR/.claude/done-config.json"
assert_no_deny "PB2 PreToolUse off trunk -> exit 0, no deny/decision" "$PBDIR"
rm -rf "$PBDIR"

# ============================================================================
# Chunk B (P0-b, #6) — empty-changeset short-circuit (Step 3c).
# base pinned AT HEAD → the commit-range diff base..HEAD is empty. With a clean
# tree Step 3 already quiet-exits; these exercise the NEW Step 3c that allows an
# empty range even when the tree has ONLY pre-existing dirt, while INTRODUCED
# dirt still blocks first (Step 3b precedes Step 3c).
# ----------------------------------------------------------------------------
# EB1 — empty range + PRE-EXISTING dirt only → allow (Step 3c).
# Baseline pinned at HEAD (empty range). Dirty a.js, but record that exact
# porcelain line in the session .dirty baseline so hc_tree_status classifies it
# as pre-existing (a warning, not a blocker) → Step 3b does not block → Step 3c
# sees the empty range and allows.
SID=eb1; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
printf 'preexisting\n' > "$PROJECT_DIR/a.js"   # tree now dirty (tracked-modified)
DIRTY_LINE=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)
printf '%s\n' "$DIRTY_LINE" > "$HDIR/baselines/$SID.dirty"   # pre-existing at baseline
run_case "EB1 empty range + pre-existing dirt only -> allow (Step 3c)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
rm -f "$HDIR/baselines/$SID.dirty"; ensure_clean

# EB2 — empty range + INTRODUCED dirt → still BLOCK (Step 3b precedes 3c).
# Same empty range, but NO .dirty baseline (empty baseline set → the dirty line
# is INTRODUCED) → Step 3b blocks with the S1 reason before Step 3c can allow.
SID=eb2; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
printf 'introduced\n' > "$PROJECT_DIR/a.js"
: > "$HDIR/baselines/$SID.dirty"   # empty baseline set → line is introduced
run_case "EB2 empty range + INTRODUCED dirt -> still block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
rm -f "$HDIR/baselines/$SID.dirty"; ensure_clean

# EB3 — empty range + clean tree → allow (existing Step 3 quiet-exit still holds).
SID=eb3; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
run_case "EB3 empty range + clean tree -> allow (Step 3 quiet-exit)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Chunk G (P2-b, #6) — SHA-keyed escalation sidecar honored EARLY (Step 3d).
# A done-state VALID at HEAD but with a RED outcome (tests exit 1) and NULL
# escalation would block at Step 8. With a sidecar escalation-accept/<HEAD>.json
# present, the gate honors it at Step 3d and ALLOWS — proving a session whose
# done-state lacks the escalation copy still honors the SHA-keyed acceptance.
# ----------------------------------------------------------------------------
SID=eg1; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
# Red done-state at HEAD, escalation:null → would block Step 8 without a sidecar.
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"b\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":1},\"task_checks\":[],\"escalation\":null}"
write_review_log 0
# Control: NO sidecar yet → must BLOCK (red tests, no escalation).
rm -f "$HDIR/escalation-accept/$HEAD_SHA.json"
run_case "EG1 red done-state, no sidecar -> block (control)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
# Seed the sidecar for THIS HEAD → gate honors it at Step 3d → ALLOW.
mkdir -p "$HDIR/escalation-accept"
printf '{"type":"user_accepted"}\n' > "$HDIR/escalation-accept/$HEAD_SHA.json"
run_case "EG1 red done-state + SHA sidecar -> allow (Step 3d honors sidecar)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
# Sidecar disarms ONLY this HEAD: a sidecar for a DIFFERENT sha does NOT help.
rm -f "$HDIR/escalation-accept/$HEAD_SHA.json"
printf '{"type":"user_accepted"}\n' > "$HDIR/escalation-accept/$BASELINE_SHA.json"
run_case "EG1 sidecar for OTHER sha -> block (disarms only this HEAD)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
rm -f "$HDIR/escalation-accept/$BASELINE_SHA.json"

# ----------------------------------------------------------------------------
# EG2 (P2-b, #6, L2 fix) — CROSS-SESSION disarm: sidecar honored with NO
# done-state. The whole point of the SHA-keyed sidecar is a DIFFERENT session
# (a fresh session-<id> key that has no done-state for this task). Previously
# the sidecar sat at Step 7, AFTER the Step-4 done-state-missing block, so it was
# dead code cross-session. With the check at Step 3d it is reached first.
#   (a) no done-state, clean committed tree at HEAD, sidecar for HEAD → ALLOW.
SID=eg2; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
clear_review_log   # NO done-state, NO review-log for this fresh session key
mkdir -p "$HDIR/escalation-accept"
printf '{"type":"user_accepted"}\n' > "$HDIR/escalation-accept/$HEAD_SHA.json"
run_case "EG2 no done-state + sidecar at HEAD -> allow (cross-session disarm)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
#   (b) move HEAD (+1 commit) → sidecar is for the OLD sha → BLOCK (no disarm).
printf 'eg2\n' > "$PROJECT_DIR/eg2.js"; git -C "$PROJECT_DIR" add -A; git -C "$PROJECT_DIR" commit -q -m eg2
EG2_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD)
run_case "EG2 HEAD moved, sidecar for old sha -> block (keyed to exact HEAD)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
# rewind HEAD back and clean up so later cases see the original HEAD_SHA.
git -C "$PROJECT_DIR" reset -q --hard "$HEAD_SHA"
#   (c) introduced dirt + sidecar present → still BLOCK on the tree (Step 3b
#       precedes 3d): an accepted escalation disarms the committed changeset, not
#       new uncommitted work.
ensure_clean
printf 'introduced\n' > "$PROJECT_DIR/eg2dirt.js"
: > "$HDIR/baselines/$SID.dirty"   # empty baseline set → the untracked line is introduced
run_case "EG2 introduced dirt + sidecar -> still block on tree (3b precedes 3d)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
rm -f "$HDIR/baselines/$SID.dirty" "$PROJECT_DIR/eg2dirt.js"
rm -f "$HDIR/escalation-accept/$HEAD_SHA.json" "$HDIR/escalation-accept/$EG2_HEAD.json"
ensure_clean

# Writer: an escalated /done writes the SHA-keyed sidecar. Uses the WRITE script
# against a self-contained repo to assert the sidecar file is created at HEAD.
WRITE_G="$(cd "$(dirname "$0")/../scripts" && pwd)/done-write-state.sh"
EG_REPO=$(mktemp_d)
git -C "$EG_REPO" init -q -b main
git -C "$EG_REPO" config user.name t; git -C "$EG_REPO" config user.email t@t
printf '.claude/\n' > "$EG_REPO/.gitignore"
printf 'r\n' > "$EG_REPO/r.js"; git -C "$EG_REPO" add -A; git -C "$EG_REPO" commit -qm init
EG_HEAD=$(git -C "$EG_REPO" rev-parse HEAD)
mkdir -p "$EG_REPO/.claude/.harness/baselines"
printf '%s\n' "$EG_HEAD" > "$EG_REPO/.claude/.harness/baselines/eg-esc.sha"
# Escalated payload (red tests) → writer bypasses green checks AND writes sidecar.
EG_PAYLOAD='{"dod":{"sources":["b"],"items":["x"]},"tests":{"exit_code":1},"task_checks":[{"desc":"x","status":"failed"}],"escalation":{"type":"user_accepted","user_decision":"accept"}}'
printf '%s' "$EG_PAYLOAD" | CLAUDE_PROJECT_DIR="$EG_REPO" bash "$WRITE_G" "eg-esc" >/dev/null 2>&1
if [ -f "$EG_REPO/.claude/.harness/escalation-accept/$EG_HEAD.json" ]; then
  printf 'PASS  %s\n' "EG1 writer creates SHA-keyed escalation sidecar"; PASS=$((PASS+1))
else
  printf 'FAIL  %s  [sidecar not written]\n' "EG1 writer sidecar"; FAIL=$((FAIL+1))
fi
rm -rf "$EG_REPO"

# ============================================================================
# Chunk E (P1-b, #6) — pending-escalation one-shot pass (Step 2b).
# A state that WOULD block (committed work past baseline, no done-state → S2)
# is allowed EXACTLY ONCE when a pending-escalation/<task_key>.json exists; the
# file is consumed (rm) so the second Stop re-blocks.
# ----------------------------------------------------------------------------
SID=pe1; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
# task_key in session mode = session-<id>.
PEND_DIR="$HDIR/pending-escalation"; mkdir -p "$PEND_DIR"
PEND_FILE="$PEND_DIR/session-$SID.json"
printf '{"reason":"asking user"}\n' > "$PEND_FILE"
# First Stop: pending present → allow, file consumed.
run_case "PE1 pending-escalation present -> one-shot allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
if [ ! -f "$PEND_FILE" ]; then
  printf 'PASS  %s\n' "PE1 pending file consumed after one allow"; PASS=$((PASS+1))
else
  printf 'FAIL  %s  [file still present]\n' "PE1 pending file consumed"; FAIL=$((FAIL+1))
fi
# Second Stop: no pending file → re-gate normally → S2 block (committed, no done-state).
run_case "PE1 second Stop after consume -> block (re-gated)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
ensure_clean

# ============================================================================
# Chunk F — a PROSE-ONLY changeset is gated like any other.
#
# The harness used to classify the changeset (noncode_globs) and silently stand
# down when every changed file was prose/docs/images — gate Step 3a, hc_state
# S_OOS. That is gone: the snapshot decides the changeset, and everything in it
# is reviewed. These cases pin the FLIP, and they matter more than most: the
# gate's fail-safe direction is ALLOW (a crashed or timed-out hook emits no
# stdout, which the contract reads as allow), so a prose case asserting BLOCK is
# also the suite's proof that the hook is alive and emitting decision JSON.
#
# Own throwaway repo (like Chunk D/E): committing here must not move the shared
# fixture's HEAD_SHA, which the review-log helpers above are keyed to.
# ----------------------------------------------------------------------------
PR_REPO=$(mktemp_d)
git -C "$PR_REPO" init -q
git -C "$PR_REPO" config user.name t; git -C "$PR_REPO" config user.email t@t
printf '.claude/\n' > "$PR_REPO/.gitignore"
printf 'code\n' > "$PR_REPO/app.js"
git -C "$PR_REPO" add -A; git -C "$PR_REPO" commit -qm init
PR_BASE=$(git -C "$PR_REPO" rev-parse HEAD)
PRHDIR="$PR_REPO/.claude/.harness"
mkdir -p "$PRHDIR/baselines" "$PRHDIR/done-state" "$PRHDIR/review-log"

# F1 — prose committed past the baseline, no done-state → BLOCK.
# Every changed file is markdown; pre-refactor this exited 0 with empty stdout.
printf '# docs\n' > "$PR_REPO/README.md"
git -C "$PR_REPO" add -A; git -C "$PR_REPO" commit -qm docs
PR_HEAD=$(git -C "$PR_REPO" rev-parse HEAD)
printf '%s\n' "$PR_BASE" > "$PRHDIR/baselines/pr1.sha"
run_case "F1 prose-only committed changeset, no done-state -> block" block \
  '{"session_id":"pr1","stop_hook_active":false}' "$PR_REPO"

# F2 — prose introduced as uncommitted tree dirt, no done-state → BLOCK.
# Baseline pinned AT head so the commit range is empty and the ONLY changeset is
# the introduced .md file: isolates the tree-dirt path from the commit path.
printf '%s\n' "$PR_HEAD" > "$PRHDIR/baselines/pr2.sha"
printf 'more prose\n' > "$PR_REPO/NOTES.md"
run_case "F2 prose-only introduced tree dirt, no done-state -> block" block \
  '{"session_id":"pr2","stop_hook_active":false}' "$PR_REPO"
rm -f "$PR_REPO/NOTES.md"

# F3 — same prose changeset, but VERIFIED → ALLOW. Without this, F1/F2 would
# also pass on a gate that blocks unconditionally; this proves prose is gated
# NORMALLY, and that Step 8's coverage check accepts a .md file in
# files_reviewed exactly as it does a .js one.
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["README.md"],"findings":[],"open_findings":0}\n' \
  "$PR_HEAD" > "$PRHDIR/review-log/$PR_HEAD.json"
printf '{"contract_version":1,"session_id":"pr3","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' \
  "$PR_HEAD" > "$PRHDIR/done-state/session-pr3.json"
printf '%s\n' "$PR_BASE" > "$PRHDIR/baselines/pr3.sha"
run_case "F3 prose-only changeset WITH valid done-state + green review -> allow" allow \
  '{"session_id":"pr3","stop_hook_active":false}' "$PR_REPO"

rm -rf "$PR_REPO"

# ============================================================================
# Chunk H — reason-scoped loop guard (block category SSOT + brake/transition).
#
# Regression pin for the jobhunt incident: a blanket `stop_hook_active => exit 0`
# swallowed the tree-dirty -> changeset-unverified transition. The agent
# committed in the block-response cycle, stopped again with the flag still true,
# and the gate exited before Step 4 — leaving the changeset unverified and
# unannounced. The guard now compares the PENDING block category against the
# previous turn's persisted one: same => runaway brake, different => let it fire.
# ----------------------------------------------------------------------------
LB_DIR="$HDIR/last-block"
LIBH="$(cd "$(dirname "$0")/../scripts" && pwd)/harness-common.sh"

# --- H0: SSOT sync — every block() call site in done-gate.sh passes a
#     $HC_BLOCK_* constant (never a bare literal / missing arg), and every
#     constant it references exists in hc_block_categories. This is the
#     "keep the reasons in sync" guard, mechanised.
GATE_SRC=$(cat "$GATE")
# 0a. no `block "..."` line may end without a $HC_BLOCK_* 2nd arg. Match the
#     helper calls (2-space indented, as in the script), excluding the block()
#     definition itself and validate_or_block's internal call which forwards
#     $category.
BAD_BLOCK=$(printf '%s\n' "$GATE_SRC" \
  | grep -nE '^  block "' \
  | grep -vE '\$HC_BLOCK_[A-Z_]+"?[[:space:]]*$' || true)
if [ -z "$BAD_BLOCK" ]; then
  printf 'PASS  %s\n' "H0a every block() call passes a \$HC_BLOCK_* category"; PASS=$((PASS+1))
else
  printf 'FAIL  %s  [call(s) without a category constant:\n%s\n]\n' "H0a block() category args" "$BAD_BLOCK"; FAIL=$((FAIL+1))
fi
# 0b. every $HC_BLOCK_* referenced in done-gate.sh is a real constant listed by
#     hc_block_categories (catches a typo'd constant name).
REFERENCED=$(printf '%s\n' "$GATE_SRC" | grep -oE '\$HC_BLOCK_[A-Z_]+' | sort -u | sed 's/^\$//')
KNOWN=$( ( . "$LIBH"; for v in $REFERENCED; do eval "printf '%s\n' \"\$$v\""; done ) 2>/dev/null | sort -u)
VALID_SET=$( ( . "$LIBH"; hc_block_categories ) 2>/dev/null | sort -u)
H0B_OK=1
while IFS= read -r cat; do
  [ -z "$cat" ] && continue
  printf '%s\n' "$VALID_SET" | grep -qxF "$cat" || { H0B_OK=0; break; }
done <<EOF
$KNOWN
EOF
if [ "$H0B_OK" -eq 1 ] && [ -n "$KNOWN" ]; then
  printf 'PASS  %s\n' "H0b every referenced \$HC_BLOCK_* is in hc_block_categories"; PASS=$((PASS+1))
else
  printf 'FAIL  %s  [referenced=%s known-valid=%s]\n' "H0b category constants valid" "$(printf '%s' "$KNOWN" | tr '\n' ' ')" "$(printf '%s' "$VALID_SET" | tr '\n' ' ')"; FAIL=$((FAIL+1))
fi

# --- H1: same category under stop_hook_active → brake (silent allow).
# Dirty tree + no done-state → the pending block is tree-dirty. Pre-seed the
# marker with tree-dirty → the gate must brake (this is the genuine runaway:
# the agent cannot clear the dirty tree and keeps stopping).
SID=h1; clear_state "$SID"; set_baseline "$SID" "$HEAD_SHA"; ensure_clean
printf 'introduced\n' > "$PROJECT_DIR/a.js"
mkdir -p "$LB_DIR"; printf 'tree-dirty\n' > "$LB_DIR/session-$SID"
run_case "H1 same category (tree-dirty) + stop_hook_active -> brake (allow)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":true}"
rm -rf "$LB_DIR"; ensure_clean

# --- H2: THE JOBHUNT CASE. Different category under stop_hook_active → the new
# block fires. Committed-clean + no done-state → pending block is
# changeset-unverified. Marker holds the PREVIOUS turn's tree-dirty. The
# categories differ → the agent complied (committed) and reached a new
# condition → the gate MUST block for changeset-unverified, not brake.
SID=h2; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
mkdir -p "$LB_DIR"; printf 'tree-dirty\n' > "$LB_DIR/session-$SID"
run_case "H2 tree-dirty -> changeset-unverified transition + stop_hook_active -> BLOCK (jobhunt regression)" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":true}"
# and the marker is now updated to the new category
if [ "$(cat "$LB_DIR/session-$SID" 2>/dev/null)" = "changeset-unverified" ]; then
  printf 'PASS  %s\n' "H2 marker advanced to changeset-unverified"; PASS=$((PASS+1))
else
  printf 'FAIL  %s  [marker=%s]\n' "H2 marker advance" "$(cat "$LB_DIR/session-$SID" 2>/dev/null)"; FAIL=$((FAIL+1))
fi
rm -rf "$LB_DIR"; ensure_clean

# --- H3: same changeset-unverified category repeated under stop_hook_active →
# brake. (Agent ran /done improperly / not at all and keeps stopping — real
# runaway on THIS category now.)
SID=h3; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
mkdir -p "$LB_DIR"; printf 'changeset-unverified\n' > "$LB_DIR/session-$SID"
run_case "H3 repeated changeset-unverified + stop_hook_active -> brake (allow)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":true}"
rm -rf "$LB_DIR"; ensure_clean

# --- H4: a green done-state ALLOWs AND clears the marker (so a later different
# block is never mistaken for a runaway of a stale cycle).
SID=h4; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
mkdir -p "$LB_DIR"; printf 'tree-dirty\n' > "$LB_DIR/session-$SID"
write_review_log 0
GREEN_DONE "$SID"
run_case "H4 green done-state -> allow (even with a stale marker present)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
if [ ! -f "$LB_DIR/session-$SID" ]; then
  printf 'PASS  %s\n' "H4 allow path cleared the last-block marker"; PASS=$((PASS+1))
else
  printf 'FAIL  %s  [marker still present: %s]\n' "H4 marker cleared" "$(cat "$LB_DIR/session-$SID")"; FAIL=$((FAIL+1))
fi
rm -rf "$LB_DIR"; ensure_clean; clear_review_log

# --- H5: WITHOUT stop_hook_active, the marker is irrelevant — a fresh Stop
# always evaluates fully and blocks. (Marker only gates the brake.)
SID=h5; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
mkdir -p "$LB_DIR"; printf 'changeset-unverified\n' > "$LB_DIR/session-$SID"
run_case "H5 marker present but stop_hook_active=false -> still blocks" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
rm -rf "$LB_DIR"; ensure_clean

# ============================================================================
echo "----------------------------------------"
printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
