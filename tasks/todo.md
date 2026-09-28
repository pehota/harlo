# ship M0 — walking skeleton (plan.md §6)

Branch: `main`. Baseline: `536f0ca`. Contract: `.dod/main/contract.json`. Brief: `.dod/main/brief.md`.

- [x] A. M0.1–M0.3 scaffold, ids, contract schemas
- [x] B. M0.4–M0.7 start, happy path, ignored
- [x] C. M0.8–M0.13 fix rounds, failure, questions, blocked, delivery signals, invariants
- [x] D. M0.14–M0.16 file State, spawn, config
- [x] E. M0.17–M0.18 apply loop, CLI
- [x] F. M0.19–M0.21 fakes, terminal Principal, e2e lifecycle
- [x] G. M0.22 property tests
- [x] H. M0.23 docs + README e2e + scenario script
- [x] Verify: /dod:verify (fresh review), manual paste run handed to user

## Review

- 29 commits on main (23 steps, 1 prep, 1 fixture move, 4 review fixes). 922 tests green.
- /dod:verify: round 1 pass (7 advisories: 4 fixed, 3 skipped by user), round 2 blocking-only pass.
- Pending: user's manual paste run.

---

# ADR 0004 — context brief + impact trace (dod plugin)

Branch: `main`. Baseline: `749dfb0`. Contract: `.dod/main/contract.json`.

## Shared interface (both bundles code against this)

- **Contract** `--brief JSON` → top-level `brief`:
  `{"applicable":true,"path":".dod/<key>/brief.md"}` (file exists, non-empty;
  relative path resolves against repo root) or
  `{"applicable":false,"reason":"<non-empty>"}`. Required on write.
  `contract_read` exports `CONTRACT_BRIEF` (JSON); a legacy contract without it
  reads as `{"applicable":false,"reason":"contract predates the context brief"}`.
- **Waiver** `id:"review"` = review depth `scope`; its reason must start
  `user: ` or `contract_write` rejects.
- **gitref** `dod_changed_standards <repo> <baseline_sha>` → JSON array of
  repo-relative paths changed since baseline (committed, staged, unstaged,
  untracked; `.dod/` excluded) matching: `CLAUDE.md`, `AGENTS.md`,
  `CONTEXT.md` at any depth, `docs/adr/*`, `.claude/rules/*`,
  `.cursor/rules/*`, `.github/copilot-instructions.md`.
- **Reviewer finding** gains `lens` ∈ `scope|impact|spec|standards|security|correctness`;
  scope findings also carry `kind` ∈ `creep|gap`. Reviewer output gains
  `depth` and `impact_trace: [{file,line,guarantees:[..],inside:bool}]`.
- **result** `result_read` exports `RESULT_CREEP_IDS`: JSON array of ids of
  blocking findings with `lens:"scope"` and `kind:"creep"` in judgement
  requirements.
- **gate** blocking failure + non-empty `RESULT_CREEP_IDS` → block ONCE
  ("report the scope-creep findings, ask the user revert / accept & amend,
  stop — do not fix"), no round bump, contract stays `open`; subsequent Stops
  release until a new result arrives. Gap-only failures → existing branch 8.
- **track** writes under `.dod/` are ignored (no edit logged, no nudge).

## Bundle A — shell (TDD)
- [x] contract.sh brief + review-waiver prefix
- [x] gitref.sh dod_changed_standards
- [x] result.sh RESULT_CREEP_IDS
- [x] gate.sh creep branch
- [x] track.sh .dod/ exclusion
- [x] tests for each; existing contract_write calls pass `--brief`

## Bundle B — prompts (scenario-first)
- [x] agents/dod-context-collector.md
- [x] agents/dod-reviewer.md — lenses, impact trace, floor-not-ceiling, depth
- [x] skills/dod-define — spawn collector after task agreed, `--brief`, implementers read brief, amend keeps baseline+brief
- [x] skills/dod-verify — changed_standards, depth, creep → user decision, gap → fix
- [x] scenario tests: context-collector (fixture repo, tools), reviewer-lenses, define, root-relay

## Bundle C — docs + release
- [x] design-v2.md, dod/README.md, CONTEXT.md, base-dod.md, ADR 0004 accepted, adr README
- [ ] bump dod → 0.4.6

## Review
