#!/bin/bash
#
# BEHAVIOURAL test — a MISSING tree baseline must not manufacture authorship.
#
# hc_tree_status is deliberately strict when the baseline .dirty is absent: the
# baseline set is EMPTY, so every current change blocks. That VERDICT is correct
# and stays. What was wrong is the CLAIM — the block reason said "changes you
# introduced" about paths the harness has no way to attribute (a two-month-old
# worktree got blamed on the current session). This suite pins both halves: the
# decision is UNCHANGED, and the degraded case says authorship is unknown.
#
# DELIBERATE CLASSIFICATION (do not "fix" it into a third case): a ZERO-LENGTH
# .dirty is NOT degraded. baseline-snapshot.sh writes `git status --porcelain >`
# and documents "always create the file (even when empty) so 'missing' (→
# strict) is distinguishable from 'clean at baseline'" — a clean repo at
# SessionStart legitimately produces 0 bytes. An EMPTY baseline set means
# nothing was pre-existing, so there "you introduced this" is TRUE and the
# original wording must survive. Case B asserts exactly that.
#
# Runs against the source-tree scripts; each case builds an isolated throwaway
# git repo, in the style of test-tree-status.sh. No install, no set -e.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
HC_COMMON="$SCRIPTS/harness-common.sh"
GATE="$SCRIPTS/done-gate.sh"

# The honest-degraded phrase the gate must use when it cannot attribute a path,
# and the assertive phrase it must keep when it CAN.
UNKNOWN_PHRASE="authorship cannot be determined"
ASSERTIVE_PHRASE="changes you introduced"

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== test-missing-baseline =="

if [ ! -f "$HC_COMMON" ]; then
  bad "harness-common.sh missing at $HC_COMMON"
  echo; echo "test-missing-baseline: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot build done-state fixtures"
  echo; echo "test-missing-baseline: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

# is_block <stdout> → 0 if the gate stdout is a block decision.
is_block() { printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1; }

# Fresh repo on `main` (trunk → session mode, task_key=session-<sid>), harness
# state gitignored. Echoes the repo path. (Same shape as test-tree-status.sh.)
make_repo() {
  local r; r=$(mktemp -d)
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t
  git -C "$r" config user.name t
  printf '.claude/\n' > "$r/.gitignore"
  printf 'a\n' > "$r/a.js"
  git -C "$r" add -A
  git -C "$r" commit -qm c1
  mkdir -p "$r/.claude/.harness/baselines" "$r/.claude/.harness/done-state" "$r/.claude/.harness/review-log"
  printf '%s' "$r"
}

# Green done-state + review-log for HEAD, so the gate reaches the tree check.
seed_green_done() {
  local r="$1" sid="$2"
  local head; head=$(git -C "$r" rev-parse HEAD)
  printf '%s\n' "$head" > "$r/.claude/.harness/baselines/$sid.sha"
  printf '{"contract_version":1,"reviewed_sha":"%s","min_review_level":"high","files_reviewed":[],"findings":[],"open_findings":0}\n' "$head" \
    > "$r/.claude/.harness/review-log/$head.json"
  printf '{"contract_version":1,"session_id":"%s","verified_sha":"%s","tree_clean":true,"dod":{"sources":["base"],"items":["tests green"]},"tests":{"exit_code":0,"command":"t","output_tail":"ok"},"task_checks":[{"desc":"x","status":"passed"}],"escalation":null}\n' "$sid" "$head" \
    > "$r/.claude/.harness/done-state/session-$sid.json"
}

run_gate() {
  printf '{"session_id":"%s","stop_hook_active":false}' "$2" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GATE" 2>/dev/null
}

# ============================================================================
# A — BASELINE MISSING. Still BLOCKS (strict direction preserved), but the
#     reason must NOT assert the session introduced the path; it must say
#     authorship is undeterminable and name the restart remediation.
# ============================================================================
R=$(make_repo); SID=nobaseline
seed_green_done "$R" "$SID"
rm -f "$R/.claude/.harness/baselines/$SID.dirty"     # no baseline at all
printf 'old\n' > "$R/maybe-old.js"                    # unattributable path
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  ok "A missing baseline still BLOCKS (strict direction unchanged)"
else
  bad "A missing baseline ALLOWed — strict guarantee lost. out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "$UNKNOWN_PHRASE"; then
  ok "A missing baseline: reason says authorship cannot be determined"
