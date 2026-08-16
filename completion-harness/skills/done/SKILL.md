---
name: done
description: "Completion harness executor. Runs the Definition-of-Done checklist in order — config detect, tests with before/after checkpoint, app startup, task-specific checks, changeset-scoped code review — then writes the per-session done-state that clears the Stop gate. Invoke when finishing a task or when the Stop hook blocks with 'Run /done'."
user-invocable: true
argument-hint: '(no args) — verifies the current changeset and writes done-state'
---

# /done — Completion Harness Executor (thin entry point)

You are running the completion gate for **this session's changeset**. The full
protocol lives in the sibling reference [`dod-protocol.md`](dod-protocol.md); this
entry point routes you to the steps that actually apply so you read only what you
need.

Global rules, escalation policy, and every step live in `dod-protocol.md` — read
each step's section on demand.

## Compute the applicable steps (triage)

Run the deterministic triage — it consumes the effective config from
`done-detect.sh` and prints **only the steps that apply** to this changeset:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/done-detect.sh" | bash "${CLAUDE_PLUGIN_ROOT}/scripts/done-triage.sh"
```

Each printed line is `[id] <intent> → dod-protocol.md#<anchor>`. **Execute exactly
the printed steps, IN ORDER.** For each one, read that step's section from
`dod-protocol.md` at the given anchor **on demand** — do **not** pre-read the whole
protocol.

**FALLBACK — never skip on doubt.** If the triage command **exits non-zero** or
**prints nothing usable** (jq missing, unreadable config, self-validation failure),
do **NOT** skip anything: open `dod-protocol.md` and execute ALL steps 0.5 → 8
in order (run ALL steps — exclude nothing). A wrongly-excluded step is the one
unacceptable outcome; when in doubt, run everything.

**Zero applicable steps is a legitimate result, not a fallback trigger.** When
every changed file matches `noncode_globs` (a doc/prose-only changeset), triage
exits 0 with a header explaining the Stop gate has **already** stood down for
this changeset (S_OOS) and prints no step lines — that is success, not failure.
Report that to the user and stop; do not fall back to running every step. The
fallback above is only for triage *failing to produce a usable plan*, never for
triage correctly producing an empty one.

## The plan artifact (audit-only)

Triage also writes the **full** ordered plan — including the excluded steps and the
exact reason each was excluded — to
`$CLAUDE_PROJECT_DIR/.claude/.harness/done-plan/<task_key>.json`. This is **evidence
only**: it is folded into done-state by Step 7 as a `.plan` field. The gate gains
**no** precondition on it, and you do **not** read it back — stdout is your
instruction; the file is the audit trail.
