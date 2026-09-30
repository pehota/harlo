# CLAUDE.md

## Code style

- Maximum function argument count: 3. Beyond that, use a single object argument.
- Every adapter gets its own module folder under `src/adapters/` — never a flat `src/adapters/<name>.ts` file. Three shapes: `src/adapters/<port>/<variant>.ts` for a port-specific adapter (e.g. `workspace/worktree.ts`, `tracker/md.ts`); `src/adapters/<name>/index.ts` for a single adapter with no variants (e.g. `src/adapters/principal/index.ts`); `src/adapters/<category>/<variant>/index.ts` for a cross-cutting adapter serving multiple ports, grouped by category (e.g. `src/adapters/agent/claude/index.ts`, `src/adapters/ask/principal/index.ts`).