else
  bad "A missing baseline: reason lacks '$UNKNOWN_PHRASE'. out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "$ASSERTIVE_PHRASE"; then
  bad "A missing baseline: reason still ASSERTS authorship ('$ASSERTIVE_PHRASE'). out=$OUT"
else
  ok "A missing baseline: reason no longer asserts the session introduced it"
fi
if printf '%s' "$OUT" | grep -q "restart the session"; then
  ok "A missing baseline: reason carries the restart remediation"
else
  bad "A missing baseline: reason omits the restart remediation. out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "maybe-old.js"; then
  ok "A missing baseline: reason still names the blocking path"
else
  bad "A missing baseline: reason does not name the blocking path. out=$OUT"
fi
rm -rf "$R"

# ============================================================================
# B — BASELINE ZERO-LENGTH (a clean repo at SessionStart). NOT degraded: the
#     baseline set is empty because nothing WAS pre-existing, so the path really
#     is the session's. Blocks, and keeps the assertive wording.
# ============================================================================
R=$(make_repo); SID=emptybaseline
seed_green_done "$R" "$SID"
: > "$R/.claude/.harness/baselines/$SID.dirty"        # clean at baseline
printf 'mine\n' > "$R/introduced.js"
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  ok "B 0-byte baseline BLOCKS (unchanged)"
else
  bad "B 0-byte baseline ALLOWed. out=$OUT"
fi
if printf '%s' "$OUT" | grep -q "$UNKNOWN_PHRASE"; then
  bad "B 0-byte baseline wrongly treated as degraded — a clean baseline CAN attribute. out=$OUT"
else
  ok "B 0-byte baseline: NOT degraded (no authorship hedge)"
fi
if printf '%s' "$OUT" | grep -q "$ASSERTIVE_PHRASE" && printf '%s' "$OUT" | grep -q "introduced.js"; then
  ok "B 0-byte baseline: keeps the (true) assertive wording and names the file"
else
  bad "B 0-byte baseline lost the assertive wording. out=$OUT"
fi
rm -rf "$R"

# ============================================================================
# C — BASELINE CORRECT and recording the change as pre-existing → ALLOW, with
#     no hedge anywhere in the output.
# ============================================================================
R=$(make_repo); SID=goodbaseline
printf 'pre\n' > "$R/preexisting.js"
git -C "$R" status --porcelain > "$R/.claude/.harness/baselines/$SID.dirty"
seed_green_done "$R" "$SID"
OUT=$(run_gate "$R" "$SID")
if is_block "$OUT"; then
  bad "C correct baseline BLOCKed a pre-existing-only tree. out=$OUT"
else
  ok "C correct baseline ALLOWs (unchanged)"
fi
if printf '%s' "$OUT" | grep -q "$UNKNOWN_PHRASE"; then
  bad "C correct baseline emitted the authorship hedge. out=$OUT"
else
  ok "C correct baseline: no authorship hedge in the output"
fi
rm -rf "$R"

# ============================================================================
# D — the flag itself. HC_TREE_BASELINE_MISSING must be SET on every path,
#     including the clean-tree early return, and must track file PRESENCE only.
# ============================================================================
# shellcheck source=/dev/null
. "$HC_COMMON" 2>/dev/null

R=$(make_repo); SID=flag
(
  export CLAUDE_PROJECT_DIR="$R"
  PROJECT_DIR="$R"; HARNESS_DIR="$R/.claude/.harness"

  HC_TREE_BASE_FILE="$R/.claude/.harness/baselines/$SID.dirty"
  rm -f "$HC_TREE_BASE_FILE"
  printf 'x\n' > "$R/dirty.js"
  hc_tree_status "$SID" >/dev/null 2>&1
  printf 'MISSING=%s\n' "${HC_TREE_BASELINE_MISSING:-unset}"

  : > "$HC_TREE_BASE_FILE"
  hc_tree_status "$SID" >/dev/null 2>&1
  printf 'EMPTY=%s\n' "${HC_TREE_BASELINE_MISSING:-unset}"

  # Clean tree (early return) — the flag must still be defined.
  rm -f "$R/dirty.js"
  rm -f "$HC_TREE_BASE_FILE"
  hc_tree_status "$SID" >/dev/null 2>&1
  printf 'CLEAN=%s\n' "${HC_TREE_BASELINE_MISSING:-unset}"
) > "$R/.flag.out" 2>/dev/null

