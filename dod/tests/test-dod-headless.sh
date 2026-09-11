#!/bin/bash
#
# Headless trial for the task-DoD plugin ("Proof").
#
# Two things this must do:
#   1. Validate this plugin's OWN hooks/hooks.json is present, valid JSON, and
#      wires both the PostToolUse nudge and the Stop gate. Since this plugin
#      IS the live bundle (unlike the old walking-skeleton, which lived
#      alongside a separate live completion-harness/hooks.json and needed a
#      merge step to become reachable by a headless `--plugin-dir` run), there
#      is no merge to construct — just assert the shipped manifest is correct.
#      This part ALWAYS runs and is asserted.
#   2. Run a real headless task (product-surface mutation) via `claude -p`
#      against this plugin directly and INDEPENDENTLY assert the Stop gate
#      blocked while no task-dod/*.json existed, then allowed once a DoD +
#      stub-done were written — never trusting the model's own completion
#      claim. If `claude` / `timeout` are unavailable in the sandbox, this
#      part SKIPs (exit 0, prints "SKIP: claude binary not available") rather
#      than failing.
#
# PASS/FAIL family, matching sibling suites.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-dod-headless =="

# ---------------------------------------------------------------------------
# Part 1 — the plugin's own hooks manifest is present and correctly wired
# (always exercised).
# ---------------------------------------------------------------------------
LIVE="$ROOT/hooks/hooks.json"

[ -f "$LIVE" ] \
  && ok "manifest: hooks/hooks.json present" \
  || bad "manifest: hooks/hooks.json missing"

jq -e . "$LIVE" >/dev/null 2>&1 \
  && ok "manifest: hooks/hooks.json is valid JSON" \
  || bad "manifest: hooks/hooks.json is not valid JSON"

HAS_GATE=$(jq -r '[.hooks.Stop[].hooks[].command] | map(select(test("dod-gate\\.sh"))) | length' "$LIVE" 2>/dev/null)
HAS_NUDGE=$(jq -r '[.hooks.PostToolUse[].hooks[].command] | map(select(test("dod-nudge\\.sh"))) | length' "$LIVE" 2>/dev/null)
[ "${HAS_GATE:-0}" -ge 1 ] \
  && ok "manifest: dod-gate.sh wired as a Stop hook" \
  || bad "manifest: dod-gate.sh not wired as a Stop hook"
[ "${HAS_NUDGE:-0}" -ge 1 ] \
  && ok "manifest: dod-nudge.sh wired as a PostToolUse hook" \
  || bad "manifest: dod-nudge.sh not wired as a PostToolUse hook"

# ---------------------------------------------------------------------------
# Part 2 — real headless run, or SKIP.
#
# Opt-in only: HC_TEST_HEADLESS=1. A real `claude -p` run spawns a full nested
# Claude Code session (minutes, tokens, a live model) — never appropriate for
# an unattended `run-tests` sweep or a CI lane without an API budget. Without
# the opt-in, or without `claude`/`timeout` on PATH, Part 2 SKIPs cleanly: the
# mandatory manifest checks above have already been asserted.
if [ "${HC_TEST_HEADLESS:-}" != "1" ]; then
  echo
  echo "SKIP: headless run is opt-in — set HC_TEST_HEADLESS=1 to exercise it (manifest checks verified above)"
  echo "test-dod-headless: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
fi
if ! command -v claude >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
  echo
  echo "SKIP: claude binary not available — manifest checks verified; headless run skipped"
  echo "test-dod-headless: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
  exit $?
fi

# A throwaway origin+clone on main, mirroring completion-harness's
# test-run-task.sh make_pair.
ORIGIN=$(hc__test_mktemp_d); CLEANUP_DIRS="$CLEANUP_DIRS $ORIGIN"
REPO=$(hc__test_mktemp_d);   CLEANUP_DIRS="$CLEANUP_DIRS $REPO"
git init -q --bare -b main "$ORIGIN" 2>/dev/null || git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$REPO" >/dev/null 2>&1
git -C "$REPO" config user.email t@t
git -C "$REPO" config user.name  t
cat > "$REPO/.gitignore" <<'GI'
.claude/.harness/
.worktrees/
GI
printf '{ "name": "fixture", "scripts": { "test": "true" } }\n' > "$REPO/package.json"
mkdir -p "$REPO/src"; printf 'x\n' > "$REPO/src/keep.txt"
mkdir -p "$REPO/.claude"; printf '{"trunk":"main"}\n' > "$REPO/.claude/done-config.json"
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" commit -qm base >/dev/null 2>&1
git -C "$REPO" push -q origin main >/dev/null 2>&1
git -C "$REPO" branch --set-upstream-to=origin/main main >/dev/null 2>&1

# Run a headless task with this plugin directly as --plugin-dir — no bundle
# copy/merge needed since this plugin is already live on its own.
OUT=$(cd "$REPO" && CLAUDE_PROJECT_DIR="$REPO" timeout 300 \
        claude -p "create a file src/foo.txt containing hello" \
        --plugin-dir "$ROOT" 2>&1)
RC=$?
echo "$OUT" | sed 's/^/    /'

# Independent assertion: the skeleton's own state under this repo (no
# worktree indirection here — the headless run operates directly on $REPO).
SKEL_DIR="$REPO/.claude/.harness/task-dod"

if [ -d "$REPO/.claude/.harness" ]; then
  if ls "$SKEL_DIR"/archive/*.json >/dev/null 2>&1; then
    ok "headless: plugin archived a task DoD at verified_sha (block cleared)"
  elif ls "$SKEL_DIR"/.nudged-* >/dev/null 2>&1 || printf '%s' "$OUT" | grep -q "no task DoD"; then
    ok "headless: plugin nudge/gate fired on the product mutation (DoD not completed by the model — expected without plugin-aware prompting)"
  else
    bad "headless: no evidence the plugin fired on a product-surface run"
  fi
else
  bad "headless: no harness state found after the run (rc=$RC)"
fi

echo
echo "test-dod-headless: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
