# Lessons

## Scenario N/A for prompt/skill text is wrong

- **Pattern:** a DoD for a prompt/skill-text change marked the scenario test
  N/A ("no runnable behavior").
- **Why wrong:** agent instructions are behavior — prove them with a headless
  before/after run (`claude -p` against the old vs new text).
- **Rule:** DoD definition starts from "how will we know it works?"
  (`works_when`), and every requirement is a proof of it (`proves`).

## Fixtures must not replay another project's incident

- **Pattern:** a scenario test fixture copied wording and details straight
  from a real incident (task text, function names, review notes) and
  asserted on those exact strings.
- **Why:** a dod test fixture was built from another project's incident
  specifics, leaking that repo's concerns into dod.
- **Rule:** fixtures model the pattern, never replay another project's
  incident — abstract the categories, then invent neutral examples.

## Verification results are built from the log, never a template

- **Pattern:** a verify round's `result.json` was written from the previous
  round's script with `"verdict":"pass"` hard-coded, before reading the
  scenario log — which had failed. A false pass reached `result.json`.
- **Why wrong:** the result is the gate's trust anchor; a templated verdict
  is grading your own homework with the answer key pre-filled.
- **Rule:** derive every check verdict from that run's actual exit code/log
  (parse it in the same script that writes the result); never reuse a prior
  round's verdict values.

## Test data is named and placed as test data

- **Pattern:** transition-row tables used only by tests lived in
  `src/core/rows/*.ts`, which reads like production code.
- **Why wrong:** a reader cannot tell test data from runtime code; it
  invites production imports of fixtures.
- **Rule:** test-only data gets a test name (`*.fixture.ts`, a `fixtures/`
  dir) and sits next to the tests that use it. Tell implementers this up
  front when asking for shared tables.

## Answer only the question asked

- **Pattern:** "how many batches?" got a full status table.
- **Why wrong:** the user asked for a number; extra content costs reading time.
- **Rule:** a closed question gets the bare answer. Add detail only if asked.

## Don't re-run checks for changes they cannot see

- **Pattern:** editing `tasks/*.md` changed the dod diff hash, and I started
  re-running the full test battery.
- **Why wrong:** the checks exercise `ship/` only; markdown outside it cannot
  change their outcome. Minutes wasted for zero information.
- **Rule:** if the only change since a passing run is outside every check's
  inputs, reuse that run's verdicts and record which hash they came from.