FLAGS=$(cat "$R/.flag.out" 2>/dev/null)
case "$FLAGS" in
  *"MISSING=1"*) ok "D flag is 1 when the baseline file is absent" ;;
  *) bad "D flag not 1 for an absent baseline. got: $FLAGS" ;;
esac
case "$FLAGS" in
  *"EMPTY=0"*) ok "D flag is 0 for a 0-byte baseline (present = usable)" ;;
  *) bad "D flag not 0 for a 0-byte baseline. got: $FLAGS" ;;
esac
case "$FLAGS" in
  *"CLEAN=1"*) ok "D flag is set even on the clean-tree early return" ;;
  *) bad "D flag undefined on the clean-tree path. got: $FLAGS" ;;
esac
rm -rf "$R"

# ============================================================================
# E — case B's premise, enforced at the WRITE side. B only holds if a 0-byte
#     .dirty can ONLY mean "clean at SessionStart". `git status --porcelain >
#     file` truncates the target BEFORE git runs, so a failing/killed git left a
#     0-byte file that B then reads as a healthy, empty baseline set — and the
#     gate asserts "changes you introduced" about paths it never observed. The
#     capture must therefore be ATOMIC: temp file, moved into place only on a
#     clean git exit; on failure NO file at all, so the degraded case A fires.
#
#     git is shimmed to fail ONLY on `status --porcelain` (everything else
#     delegates to the real binary), which is the exact failure shape.
# ============================================================================
SNAP="$SCRIPTS/baseline-snapshot.sh"
REAL_GIT=$(command -v git)
make_failing_git_dir() {
  local d; d=$(mktemp -d)
  cat > "$d/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  if [ "\$a" = "--porcelain" ]; then exit 128; fi
done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$d/git"
  printf '%s' "$d"
}
run_snapshot() {  # <repo> <sid> [shim_dir]
  local extra_path=""
  [ -n "$3" ] && extra_path="$3:"
  printf '{"session_id":"%s","source":"startup"}' "$2" \
    | PATH="${extra_path}$PATH" CLAUDE_PROJECT_DIR="$1" bash "$SNAP" >/dev/null 2>&1
}

# E1 CONTROL — a healthy capture must still produce the file (the fix must not
#     simply stop writing baselines).
R=$(make_repo); SID=atomic
run_snapshot "$R" "$SID"
if [ -f "$R/.claude/.harness/baselines/$SID.dirty" ]; then
  ok "E1 control: a healthy SessionStart still writes the tree baseline"
else
  bad "E1 control: no baseline written on a healthy SessionStart"
fi
rm -rf "$R"

# E2 — git status fails, no prior baseline → NO file (not a 0-byte one).
R=$(make_repo); SID=atomic
SHIM=$(make_failing_git_dir)
run_snapshot "$R" "$SID" "$SHIM"
B="$R/.claude/.harness/baselines/$SID.dirty"
if [ ! -f "$B" ]; then
  ok "E2 failed capture leaves NO baseline (degraded, not a fake-clean 0-byte)"
else
  bad "E2 failed capture left a $(wc -c < "$B" | tr -d ' ')-byte baseline — B's premise broken"
fi
rm -rf "$R"

# E3 — git status fails with a STALE baseline present → it is REMOVED. Keeping
#     it would whitelist an earlier session's porcelain as this session's
#     pre-existing set. Missing is the honest, strict state (case A).
R=$(make_repo); SID=atomic
mkdir -p "$R/.claude/.harness/baselines"
printf ' M stale.js\n' > "$R/.claude/.harness/baselines/$SID.dirty"
SHIM=$(make_failing_git_dir)
run_snapshot "$R" "$SID" "$SHIM"
if [ ! -f "$R/.claude/.harness/baselines/$SID.dirty" ]; then
  ok "E3 failed capture removes a stale baseline rather than reusing it"
else
  bad "E3 stale baseline survived a failed capture: $(cat "$R/.claude/.harness/baselines/$SID.dirty")"
fi
# …and no temp file is left behind to be mistaken for state.
if ls "$R"/.claude/.harness/baselines/*.tmp.* >/dev/null 2>&1; then
  bad "E3 a .tmp.* scratch file was left in baselines/"
else
  ok "E3 no temp scratch left in baselines/"
fi
rm -rf "$R" "$SHIM"

echo
echo "test-missing-baseline: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
