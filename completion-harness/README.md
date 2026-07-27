# Completion Harness

Makes Claude Code's Definition of Done a **structural forcing function**, not
advisory text. A Stop hook blocks the agent from declaring a task "done" until a
`/done` verification has actually passed for the current changeset.

## What it is

Three parts:

- **`scripts/done-gate.sh`** — a **Stop hook** (the gate). Fires on every turn
  exit; blocks unless a valid done-state exists for the session and matches live
  git state (HEAD == verified SHA, clean tree).
- **`skills/done/SKILL.md`** — the **`/done` skill** (the executor). Runs the
  checklist in order — config detect, tests (before/after checkpoint), app
  startup, changeset-scoped code review, task-specific checks — then writes the
  done-state that clears the gate.
- **`scripts/baseline-snapshot.sh`** — a **SessionStart hook**. Records the
  baseline HEAD SHA per session and optionally caches a background test snapshot
  keyed by SHA.

The two most error-prone `/done` steps are **scripted for determinism** (never
hand-written by the LLM): Step 0 config detection + fingerprinting
(`scripts/done-detect.sh`) and Step 7 done-state assembly with live-injected git
facts (`scripts/done-write-state.sh`, which refuses a dirty tree).

State lives under `<project>/.claude/.harness/` (git-ignored) and is keyed by
`session_id`, so parallel sessions in separate worktrees are fully isolated.

## Install

```bash
bash install.sh /path/to/project    # defaults to $PWD
```

This is idempotent. It:
- copies `scripts/`, `skills/done/`, and the base DoD artifact
  (`dod/base-dod.md` → `.claude/harness/base-dod.md`) into the project's
  `.claude/` — `/done` reads that base DoD and folds external instruction
  sources (`MY_RULES.md`, `CLAUDE.md`, the task) into one effective DoD per run,
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
`.claude/.harness/done-state/<session_id>.json`. The next turn exit sees a valid
done-state and lets the agent stop.

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
