# CLAUDE.md

Human-curated only. Implementers propose entries in REFLECTION.md; you promote the good ones here.
(Machine-generated context files give ~no benefit and can slightly hurt; human-written ones help a little.)

## TOOLCHAIN
- Bun for everything: `bun install`, `bun add`, `bun run`, `bun test`. Never npm/yarn/pnpm; use `bunx` not `npx`.
- `bun run typecheck` = tsc --noEmit. `bun run lint` = eslint. `bun run format` = prettier --write. Tests = Vitest.

## STYLE / PATTERNS
- ESLint config is the source of truth for patterns (component-lib boundaries, named exports, etc.). Fix what it reports.
- Functional components + hooks; design tokens for styling; no `any`.

## ARCH
- One feature module per directory under `apps/*/src/features/`. Only the data layer talks to the store.

## TEST STRATEGY
- Vitest. Every acceptance criterion maps to a test that would fail if the behavior regressed.

## GOTCHAS
- (add durable, specific gotchas here — keep short)
