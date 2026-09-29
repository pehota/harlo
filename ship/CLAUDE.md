# CLAUDE.md

## Code style

- Maximum function argument count: 3. Beyond that, use a single object argument.
- Every adapter gets its own module folder under `adapters/` (e.g. `adapters/<name>/index.ts` or `adapters/<port>/<variant>.ts`), even a cross-cutting one serving multiple ports — never a flat `adapters/<name>.ts` file.
