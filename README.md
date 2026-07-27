# Completion Harness

A Claude Code plugin that turns your Definition of Done into a **gate**, not a
suggestion. Claude can't call a task "done" until the checks actually pass — and
it can't skip them by forgetting.

## What it enforces

Before Claude can end a task, `/done` must pass on the current changeset:

- tests green
- lint green (if configured)
- an **independent** review of the changeset — a fresh agent, not self-review
- any task-specific checks you named (e.g. "verify the UI in a browser")

Verification is keyed to the **git branch** (the task), so it survives across
sessions: pick a task back up later and the harness remembers what's been
verified. On `main`/trunk it auto-creates a task branch on your first edit.

## Install

```
/plugin marketplace add git@pehota:pehota/harlo.git
/plugin install completion-harness@harlo
```

Try it for a single session without installing:

```
claude --plugin-dir completion-harness
```

## Layout

- **`completion-harness/`** — the plugin: scripts, the `/done` skill, hooks, base
  DoD. See its [README](completion-harness/README.md).
- **`completion-harness-design.md`** — full design and rationale.

## Status

Early. Validated in supervised (interactive) use; autonomous / headless runs are
not yet verified.
