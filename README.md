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

**Work on a branch — ideally a worktree** (`completion-harness/scripts/new-worktree.sh`
provisions one). Directly on trunk there is no branch to key the changeset anchor on, so
the harness keys it on a per-session file instead; that file can go missing (deleted,
age-reaped, or looked up under a mismatched session id) and the gate then blocks rather
than guess — four false blocks in one observed session. On a branch the anchor is keyed
on the branch and its starting point is derivable from git. Not a cure-all: a branch does
not fix a deleted state directory or a disabled plugin. See
[`completion-harness/README.md`](completion-harness/README.md#work-on-a-branch--worktrees-make-it-cheap).

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
- **`docs/`** — the docs:
  - [`architecture.md`](docs/architecture.md) — navigable map (C4 diagrams, flows,
    the Stop-gate decision tree, edge-case matrix). **Start here to understand the harness.**
  - [`design.md`](docs/design.md) — full design and rationale.
  - [`design-brief.md`](docs/design-brief.md) — the original design prompt (historical).

## Tests

```
bash run-tests.sh
```

Runs all suites (exits non-zero if any fail). The suites are self-contained,
tracked files under `completion-harness/tests/` that source the real bundle
scripts directly, so no install step is needed. Run a single suite with `bash
completion-harness/tests/test-<name>.sh`.

**Run tests on push:** enable the tracked `pre-push` hook (installs alongside the
repo's existing hooks; `core.hooksPath` is deliberately not used so those keep
working):

```
cp .githooks/pre-push .git/hooks/pre-push && chmod +x .git/hooks/pre-push
```

### Versioning

The single source of truth for the plugin version is
`completion-harness/.claude-plugin/plugin.json` (`"version"`). The version is
**derived from conventional commits** and enforced on push.

While the major is `0` (pre-1.0) we use a damped **0.x convention**: a
breaking change bumps the **minor** (`0.1.0` → `0.2.0`); a `feat`, `fix`, or
`perf` bumps the **patch** (`0.1.0` → `0.1.1`); `docs`/`chore`/`test`/`ci`/
`style`/`build`/`refactor` do **not** bump. From `1.0.0` on, standard semver
applies (breaking → major, feat → minor, fix/perf → patch).

The `pre-push` hook enforces this: if the commits you're pushing require a
higher version than `plugin.json` declares, it **auto-applies the bump**
(commits `chore(release): bump completion-harness to X.Y.Z`) and aborts the
push — run your push again to include the release commit. Bypass with
`git push --no-verify`.

Preview or apply the bump manually:

```
bash bump-version.sh --dry-run   # print the recommendation, change nothing
bash bump-version.sh             # write plugin.json + commit the bump
```

## Status

Early. Validated in supervised (interactive) use; autonomous / headless runs are
not yet verified.
