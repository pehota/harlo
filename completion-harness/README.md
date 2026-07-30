# Completion Harness

Makes Claude Code's Definition of Done a **structural forcing function**, not
advisory text. A Stop hook blocks the agent from declaring a task "done" until a
`/done` verification has actually passed for the current changeset.

## What it is

Three parts:

- **`scripts/done-gate.sh`** — a **Stop hook** (the gate). Fires on every turn
  exit; blocks unless a valid done-state exists for the session and matches live
  git state (HEAD == verified SHA, clean tree).
- **`skills/done/SKILL.md`** + **`dod-protocol.md`** — the **`/done` skill** (the
  executor), split for progressive disclosure: a thin `SKILL.md` runs a
  deterministic **triage** (`done-detect.sh | done-triage.sh`) that computes which
  DoD steps apply to the changeset and writes an audit plan
  (`done-plan/<task_key>.json`); the agent reads each applicable step's section
  from `dod-protocol.md` on demand. The checklist itself — config detect, tests
  (before/after checkpoint), app startup, task-specific checks, changeset-scoped
  independent code review — then writes the done-state that clears the gate.
- **`scripts/baseline-snapshot.sh`** — a **SessionStart hook**. Records the
  baseline HEAD SHA per session and optionally caches a background test snapshot
  keyed by SHA.

The two most error-prone `/done` steps are **scripted for determinism** (never
hand-written by the LLM): Step 0 config detection + fingerprinting
(`scripts/done-detect.sh`) and Step 7 done-state assembly with live-injected git
facts (`scripts/done-write-state.sh`, which refuses a dirty tree).

State lives under `<project>/.claude/.harness/` (git-ignored) and is keyed by
**task** (the git branch), with session as a fallback on trunk — so a task's
verification survives across sessions, and parallel work in separate worktrees
(different branches) is fully isolated.

## Install as a plugin (primary)

The completion harness ships as a self-contained Claude Code plugin, distributed
via a marketplace in this same repo.

```
/plugin marketplace add <repo>          # this repo (URL or local path)
/plugin install completion-harness@harlo
```

Local development — load the plugin directly from the bundle dir without a
marketplace:

```bash
claude --plugin-dir completion-harness
```

The plugin wires the SessionStart / Stop / PreToolUse hooks from
`hooks/hooks.json` and resolves its scripts and base DoD under
`${CLAUDE_PLUGIN_ROOT}`. Per-project state still lives under
`<project>/.claude/.harness/` (git-ignored).

`install.sh` (below) is the **non-plugin fallback** — use it only when the
plugin path is unavailable.

## Install (non-plugin fallback)

```bash
bash install.sh /path/to/project    # defaults to $PWD
```

This is idempotent. It:
- copies `scripts/`, `skills/done/`, and the base DoD artifact
  (`dod/base-dod.md` → `.claude/dod/base-dod.md`) into the project's
  `.claude/` — `/done` reads that base DoD and folds in the agent's own active
  instructions plus the task into one effective DoD per run (setup-agnostic — no
  assumption about where your instructions live),
- wires the Stop + SessionStart hooks into `.claude/settings.local.json`
  (machine-local; merged with `jq`, existing hooks preserved),
- seeds a starter `.claude/done-config.json` if absent,
- adds `.claude/.harness/` to the project's `.gitignore`.

Requires `jq` and `git`.

## Use

When you finish a task (or when the Stop hook blocks with "Run /done"), run:

```
/done
```

It verifies the changeset and writes
`.claude/.harness/done-state/<task_key>.json` (keyed by the git branch, with a
`session-<id>` fallback on trunk). The next turn exit sees a valid done-state that
matches the live HEAD/tree and lets the agent stop.

**Parallel work must use separate git worktrees** — the harness makes
same-directory parallelism *safe* (each session needs its own verification) but
not *correct* (agents still race on the git tree).

## Uninstall

- Remove the two hook entries from `<project>/.claude/settings.local.json`
  (the ones running `done-gate.sh` / `baseline-snapshot.sh`).
- Delete `<project>/.claude/scripts/done-gate.sh`,
  `<project>/.claude/scripts/baseline-snapshot.sh`,
  `<project>/.claude/skills/done/`, and `<project>/.claude/.harness/`.
- Optionally remove `.claude/done-config.json` and the `.gitignore` line.

## Portability

The bundle hardcodes no machine paths — it uses `$CLAUDE_PROJECT_DIR` (falling
back to `$PWD`). To use it on another machine: copy this bundle there and run
`install.sh` against any project. That's it.
