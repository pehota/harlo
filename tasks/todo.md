# ship — queue loop (feat/ship-queue)

Baseline: `d5eec8b`. No dod for this task (user's call).

- [x] 1. Config rule: every `policy.outcomes` entry needs `tracker.outcomes[o].comment === true` (TDD) + docs + dogfood config edit
- [x] 2. Extract `env/drive-loop.ts` from `env/drive.ts` (behaviour unchanged, drive.test.ts green)
- [x] 3. `env/queue.ts` + `env/queue.test.ts` (TDD): lock, orphans first, `ship next` loop, re-pick guard
- [x] 4. Docs: plan.md M1.14 + §7, docs/queue.md, README link
- [x] Gates: `bun test`, `bun run typecheck`

## Review

- 4 commits on `feat/ship-queue`, not pushed. `bun test` 1115 pass / 0 fail; `tsc --noEmit` clean.
- queue tests reuse `lifecycle()` via a new `items` option (real md Tracker); SIGTERM lock release checked by a throwaway run.
- Dogfood `ship.config.json` edited (rolled_back comment: true), uncommitted there (file is untracked).
- Not done: fresh-agent review (subagent spawning was forbidden for this task).
