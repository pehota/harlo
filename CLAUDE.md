# CLAUDE.md

This is a harness meant to make an agent work on a task independently.

## PRINCIPLES

See docs/PRINCIPLES.md to understand the principles the harness is build on

## Working here

- Layout: `loop/` driver + adapters, `checks/` gates, `templates/` copied into target projects, `tests/` bash tests.
- All `.sh` are run directly (e.g. `loop/loop.sh`), so they need the executable bit. This environment creates files as `644` and git records the mode — after adding/creating any script, `chmod +x` it and `git update-index --chmod=+x`, or it breaks on clone.
- `.harness.json` command strings are `eval`'d as shell. Treat the file as trusted; quote any untrusted input (e.g. agent-supplied paths) before it reaches `eval`.
- Tests: `bash tests/<name>.test.sh` (no framework; self-contained, exit nonzero on failure).
- Commits: use Conventional Commits (`feat:`, `fix:`, `test:`, `docs:`, `chore:`, `refactor:`, …).
