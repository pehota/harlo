# Lessons

## Scenario N/A for prompt/skill text is wrong

- **Pattern:** a DoD for a prompt/skill-text change marked the scenario test
  N/A ("no runnable behavior").
- **Why wrong:** agent instructions are behavior — prove them with a headless
  before/after run (`claude -p` against the old vs new text).
- **Rule:** DoD definition starts from "how will we know it works?"
  (`works_when`), and every requirement is a proof of it (`proves`).
