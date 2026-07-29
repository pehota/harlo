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
PROJECT_DIR=$(mktemp -d)
NONGIT_DIR=$(mktemp -d)
trap 'rm -rf "$PROJECT_DIR" "$NONGIT_DIR"' EXIT

git -C "$PROJECT_DIR" init -q
git -C "$PROJECT_DIR" config user.name t
git -C "$PROJECT_DIR" config user.email t@t
printf 'a\n' > "$PROJECT_DIR/a.txt"
# Harness state is git-ignored in a real install; mirror that so the porcelain
# check does not see .harness state as a dirty/untracked tree.
printf '.claude/\n' > "$PROJECT_DIR/.gitignore"
git -C "$PROJECT_DIR" add -A
git -C "$PROJECT_DIR" commit -q -m c1
BASELINE_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)

# advance HEAD so HEAD != baseline for the "commits happened" cases
printf 'b\n' > "$PROJECT_DIR/b.txt"
git -C "$PROJECT_DIR" add -A
git -C "$PROJECT_DIR" commit -q -m c2
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD)

HDIR="$PROJECT_DIR/.claude/.harness"
mkdir -p "$HDIR/baselines" "$HDIR/done-state" "$HDIR/review-log"

# helper to set the baseline file for a session (still keyed by raw session id)
set_baseline() { printf '%s\n' "$2" > "$HDIR/baselines/$1.sha"; }
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
# changeset (BASELINE_SHA..HEAD == b.txt) so the STRUCTURAL coverage check (gate
# Step 8) is satisfied and cases gate on the axis they mean to test (severity /
# outcomes), not on coverage. Cases that specifically exercise coverage set
# files_reviewed explicitly via write_raw_review_log.
write_review_log() {
  local findings
  findings=$(jq -cn --argjson n "$1" '[range(0;$n) | {severity:"high",file:"b.txt",line:1,desc:"finding"}]')
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["b.txt"],"findings":%s,"open_findings":%s}\n' "$HEAD_SHA" "$findings" "$1" > "$HDIR/review-log/$HEAD_SHA.json"
}
clear_review_log() { rm -f "$HDIR/review-log/$HEAD_SHA.json"; }
# write_review_findings <findings_json_array>  → severity-tagged review-log.
# open_findings is set to a dummy 0 to prove the gate recomputes structurally
# from findings[].severity and does NOT trust the self-reported open_findings.
# files_reviewed covers the changeset so coverage passes and the case gates on
# severity alone.
write_review_findings() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["b.txt"],"findings":%s,"open_findings":0}\n' "$HEAD_SHA" "$1" > "$HDIR/review-log/$HEAD_SHA.json"; }
# write_raw_review_log <raw_json>  → write arbitrary (possibly malformed) content.
write_raw_review_log() { printf '%s\n' "$1" > "$HDIR/review-log/$HEAD_SHA.json"; }
# set_min_level <low|medium|high|critical>  → per-case done-config.json.
set_min_level() { mkdir -p "$PROJECT_DIR/.claude"; printf '{"min_review_level":"%s"}\n' "$1" > "$PROJECT_DIR/.claude/done-config.json"; }
clear_config() { rm -f "$PROJECT_DIR/.claude/done-config.json"; }

# Reset tracked files to HEAD but preserve untracked harness state (.claude).
ensure_clean() { git -C "$PROJECT_DIR" checkout -q -- . 2>/dev/null; git -C "$PROJECT_DIR" clean -fdq -e .claude 2>/dev/null; }

# ============================================================================
# Case 1 — stop_hook_active=true → exit 0 (loop guard)
# ============================================================================
run_case "1 stop_hook_active=true -> allow" allow \
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

# ============================================================================
# Case 4 — valid done-state, verified_sha==HEAD, clean tree → exit 0
# ============================================================================
SID=s4; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "4 valid done-state, sha==HEAD, clean, green outcomes + review-log open:0 -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 5 — verified_sha != HEAD → BLOCK
# ============================================================================
SID=s5; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[],\"escalation\":null}"
run_case "5 verified_sha != HEAD -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 6 — dirty tree (sha matches) → BLOCK
# ============================================================================
SID=s6; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[],\"escalation\":null}"
printf 'dirty\n' > "$PROJECT_DIR/a.txt"   # make tree dirty
run_case "6 dirty tree -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
ensure_clean

