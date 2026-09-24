---
status: proposed
---

# Context is split by timing: a define-time brief and a review-time impact trace

Implementers and `dod-reviewer` both missed a write that ran outside its
caller's database transaction. They also kept producing code that ignored the
project's own conventions. Both failures come from missing context, but the
two kinds of context become knowable at different times. So we collect them at
different times.

- **Project standards and domain invariants** already exist before any code
  is written, and they don't change during a task. At the start of
  `/dod:define`, a fresh `dod-context-collector` agent writes them once into
  `.dod/$TASK_KEY/brief.md`. Implementers and the reviewer both read it.
  It is collected by a fresh agent, never the implementer, so the implementer
  can't choose which standards apply to itself.
- **Impact** (the guarantees that enclose the changed code: transaction, lock,
  auth context, ordering) is only knowable once a diff exists. The reviewer
  derives it itself through a mandatory impact trace from each changed hunk.

For the reviewer, the brief is a floor, not a ceiling. It must still form its
own view, which limits the shared blind spots a common brief would otherwise
create.

## Considered Options

- **Each agent discovers context on its own.** Rejected. It is uncontrolled
  and inconsistent between implementer and reviewer, and every agent pays the
  discovery cost again.
- **One shared brief that also covers impact.** Rejected. At define time the
  diff doesn't exist yet, so impact can only be guessed, and a guessed brief
  would give implementer and reviewer the same blind spot.

## Consequences

- The contract references the brief by path. `contract.sh` checks that it
  exists, or that it is `applicable:false` with a concrete reason. If it is
  N/A, the reviewer falls back to its own standards discovery.
- A standards file changed in the diff overrides the brief **only if the task
  asked for that change**. `/dod:verify` computes the changed standards
  mechanically. An unrequested standards edit is a blocking `scope` finding.
- The review gains a depth (`full` | `scope`). The scope check always runs.
  `scope` depth needs the user's explicit consent, recorded as a waiver.
  Scope creep goes to the user as a decision (revert / accept & amend) and is
  never auto-fixed.
- Lens order: scope → impact trace → spec → standards → security →
  correctness. Scope is the only lens that stops the review early, because
  scope creep may be reverted and reviewing it would be wasted work. Impact
  comes second so it is never the lens cut on a large diff. All other lenses
  run in full and report together, since one fix round is cheaper than several.
