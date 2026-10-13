---
status: accepted
---

# dod's own CLI is auto-approved by a PreToolUse hook

Teammates got a permission prompt every time a dod skill ran a Bash step.
The steps were compound commands touching a path outside their repo:
`. "${CLAUDE_PLUGIN_ROOT}/lib/x.sh"; fn …`. They also relied on shell
variables (`REPO`, `TASK_KEY`, `CONTRACT_*`, `STATE_*`) carried from one
block to the next, which never worked anyway: each Bash tool call is a
fresh shell.

Two obvious fixes don't exist:

- **A plugin cannot ship permission rules.** Only the user's or project's
  settings can allow a command.
- **A SKILL.md `allowed-tools` lasts one turn.** `/dod:define` spans
  several turns (it waits for the user's confirmation), so the approval is
  gone by the time the contract is written.

A plugin *can* ship a PreToolUse hook, and a PreToolUse hook can answer
`permissionDecision: "allow"`.

## Decision

- **One fixed command shape.** Every skill step is one Bash call:
  `bash "<plugin root>/scripts/dod.sh" <verb> [args]`. `dod.sh` resolves
  the repo and task key itself, computes the diff hash and round, and
  delegates to `lib/*.sh` (N6 is unchanged: it never parses an artefact
  itself). It never evals or executes its arguments.
- **`hooks/approve.sh` allows only that shape.** All of these must hold:
  - the tool is Bash;
  - the command is exactly `bash ` + this plugin's own `dod.sh` path. The
    path is resolved from the hook's own location and compared as an exact
    string (double-quoted, single-quoted or bare);
  - then a whitelisted verb;
  - then arguments the shell takes literally. Inside `'…'` anything goes.
    Inside `"…"` there is no `$`, backtick, `\` or newline. Outside quotes
    there is none of `` ; & | < > ( ) $ ` \ * ? [ ] { } ~ # `` and no
    newline or CR. Quotes are balanced.
- **Otherwise fall through.** The hook prints nothing and exits 0, and
  Claude Code's normal permission handling decides. It never denies,
  never blocks, and never fails on bad input.

## Considered Options

- **`allowed-tools` in the skills.** Rejected: one turn only, see above.
- **Ask every user to add a permission rule.** Rejected: it's the friction
  we're removing, and a rule like `Bash(bash *dod.sh*)` would also match
  chained commands.
- **Allow any command that mentions `dod.sh`.** Rejected: `bash dod.sh
  claim; rm -rf ~` would pass. Only a full-command grammar is safe.
- **Deny anything that looks like a dod command but isn't.** Rejected: a
  deny from a plugin would override the user's own allow rules. The hook
  only ever widens what runs without a prompt, for one exact shape.

## Consequences

- **Security surface.** The hook auto-runs one program, `dod.sh`, with
  literal arguments. The worst a crafted call can do is what `dod.sh` can
  do: write dod's own bookkeeping under `<repo root>/.dod/` (open or amend
  a contract, write a result, arm the latch). An agent could already do
  all of that with Write. The grammar is checked with one anchored regex
  (`\A…\z`), so a trailing newline can't slip through. A path that only
  resolves to `dod.sh` (via `../`, another copy, an env var) is not exact,
  so it falls through.
- **Fall-through is the failure mode.** If the hook is wrong, missing, or
  `jq` is absent, the user sees the prompt they saw before. Nothing blocks.
- **The skills changed mechanics, not behaviour.** Every step is a one-line
  CLI call with JSON in single quotes (a literal `'` in JSON is written
  as `\u0027`, JSON's escape for it). `contract-read` prints the contract, state and latest result
  as JSON, so nothing needs to be carried between calls. `contract-write`
  snapshots HEAD as the baseline itself, at write time.
- **Still prompts.** These keep the user's normal permission rules: the
  project's own check commands that `/dod:verify` runs (also inside the
  baseline worktree), and any dod call written outside the grammar.
  `/dod:define`'s preflight is `dod.sh brief-path`, which fails outside a
  git repo or without `jq`, so it does not prompt.
- **The skills rely on `${CLAUDE_PLUGIN_ROOT}` being expanded to the
  plugin's absolute path** in the command the agent runs. The hook does not
  accept a literal `${CLAUDE_PLUGIN_ROOT}`: it's a variable whose value the
  hook cannot see.
