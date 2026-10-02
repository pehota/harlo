# CLAUDE.md

## Code style

- Maximum function argument count: 3. Beyond that, use a single object argument.
- Every adapter gets its own module folder under `src/adapters/` — never a flat `src/adapters/<name>.ts` file. Three shapes: `src/adapters/<port>/<variant>.ts` for a port-specific adapter (e.g. `workspace/worktree.ts`, `tracker/md.ts`); `src/adapters/<name>/<impl>.ts` for a single adapter with no variants, named for what it does (e.g. `src/adapters/principal/tty.ts`); `src/adapters/<category>/<variant>/<impl>.ts` for a cross-cutting adapter serving multiple ports, grouped by category (shape only — `src/adapters/agent/claude/` and `src/adapters/ask/principal/` still have an `index.ts` each, not yet renamed to comply).
- Never name any module `index.ts` (not just adapters — applies repo-wide: `src/core/`, `src/contracts/`, `src/runner/`, everywhere) to export multiple things or a default value. Every file gets a real, specific name so imports stay qualified (`import { tty } from "./adapters/principal/tty"`, never a barrel or default export).

## Dev tools

- `env/judge.ts` renders a Delivery's real journal (input/output/reasoning per step-call) for a human judging step-output quality. It's a development/debugging tool, not part of the shipped runtime — `ship` never invokes it. See [`docs/judge.md`](docs/judge.md).

## Environment scripts

- `env/setup.ts` writes a repo's `ship.config.json` and its machine config `~/.config/ship/<projectId>.json`, then loads them with `bin/ship status`. A user-facing environment script, not a dev tool. Environment code: never import `src/core` or `src/runner` (`src/contracts` is fine). Its `ADAPTERS` registry lists only adapters that implement every op of their port; add one when it is completed (e.g. jira after pehota/harlo#43). An agent setting up a repo runs it non-interactively: `bun <ship>/env/setup.ts --yes [flags]`. See [`README.md`](README.md#set-up-ship-in-another-repo).