# ============================================================================
# Case 7 — escalation present, verified_sha==HEAD, clean tree → exit 0
# Escalation is honoured only for the exact changeset it was recorded against
# (sha matches HEAD, tree clean). Under the reordered gate this reaches exit 0.
# ============================================================================
SID=s7; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
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
printf 'dirty\n' > "$PROJECT_DIR/a.txt"   # make tree dirty, HEAD unchanged
run_case "8b HEAD == baseline + dirty + no done-state -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"
ensure_clean

# ============================================================================
# Case 9 — escalation present BUT verified_sha stale (!= HEAD) → BLOCK
# Proves a stale escalation no longer disarms the gate: SHA mismatch is caught
# first, so the escalation never gets a chance to allow the stop.
# ============================================================================
SID=s9; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"deadbeef\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
run_case "9 escalation + stale sha -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Case 10 — escalation present + verified_sha==HEAD but DIRTY tree → BLOCK
# Proves the dirty-tree check is enforced before escalation is honoured.
# ============================================================================
SID=s10; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[],\"escalation\":{\"type\":\"environment\",\"captured_error\":\"docker down\"}}"
printf 'dirty\n' > "$PROJECT_DIR/a.txt"   # make tree dirty
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
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12a no review-log for HEAD -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12b — review-log present with open_findings:2 → BLOCK (open findings)
SID=s12b; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 2
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12b review-log open_findings:2 -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12c — review-log present with open_findings:0 → ALLOW (green review)
SID=s12c; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12c review-log open_findings:0 -> allow" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12d — done-state lint.exit_code:1 (tests green, review green) → BLOCK
SID=s12d; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"lint\":{\"exit_code\":1},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12d lint exit_code:1 -> block" block \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 12e — lint field ABSENT (tests green, review green) → ALLOW (lint skipped)
SID=s12e; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"
run_case "12e lint absent -> allow (not blocked on lint)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# Case 13 — a task_check with status "failed" → BLOCK (tests+lint+review green)
SID=s13; clear_state "$SID"; set_baseline "$SID" "$BASELINE_SHA"; ensure_clean
write_review_log 0
write_done "$SID" "{\"contract_version\":1,\"session_id\":\"$SID\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"lint\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"},{\"desc\":\"y\",\"status\":\"failed\"}],\"escalation\":null}"
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
GREEN_DONE() { write_done "$1" "{\"contract_version\":1,\"session_id\":\"$1\",\"verified_sha\":\"$HEAD_SHA\",\"tree_clean\":true,\"dod\":{\"sources\":[\"base\"],\"items\":[\"x\"]},\"tests\":{\"exit_code\":0},\"task_checks\":[{\"desc\":\"x\",\"status\":\"passed\"}],\"escalation\":null}"; }

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
set_min_level high; write_raw_review_log "{\"contract_version\":1,\"reviewed_sha\":\"$HEAD_SHA\",\"min_review_level\":\"high\",\"files_reviewed\":[\"b.txt\"],\"findings\":[]}"; GREEN_DONE "$SID"
run_case "17l findings is EMPTY array -> allow (nothing found)" allow \
  "{\"session_id\":\"$SID\",\"stop_hook_active\":false}"

# ============================================================================
# Coverage-contract cases (structural: files_reviewed ⊇ changed files).
# The main-repo changeset is BASELINE_SHA..HEAD, which touches exactly ONE file
# (b.txt). To exercise the "missing one changed file" gap we need ≥2 changed
# files, so these cases run in a dedicated isolated repo whose base..HEAD touches
# TWO files (f1.txt, f2.txt). Findings are empty (severity passes) so the ONLY
# gating axis is coverage. done-state is branch-keyed (feature branch → task
# mode) so the pinned merge-base is the changeset base the gate diffs against.
# ============================================================================
COV_REPO=$(mktemp -d)
git -C "$COV_REPO" init -q -b main
git -C "$COV_REPO" config user.name t
git -C "$COV_REPO" config user.email t@t
printf '.claude/\n' > "$COV_REPO/.gitignore"
printf 'base\n' > "$COV_REPO/base.txt"
git -C "$COV_REPO" add -A
git -C "$COV_REPO" commit -q -m base
git -C "$COV_REPO" checkout -q -b feat/cov
printf '1\n' > "$COV_REPO/f1.txt"
printf '2\n' > "$COV_REPO/f2.txt"      # TWO changed files in base..HEAD
git -C "$COV_REPO" add -A
git -C "$COV_REPO" commit -q -m work
COV_HEAD=$(git -C "$COV_REPO" rev-parse HEAD)
CHDIR="$COV_REPO/.claude/.harness"
mkdir -p "$CHDIR/done-state" "$CHDIR/review-log"
# branch-keyed green done-state (task_key = br-feat-cov)
printf '{"contract_version":1,"session_id":"c","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$COV_HEAD" \
  > "$CHDIR/done-state/br-feat-cov.json"
