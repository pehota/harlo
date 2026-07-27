# Completion Harness — Definition of Done (meta)

This is the harness **project's own** Definition of Done — the meta face of the
DoD it ships. Every change to the harness itself is verified against this file.
The harness eats its own dog food: the standard it forces on target projects is
the standard its own changes are held to.

This is not installed into target projects. `dod/base-dod.md` is the portable
artifact that ships into targets; `DOD.md` stays here, in the harness repo.

## Folded-in source — the maintainer's active instructions

Per the harness's own setup-agnostic assembly rule, this DoD folds in whatever
completion standard is in force for the maintainer's agent (external instructions
override harness defaults on conflict — the harness does not depend on where those
instructions live). In this repo that standard currently requires: a change to the
harness is done only when ALL pass:

1. **Meets every stated requirement** — behavior and appearance.
2. **Verified by exercising the actual flow**, not just reading the diff
   (functional + visual). For this repo that means running `test-gate.sh` and
   re-running `install.sh` against a fixture — not asserting from the source.
3. **Code reviewed by a FRESH agent** (clean context, independent — not
   self-review), and all found issues addressed.
4. **Build, tests, lint — all green.** Here: the script test suites
   (`test-gate.sh`, `test-write-state.sh`, `test-detect.sh`) are fully green and
   any regression is treated as a blocker.

No "done" until 1–4 are proven. **State how each was verified.**

**Don't grade your own homework.** Verify against an independent source of truth
(this design doc / these requirements) in the real target medium — never against
your own render, extraction, or mental model.

## Harness-specific checks

- [ ] `test-gate.sh` is fully green (the gate's decision logic must not regress).
- [ ] `install.sh` remains idempotent — re-running it produces no duplicate hook
      entries and no duplicate `.gitignore` lines.
- [ ] The portable bundle hardcodes no machine paths — hooks use
      `$CLAUDE_PROJECT_DIR` (falling back to `$PWD`).
- [ ] `dod/base-dod.md` installs to `.claude/harness/base-dod.md` (committed,
      not gitignored); per-session state stays under `.claude/.harness/`.
- [ ] Any prompt-body logic (e.g. `/done` Step 0.5 assembly) that cannot be
      unit-tested is stated as such — never claimed to have been executed.
