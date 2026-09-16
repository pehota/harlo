# Architecture Decision Records

- [0001 — The Definition of Done is fixed at task start, not assembled at `/done`](0001-task-dod-defined-at-task-start.md) —
  makes the task's DoD an append-only state file written at task start, so `/done`
  verifies against requirements captured up front rather than reconstructed from a
  faded memory of the prompt.
- [0002 — Auto-branching is removed, not merely defaulted off](0002-remove-auto-branching.md) —
  deletes the `auto-branch.sh` hook and its config keys outright, on the grounds
  that deciding where a user's work lives is version-control policy, not the DoD
  gate's job.
- [0003 — Verification is triggered by an explicit claim, not inferred from a stopping agent](0003-claim-triggered-verification.md) —
  the Stop gate goes silent until the agent arms a claim latch, then blocks until a
  HEAD-keyed verification result *and* a clean product surface cover the changeset;
  establishes the asymmetry rule that an agent-authored signal may only tighten the gate.

> **All ADRs above are marked `review: needed`.** They record decisions for the
> implementation that [`../design-v2.md`](../design-v2.md) redesigns. Revisit
> them once the new harness has been built and exercised — not before.
