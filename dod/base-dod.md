# Base Definition of Done

The minimum requirement set `/dod:define` must fold into every contract.
This is the low-precedence baseline: task-specific requirements augment it,
and a user waiver (step 3.5 of `dod-define/SKILL.md`) can excuse any one
item from blocking — but no item here may be silently left out of the
requirements array. Every item below is either `applicable:true` with a
real command/agent, or `applicable:false` with a concrete recorded reason.

## Checklist

- [ ] **Tests green.** The project's detected test command, run and must
      exit 0.
- [ ] **e2e, if the task touches a user-facing flow.** Decided at define
      time — see `dod-define/SKILL.md` step 3.4.
- [ ] **Scenario test, if the task changes observable behavior.** Decided
      independently of e2e — see step 3.4.6.
- [ ] **Independent (fresh-agent) review.** Always present, protocol
      required — `dod-reviewer` forms its own opinion on the changeset,
      never the implementing agent grading its own work.
- [ ] **Relevant documentation updated.** Does this task change anything a
      doc, README, ADR, or design note describes — behavior, a command's
      shape, a config option, an architecture decision? If yes,
      `applicable:true` with `doc_paths` naming every doc that must be
      updated. If no — a pure refactor with no doc-visible surface, an
      internal fix with no documented behavior to update —
      `applicable:false` with a concrete reason. Never silently skip this
      because the task "looks small"; silence is not the same as
      "considered, not applicable." Structurally enforced, same as
      `e2e`/`scenario` — a contract cannot omit `docs` or leave it in the
      wrong shape.

## Notes

- This file is read by `dod-define` (step 3.4.7) when reasoning about a
  task's requirements — it is guidance for the agent's judgement, not
  itself machine-parsed. The `tests`/`e2e`/`scenario`/`docs`/`review`
  *presence* is enforced structurally by `dod/lib/contract.sh`
  (`contract__validate_docs` mirrors `contract__validate_e2e`/`scenario`).
  What `docs` cannot enforce mechanically is whether the named
  `doc_paths` were *correctly* updated — that's `dod-reviewer`'s judgement
  call, checked against the `docs` requirement during the `review` pass.
