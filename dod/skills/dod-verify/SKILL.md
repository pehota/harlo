---
name: dod-verify
description: "Task-DoD verifier. Checks the currently-collected task-dod/<task_key>.json contract against reality — config detect, tests with before/after checkpoint, app startup, task-specific checks, changeset-scoped code review — then writes the per-requirement verification result that clears the Stop gate. Invoke when finishing a task or when the Stop hook blocks with 'run the /done checklist'."
user-invocable: false
argument-hint: '(no args) — verifies the current changeset against the collected task-dod contract'
---

# dod-verify — Task-DoD checklist executor (thin entry point)

You are checking whether **this session's changeset satisfies the DoD contract
`dod-collect` already recorded** at `task-dod/<task_key>.json`. The full
protocol lives in the sibling reference
[`dod-verify-protocol.md`](dod-verify-protocol.md); this entry point routes
you to the steps that actually apply so you read only what you need.

This skill does **zero assembly**. The DoD was already assembled at
collection time by `dod-collect` (base checklist + standing instructions +
task-stated verifications + user instructions + config-detected baseline,
deduped into `requirements[]`). Your job here is purely: read what is on
file, check each requirement, write bespoke per-requirement evidence.

Global rules, escalation policy, and every step live in
`dod-verify-protocol.md` — read each step's section on demand.

## Compute the applicable steps (triage)

Run the deterministic triage — it consumes the effective config from
`dod-verify-detect.sh` and prints **only the steps that apply** to this
changeset:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-verify-detect.sh" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-verify-triage.sh"
```

Each printed line is `[id] <intent> → dod-verify-protocol.md#<anchor>`.
**Execute exactly the printed steps, IN ORDER.** For each one, read that
step's section from `dod-verify-protocol.md` at the given anchor **on
demand** — do **not** pre-read the whole protocol.

**FALLBACK — never skip on doubt.** If the triage command **exits non-zero**
or **prints nothing usable** (jq missing, unreadable config, self-validation
failure), do **NOT** skip anything: open `dod-verify-protocol.md` and execute
ALL steps 0 → 8 in order (run ALL steps — exclude nothing). A
wrongly-excluded step is the one unacceptable outcome; when in doubt, run
everything.

**Every changeset is in scope.** Triage never returns an empty plan: there is
no file classification, so a doc/prose-only changeset gets exactly the same
steps as any other. A step is excluded only when a config signal proves it
vacuous (no lint command configured, no start command configured) — never
because of what kind of file changed.

## The plan artifact (audit-only)

Triage also writes the **full** ordered plan — including the excluded steps
and the exact reason each was excluded — to
`$CLAUDE_PROJECT_DIR/.claude/.harness/done-plan/<task_key>.json`. This is
**evidence only**: the gate gains **no** precondition on it, and you do
**not** read it back — stdout is your instruction; the file is the audit
trail.