# cov_log <files_reviewed_json_array>  → review-log for COV_HEAD, empty findings
# (severity passes) so coverage is the sole gating axis.
cov_log() { printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":%s,"findings":[]}\n' "$COV_HEAD" "$1" > "$CHDIR/review-log/$COV_HEAD.json"; }

# Case COV-1 — files_reviewed covers ALL changed files → ALLOW.
cov_log '["f1.txt","f2.txt"]'
run_case "COV1 files_reviewed covers all changed -> allow" allow \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

# Case COV-2 — files_reviewed MISSING one changed file → BLOCK ("did not cover").
cov_log '["f1.txt"]'
run_case "COV2 files_reviewed missing f2.txt -> block (did not cover)" block \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

# Case COV-3 — review-log has NO files_reviewed field, changes exist → BLOCK.
# files_reviewed is a required contract field, so this now fails the schema gate
# FIRST (before the coverage check). Block outcome preserved; reason shifted from
# coverage-gap to schema.
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","findings":[]}\n' "$COV_HEAD" > "$CHDIR/review-log/$COV_HEAD.json"
run_case "COV3 no files_reviewed field, changes exist -> block (schema)" block \
  '{"session_id":"c","stop_hook_active":false}' "$COV_REPO"

# Case COV-4 — files_reviewed is a SUPERSET (extra unchanged file) → ALLOW.
cov_log '["f1.txt","f2.txt","unrelated.txt"]'
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
FEAT_REPO=$(mktemp -d)
git -C "$FEAT_REPO" init -q -b main
git -C "$FEAT_REPO" config user.name t
git -C "$FEAT_REPO" config user.email t@t
printf '.claude/\n' > "$FEAT_REPO/.gitignore"
printf 'base\n' > "$FEAT_REPO/base.txt"
git -C "$FEAT_REPO" add -A
git -C "$FEAT_REPO" commit -q -m base
# branch off main, commit feature work → HEAD moves past the fork base
git -C "$FEAT_REPO" checkout -q -b feat/x
printf 'work\n' > "$FEAT_REPO/work.txt"
git -C "$FEAT_REPO" add -A
git -C "$FEAT_REPO" commit -q -m work
FEAT_HEAD=$(git -C "$FEAT_REPO" rev-parse HEAD)

FHDIR="$FEAT_REPO/.claude/.harness"
mkdir -p "$FHDIR/done-state" "$FHDIR/review-log"
# branch-keyed done-state (NOT session-keyed): br-feat-x
printf '{"contract_version":1,"session_id":"whatever","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["x"]},"tests":{"exit_code":0},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$FEAT_HEAD" \
  > "$FHDIR/done-state/br-feat-x.json"
# independent review-log for the feature HEAD, no open findings. files_reviewed
# covers the feature changeset (merge-base(main,feat/x)..HEAD == work.txt) so the
# STRUCTURAL coverage check passes and the cross-session-resume assertion holds.
printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":["work.txt"],"findings":[],"open_findings":0}\n' "$FEAT_HEAD" \
  > "$FHDIR/review-log/$FEAT_HEAD.json"

run_case "16a feat/x branch-keyed state ALLOWs for session A" allow \
  '{"session_id":"A","stop_hook_active":false}' "$FEAT_REPO"
run_case "16b same state ALLOWs for a DIFFERENT session B (cross-session resume)" allow \
  '{"session_id":"B","stop_hook_active":false}' "$FEAT_REPO"

rm -rf "$FEAT_REPO"

# ============================================================================
echo "----------------------------------------"
printf 'Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
