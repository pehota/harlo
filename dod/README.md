# dod

Task-DoD lifecycle plugin: the agent records an explicit completion claim,
and the Stop gate blocks until a verification result covers the changeset.

Full design: [`docs/design-v2.md`](../docs/design-v2.md).
Baseline requirements every contract folds in: [`base-dod.md`](base-dod.md).

## Usage

- `/dod:define [task]` — open a DoD contract before implementation starts.
  Self-invoked by the agent; run it yourself if it forgets. Clarifies an
  ambiguous task first, spawns a fresh `dod-context-collector` to write the
  context brief (the project standards and invariants relevant to this
  task, at `.dod/<key>/brief.md`) the moment the task is agreed, records
  "how will we know it works?" as `works_when`, then derives
  test/e2e/scenario/docs/review per `base-dod.md` as its proofs (each states
  what it `proves`) and shows a confirmation table — including the brief's
  path (or why it's N/A) — before writing anything.
- `/dod:verify` — run the contract's checks and independent review, write a
  result. Self-invoked by the agent; run it yourself if the gate blocks
  asking for it. The review runs a **scope check first**, over the full
  changeset: any change outside the task is a blocking finding, and if it's
  unrequested scope creep the review stops there and the agent asks you to
  revert it or accept it and amend the contract — never an auto-fix. A scope
  gap (part of the task left undone) is also blocking, but only creep stops
  the review early; once past scope, the rest of the lenses (impact, spec,
  standards, security, correctness) run too, reading the context brief as a
  floor. A
  `review` waiver sets the review **depth** to `scope` (scope check only,
  your explicit call, never the agent's) instead of `full`. The independent
  review also confirms every path in an applicable `docs` requirement's
  `doc_paths` was actually updated. The pass table has a row per
  requirement; its findings come only from the reviewer — the agent's own
  observations are settled, fixed or dropped, before verify runs. Advisories
  come only from the final passing round's review (a failing round shows
  blocking findings only). All pass with advisories does not close the
  contract: the agent asks you fix or skip per advisory and stops. All skip
  closes it; a fix is made, re-verified (blocking-only review), then closes.
  Until decided, `prompt.sh` reminds the agent of the pending advisory ids
  on every later prompt.

## Where state lives

All of dod's bookkeeping (contract, result, state, brief, baseline
worktree, `errors.log`) lives in ONE `.dod/` at the **git top-level**, keyed
by branch: `<repo root>/.dod/<task_key>/`. Hooks resolve it from
`CLAUDE_PROJECT_DIR`, skills from the Bash tool's `$PWD` — both normalised
to the top-level, so a session launched in, or `cd`'d into, a subdir still
reads and writes the same `.dod/`.

## Manual escape hatch

The Stop gate blocks once per turn-end cycle while a task is claimed
(latched) but not yet verified. There is no `/dod:cancel` command — the two
ordinary ways out are finishing the task (`/dod:verify` until it passes) or
`/clear` (cancels the open contract for this branch).

If you need to abandon a claimed task without clearing the session (e.g. to
keep unrelated conversation context), delete the latch by hand:

```bash
rm -f "$(git rev-parse --show-toplevel)/.dod/<task_key>/state.json"
```

`<task_key>` is the current git branch name (sanitised — see
`dod/lib/gitref.sh`'s `dod_task_key`). This clears the claim; the contract
itself stays at `.dod/<task_key>/contract.json` and can still be amended by
re-running `/dod:define`. This is a manual, human-operated escape — the
agent is not instructed to use it as a way around a block.
