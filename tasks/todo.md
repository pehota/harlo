# claim → verify gating for the `dod` plugin

Plan: `~/.claude/plans/validated-bubbling-cocoa.md`
Branch: `main`. Baseline: `9a22e74`.

## Bundle 1 — core scripts
- [ ] `dod/scripts/dod-complete-task.sh` — arm the latch, point at dod-verify
- [ ] `dod/scripts/dod-user-turn.sh` — UserPromptSubmit: disarm + remind
- [ ] `dod/scripts/dod-task-log.sh` — TaskCompleted audit trail
- [ ] `dod/scripts/dod-gate.sh` — latch-driven; drop dod-stub-done.sh from block text
- [ ] `dod/scripts/lib-classify.sh` — HC_BASE → HC_BASE_ORIG; pin artifact_paths; validate base sha
- [ ] `dod/hooks/hooks.json` — register UserPromptSubmit + TaskCompleted (never SubagentStop)

## Bundle 2 — tests
- [ ] `dod/tests/test-helpers.sh` — untidy fixture builders
- [ ] `dod/tests/test-dod-claim.sh` — one case per state-machine row + each bypass

## Bundle 3 — docs
- [ ] `docs/adr/0003-claim-triggered-verification.md`
- [ ] `docs/adr/0001-*.md` — pointer to 0003
- [ ] `dod/README.md` — line 72 claims the classifier is unused for gating
- [ ] `dod/scripts/dod-gate.sh` header comment
- [ ] `docs/architecture.md` — only where it contradicts

## Bundle 4 — release
- [ ] `dod/.claude-plugin/plugin.json` 0.1.2 → 0.2.0 (needs `!` / BREAKING CHANGE footer)

## Definition of Done
- [ ] 1. Every requirement met — state-machine table walked
- [ ] 2. Real flow exercised on untidy fixtures (not diff-reading)
- [ ] 3. Fresh `dod:dod-reviewer` review; blocking findings fixed, rest batched to user
- [ ] 4. `./run-tests.sh` green + `shellcheck -S error -x` on changed files
- [ ] 5. Live smoke test, stdout/exit pasted per step

## Review
_(filled at the end)_
