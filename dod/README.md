# dod

Task-DoD lifecycle plugin: the agent records an explicit completion claim,
and the Stop gate blocks until a verification result covers the changeset.

Full design: [`docs/design-v2.md`](../docs/design-v2.md).

## Usage

- `/dod:define [task]` — open a DoD contract before implementation starts.
  Self-invoked by the agent; run it yourself if it forgets.
- `/dod:verify` — run the contract's checks and independent review, write a
  result. Self-invoked by the agent; run it yourself if the gate blocks
  asking for it.

## Manual escape hatch

The Stop gate blocks once per turn-end cycle while a task is claimed
(latched) but not yet verified. There is no `/dod:cancel` command — the two
ordinary ways out are finishing the task (`/dod:verify` until it passes) or
`/clear` (cancels the open contract for this branch).

If you need to abandon a claimed task without clearing the session (e.g. to
keep unrelated conversation context), delete the latch by hand:

```bash
rm -f .dod/<task_key>/state.json
```

`<task_key>` is the current git branch name (sanitised — see
`dod/lib/gitref.sh`'s `dod_task_key`). This clears the claim; the contract
itself stays at `.dod/<task_key>/contract.json` and can still be amended by
re-running `/dod:define`. This is a manual, human-operated escape — the
agent is not instructed to use it as a way around a block.
