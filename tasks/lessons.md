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
