# Completion Harness

Makes Claude Code's Definition of Done a **structural forcing function**, not
advisory text. A Stop hook blocks the agent from declaring a task "done" until a
`/done` verification has actually passed for the current changeset.

## What it is

Three parts:

- **`scripts/done-gate.sh`** — a **Stop hook** (the gate). Fires on every turn
  exit; blocks unless a valid done-state exists for the session and matches live
  git state (HEAD == verified SHA — or a HEAD whose **tree** is byte-identical to
  the verified one — plus no uncommitted work introduced this session).
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
facts — `verified_sha`, `head_tree`, `review_anchor_sha`, `base_sha`,
`tree_clean`, none of them agent-supplied (`scripts/done-write-state.sh`, which
refuses a dirty tree).

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

A HEAD move that leaves the tree byte-identical — rewording a commit, or a
`pull --rebase` that replays the same patches — **carries** the verification: no
re-review, no fresh `/done`. Any content change re-blocks: one byte in any tracked
file, a file mode flip, a symlink target, or a submodule pointer bump all produce
a different tree.

**Parallel work must use separate git worktrees** — the harness makes
same-directory parallelism *safe* (each session needs its own verification) but
not *correct* (agents still race on the git tree).

### Work on a branch — worktrees make it cheap

**Recommended working mode: a branch, ideally a worktree.**

On trunk there is no branch to key the changeset anchor on, so the harness falls
back to SESSION mode and keys it on a *file*, `baselines/<session-id>.sha`. That
file goes missing for ordinary reasons — the state dir was deleted, the baseline
was age-reaped, SessionStart never ran for this id, or the gate resolved a
different session id than `/done` wrote under. With no anchor the gate cannot
tell an empty changeset from a session of unverified commits, so it blocks; one
observed session hit **four false blocks** this way.

On a branch the harness runs in TASK mode: the anchor is `merge-base(trunk, HEAD)`,
keyed on the branch, pinned once, and derivable from git rather than remembered in
a file. It is not a cure-all — a branch does not help if the state directory is
deleted or the plugin is disabled — but it removes that whole class of false block.

Two scripts make the branch path the cheap one:

```
scripts/new-worktree.sh <branch-name> [path]     # provision
scripts/finish-worktree.sh [--skip-verify]       # integrate + tear down
```

`new-worktree.sh` fetches, cuts the branch from **`origin/<trunk>`** (never local
trunk, which may be unpushed or stale), symlinks the gitignored local config a
fresh checkout cannot have, and runs the detected install command. It refuses if
the branch or path already exists, never overwrites a file, and prints everything
it did *not* do — including gitignored files outside the allowlist, which you
promote yourself via `worktree.overrides.link` in `.claude/done-config.json`.

`finish-worktree.sh` runs **inside** the worktree and refuses unless the tree is
clean and `/done` left a green done-state that still describes HEAD (the gate's
own predicates, not a second implementation). Then it rebases onto
`origin/<trunk>`, fast-forwards trunk `--ff-only`, and removes the worktree. It
**never pushes** — it prints what would be pushed and stops. `--skip-verify`
bypasses the done-state gate only, and says so loudly.

What gets provisioned is **detected, not hardcoded** (`scripts/worktree-detect.sh`,
namespaced under the `worktree` key of `.claude/done-config.json`). `setup_cmd` is
deliberately never auto-detected into something runnable: candidates are reported
for you to promote, because running a `setup` target found by heuristic is how a
provisioning script drops a database.

### Headless execution — `run-task.sh`

```
scripts/run-task.sh "<task description>" [branch-name]
```

Kicks off an implementation task with `claude -p` and walks away, trusting the
harness to enforce the same Definition-of-Done it enforces interactively, then
leaving a full record of what happened. **Observability, not notification** —
there is no push alert; the record is `report.json` + `transcript.log` + an
append-only `index.jsonl`, all under the MAIN checkout's `.claude/.harness/`
(so they survive even if the worktree is later removed).

What it does, in order:

1. Provisions a worktree (`new-worktree.sh`, off `origin/<trunk>`) and pins
   its tree baseline (`baseline-snapshot.sh`, standalone).
2. Installs a **no-push guardrail**: a `git` shim placed first on `PATH` for
   the child `claude` process only. Every subcommand passes through to the
   real `git` except `push`, which is refused with a clear message. This —
   not a prompt instruction the model could ignore under pressure — is the
   actual safety boundary, together with worktree isolation.
3. Runs, from inside the worktree, with the shimmed `PATH`:
   `timeout <headless_timeout_minutes>m claude -p "<prompt>" --permission-mode
   bypassPermissions --max-turns <headless_max_turns>`. The prompt is the task
   text plus fixed instructions: the branch is already set up; run `/done`
   yourself before considering the work finished; never push or open a PR — a
   human reviews the branch afterward; if genuinely blocked, stop and explain.
   `bypassPermissions` is a deliberate, flagged tradeoff — without it, any
   tool-approval prompt hangs forever with nobody to answer it.
4. After the process exits, **verifies independently** — never trusts the
   model's own claim of completion. Reuses the Stop gate's own shared
   predicates (`hc_tree_status`, `hc_verification_state`,
   `hc_done_state_blocked`) to compute one verdict: `PASSED`, `BLOCKED` (a
   done-state exists but the gate's conditions are not met), `NO_STATE` (the
   model never ran `/done`), `TIMED_OUT`, or `ERROR`.
5. Writes the report and exits non-zero unless the verdict is `PASSED`, so
   scripting/CI around this can branch on exit code.

**Never merges, never pushes, never opens a PR.** The worktree and branch are
left in place for you to inspect and finish by hand — with `finish-worktree.sh`
above, or later PR automation, which is explicitly out of scope for this
iteration.

Config (`.claude/done-config.json`):

- `headless_max_turns` (default `60`) — the `--max-turns` bound.
- `headless_timeout_minutes` (default `45`) — the wrapping `timeout` bound.

Inspecting past runs:

```
jq . .claude/.harness/headless-tasks/<task-id>/report.json
jq -s 'sort_by(.timestamp)' .claude/.harness/headless-tasks/index.jsonl
jq 'select(.verdict != "PASSED")' .claude/.harness/headless-tasks/index.jsonl
```

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
