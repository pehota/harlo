# Base Definition of Done

Every contract answers one chain: **agree the task → "how will we know it
works?" (`works_when`: "It works when <observable outcome>") → "how do we
prove that?"**. Each item below is one of those proofs, and each
requirement records what it `proves` about `works_when`.

The minimum requirement set `/dod:define` must fold into every contract.
This is the low-precedence baseline: task-specific requirements augment it,
and a user waiver (step 5 of `dod-define/SKILL.md`) can excuse any one
item from blocking — but no item here may be silently left out of the
requirements array. Every item below is either `applicable:true` with a
real command/agent, or `applicable:false` with a concrete recorded reason.

## Checklist — the proofs

Prerequisite for all of them: if the repo has a build or start step, it runs
green (folded into the checks, not a requirement of its own).

- [ ] **Logic — tests green.** The project's detected test command, run and
      must exit 0.
- [ ] **Outcome — e2e, if the task touches a user-facing flow.** Decided at
      define time — see `dod-define/SKILL.md` step 4.
- [ ] **Outcome — scenario test, observing `works_when` directly.** Decided
      independently of e2e — see step 4. Agent, prompt and skill text is
      observable behavior (prove it with a headless before/after run); N/A
      only when another item already fully proves `works_when`.
- [ ] **Described — relevant documentation updated.** Does this task change
      anything a doc, README, ADR, or design note describes — behavior, a
      command's shape, a config option, an architecture decision? If yes,
      `applicable:true` with `doc_paths` naming every doc that must be
      updated. If no — a pure refactor with no doc-visible surface, an
      internal fix with no documented behavior to update —
      `applicable:false` with a concrete reason. Never silently skip this
      because the task "looks small"; silence is not the same as
      "considered, not applicable." Structurally enforced, same as
      `e2e`/`scenario` — a contract cannot omit `docs` or leave it in the
      wrong shape.
- [ ] **Independent — fresh-agent review.** Always present, protocol
      required — `dod-reviewer` forms its own opinion on the changeset,
      never the implementing agent grading its own work, and judges whether
      each `proves` genuinely proves `works_when`.

## Notes

- This file is read by `dod-define` (step 4) when reasoning about a
  task's requirements — it is guidance for the agent's judgement, not
  itself machine-parsed. The `tests`/`e2e`/`scenario`/`docs`/`review`
  *presence*, `works_when` and every `proves` are enforced structurally by
  `dod/lib/contract.sh` (`contract__validate_docs` mirrors
  `contract__validate_e2e`/`scenario`).
  What `docs` cannot enforce mechanically is whether the named
  `doc_paths` were *correctly* updated — that's `dod-reviewer`'s judgement
  call, checked against the `docs` requirement during the `review` pass.
- The context brief (ADR 0004, `contract.brief`) is contract context, not a
  proof — it is not a checklist item here. It informs the implementer and
  is a floor for `dod-reviewer`'s `standards` lens, but proves nothing about
  `works_when` on its own.
