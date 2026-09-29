# CLAUDE.md

## Code style

- Maximum function argument count: 3. Beyond that, use a single object argument.
- Every adapter gets its own module folder under `adapters/` — never a flat `adapters/<name>.ts` file. Three shapes: `adapters/<port>/<variant>.ts` for a port-specific adapter (e.g. `workspace/worktree.ts`, `tracker/md.ts`); `adapters/<name>/index.ts` for a single adapter with no variants (e.g. `adapters/principal/index.ts`); `adapters/<category>/<variant>/index.ts` for a cross-cutting adapter serving multiple ports, grouped by category (e.g. `adapters/agent/claude/index.ts`, `adapters/ask/principal/index.ts`).
