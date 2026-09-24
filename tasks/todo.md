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

---

# works_when-driven DoD definition + reviewer-only pass table

## Item 1 — define chain, `proves`, root relay
- [x] A. `dod-verify` SKILL: settle own observations / implementer notes before verify (fix bug → delegate; else drop); never hint the reviewer
- [x] B. `dod-verify` SKILL pass table: findings only from reviewer `findings[]`
- [x] C. `dod-define` SKILL: capture/clarify → Q1 `works_when` → Q2 find & list proofs; `proves` replaces `rationale`; table opens with "It works when:" + Proves column
- [x] C. `contract.sh`: `--works-when` + `proves` required on write; legacy (no works_when / rationale-only) still reads
- [x] C. `dod-reviewer` + verify reviewer input: `works_when`; judge each `proves`
- [x] D. Docs: `docs/design-v2.md` (§5.2, §6.3, §6.7, §7.6, D30), `dod/base-dod.md`, `dod/README.md`
- [x] Tests: `test-contract.sh` (works_when + proves cases), fixtures in gate/prompt/session/track
- [x] Scenario tests `dod/tests/scenario/` (root-relay; define a/b/c), baseline fail → after 3/3

## Review
- Baseline (39b65b7 skill text): root-relay 0/3 (root added its own findings); define (a) 0/3, (b) 0/3, (c) 0/3 — all fail.
- After: root-relay 3/3; define (a) 3/3, (b) 3/3, (c) 3/3. (b) needed a skill fix: ambiguity test = "can works_when be concrete without guessing?".
- `bash run-tests.sh`: all 36 suites passed. Scenario tests stay out of it (glob is `dod/tests/test-*.sh`, non-recursive).

## Future (out of scope)
- Specialised subagent for Q1 (derive `works_when`) and for Q2 (find/list proofs).

---

# Advisory batching across /dod:verify rounds

## Item 2 — final-review-only advisories, decided before close
- [x] a. Carry-over deleted: `result_merge_advisories`, dedupe, `carried_from_round`, "N advisories held for the end" (+ tests, fixtures, doc text). Failing rounds' advisories are ignored.
- [x] b. Kept: `result_next_round` (round = prior + 1, same baseline_sha, else 1) + tests.
- [x] c. `result.sh`: `RESULT_ADVISORY_IDS` (advisory ids of the result).
- [x] d. `state.sh`: `decisions[]` + `decided_diff_hash`; `state_record_decisions` needs exactly one decision per advisory id of the decided result (f4); `state_decision_needs_verify`. No `awaiting_decision` field (f5: written, never read).
- [x] e. Gate: branch 11 (all pass + advisories + no decisions → release, contract open); branch 12 (fix decided + diff unchanged → block). Escalation text: "the advisories of the last review".
- [x] f. `dod-reviewer` `blocking_only` input; SKILL step 5 flag, step 6 findings as-is, step 8 by outcome, escalation lists last review's advisories (not asked), "Advisory decision" section.
- [x] g. Docs: `dod/README.md`, `docs/design-v2.md` (§5.1, §6.4, §6.5, §6.6, §7.6, D31).
- [x] h. Scenario `test-advisory-batching.sh`: (fail), (decide), (after-fix), (escalate).

## Review
- Why the pivot: review round 1 failed (2 blocking + 4 advisories); 4 of 6 rooted in cross-round carry-over. Without carry-over, f1 (decided advisories re-carried) and f2 (carried/new id clash) cannot occur: decisions are keyed to one result's ids + diff_hash and never compared with a later result.
- Unit red → green: test-state 6 → 40/40, test-result 2 → 18/18, test-gate 3 → 56/56.
- Scenario baseline (371f1fb skill): (fail) 0/3 (presents a3), (decide) 0/3 (no recommendation), (after-fix) 0/3 (a9 asked), (escalate) 0/3 (asks b1/a1 as decisions).
- After: all four 3/3. First after-run (escalate) 2/3 — step 8's failing-round "don't list advisories" beat the escalation text; named escalation as the one exception in both places.
- Bite: 16 bad hand-made replies rejected, 4 good accepted.
- `bash run-tests.sh`: all 36 suites passed.
