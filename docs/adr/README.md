# Architecture Decision Records

- [0001 — The Definition of Done is fixed at task start, not assembled at `/done`](0001-task-dod-defined-at-task-start.md) —
  makes the task's DoD an append-only state file written at task start, so `/done`
  verifies against requirements captured up front rather than reconstructed from a
  faded memory of the prompt.
- [0002 — Auto-branching is removed, not merely defaulted off](0002-remove-auto-branching.md) —
  deletes the `auto-branch.sh` hook and its config keys outright, on the grounds
  that deciding where a user's work lives is version-control policy, not the DoD
  gate's job.
