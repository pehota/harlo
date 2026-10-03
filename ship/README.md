# ship

ship carries one WorkItem from a tracker to a verified production release.
A pure core moves each Delivery through fixed steps and gates. The Runner
around it loads and saves state and runs one executable adapter per port.

- Design: [`docs/architecture.md`](docs/architecture.md)
- Writing an adapter: [`docs/adapters.md`](docs/adapters.md)
- Dogfood data layout, backup and recovery: [`docs/dogfood.md`](docs/dogfood.md)
- Terms: [`CONTEXT.md`](CONTEXT.md)
- Draining the tracker one Delivery at a time (environment loop around `ship next`): [`docs/queue.md`](docs/queue.md)
- Judging a step's real output (dev/debugging tool, not part of the shipped runtime): [`docs/judge.md`](docs/judge.md)
- Setting up ship in another repo (writes both config layers): [Set up ship in another repo](#set-up-ship-in-another-repo)

## Install

Needs [Bun](https://bun.sh) and bash.

```bash
cd ship
bun install
export PATH="$PWD/bin:$PATH"   # puts `ship` on PATH
bun run check                  # typecheck + tests
```

## Config

Two layers with disjoint keys. Each layer's schema rejects the other's keys.

| Layer | File | Holds |
|---|---|---|
| Project | `ship.config.json` in the working directory | `projectId`, `adapters` (argv per project port), `policy` |
| Machine | `$SHIP_MACHINE_CONFIG`, else `~/.config/ship/<projectId>.json` | `principal`, `state` (argv), `secrets`, `capabilities` |

- **Adapter argv** is a prefix. The Runner appends `<port> <op>`.
- **Project ports:** `tracker`, `workspace`, `define`, `implement`, `check`,
  `integrate`, `deploy`, `verify`. All eight are required.
- **Machine ports:** `principal`, `state`.
- **`policy`:** only `policy.tracker.outcomes` is required. It must give a
  `status` for `delivered` and `accepted_with_failure` (Close awaits it), and
  map every stop outcome in `policy.outcomes` with `"comment": true` (a stop's
  reason is kept as a tracker comment).

| `policy` key | Default |
|---|---|
| `fixRounds` | `2` |
| `retryCap` | `{ "default": 1 }`, per step or gate by name |
| `minimum` | `person` for every gate and Blocked; Decision: `scope` person, `advisory` model; `question` per `about`, unknown `about` → person |
| `outcomes` (stop outcomes) | `["rolled_back", "abandoned"]` |
| `tracker.steps` | `{}` — tracker status fired when a step is entered |

**Capability profile** (machine `capabilities.<port>`): `env` and `tools` for
the adapter serving that port. Any port, not only steps.

**Secrets fail fast.** Declare a secret in the machine layer, reference it from
a profile `env` value:

```jsonc
"secrets":      { "GH": { "env": "GH_TOKEN" } },
"capabilities": { "integrate": { "env": { "GH_TOKEN": "$secrets.GH" }, "tools": ["git", "gh"] } }
```

- An undeclared `$secrets.X` is a config error.
- A referenced secret whose env var is unset or empty is a config error.
- Every verb loads the whole config, so both give **exit 2 on every verb**,
  `status` included, before anything is touched.

**Adapters in this bundle:**

| Adapter | Port | Args |
|---|---|---|
| `src/adapters/state/files.ts` | state | `--dir <dir>` (`~` expanded) |
| `src/adapters/principal/tty.ts` | principal | none (always `/dev/tty`) |
| `src/adapters/fake.ts` | any | `--script <file>`. **Tests only.** |

## Set up ship in another repo

Run from anywhere inside the target git repo:

```bash
bun /abs/path/harlo/ship/env/setup.ts           # asks; [enter] accepts each default
bun /abs/path/harlo/ship/env/setup.ts --yes     # every default, no prompts
```

**It asks**, each as a numbered list with the default marked:

| Prompt | Default |
|---|---|
| Project id | the repo's directory name |
| Tracker | `github` if `origin` is on GitHub, else `md`; or own path |
| GitHub: repo, project number, project owner, ready status, status labels | `origin`'s `owner/name`; no project (label mode); repo owner; `Todo` (project) / `ready` (labels); `In Progress,Done` (project options) / `in_progress,done` (labels) |
| md: tracker dir | `~/.local/state/ship/<projectId>/tracker` (created) |
| Workspace, Define, Implement, Check, Integrate, Deploy, Verify, Principal, State | the one fully implemented adapter; or own path |
| Main line | the current branch; or an existing local branch; or a new one (created from HEAD) |
| Push `<branch>` to `<remote>` with upstream? `[y/N]` | no. Only for a new Main line on a repo with a remote (`origin`, else the first), and only in a run that already asked something |
| Worktrees root | `<git root>/.ship/worktrees` (hidden: `bun test` skips it; a non-hidden root inside the repo gets a warning) |
| State dir | `~/.local/state/ship/<projectId>/state` (created) |

Only adapters that implement every op of their port are listed (Jira is not, yet).
"Own path" takes an argv, split on whitespace.

**It writes**:

- `<git root>/ship.config.json`: all eight project ports, Integrate `--root` = where the Main line is checked out
  (see below), and a policy that moves a picked item to in progress (`In Progress` / `in_progress`), done on delivery, a comment on every stop.
- `~/.config/ship/<projectId>.json`: tty Principal, file State, `USER` for the Claude steps.
- `.ship/` as a line in the repo's `info/exclude` (once).

It refuses to overwrite either file without `--force` (exit 1, nothing written), then loads both
with `ship status` (exit 2 if ship rejects them).

| Flag | Sets |
|---|---|
| `--yes` | the default for every value not given as a flag |
| `--force` | overwrite existing config files |
| `--push-main` | push a new Main line: `git push -u <remote> <branch>` (never pushed without it under `--yes` or with every value given) |
| `--project-id <id>` | Project id |
| `--tracker github\|md\|path:<argv>` | Tracker |
| `--repo`, `--project`, `--project-owner`, `--ready-label`, `--status-labels` | the GitHub tracker's flags of the same name. `--status-labels`: at least two; the first is the policy's in-progress status, the last its done status (project mode: the Status field's options, not passed to the adapter) |
| `--tracker-dir <dir>` | md tracker dir |
| `--main current\|<existing>\|new:<name>` | Main line (workspace `--main`). Never asks: anything else (`new` without `:<name>`, a menu word) is a usage error (exit 1, nothing written) saying to use `new:<name>`. A local branch named like a menu word (e.g. `new`) is picked by its name |
| `--worktrees <dir>` | Worktrees root (workspace `--root`) |
| `--state-dir <dir>` | State dir |
| `--<port> <adapter>\|path:<argv>` | any other port, e.g. `--define 'path:my-agent --fast'` |
| `--help` | usage |

A value given as a flag is never asked. A flag the chosen adapters do not use (another tracker's; `--main`,
`--worktrees` with an own-path workspace; `--state-dir` with an own-path state) is ignored, all of them named in one
`warning:` line on stderr.

A new Main line not pushed (declined, `--yes` without `--push-main`, or the push failed) gets the exact
`git push -u <remote> <branch>` on stderr: Integrate's push fails until it is run. A failed push is not fatal:
the configs are written and the exit code is unchanged.

Last, it prints the queue command to run from the git root:

```bash
bun <ship>/env/queue.ts --ship <ship>/bin/ship --interval 30000 --state bun <ship>/src/adapters/state/files.ts --dir <state dir>
```

The tty Principal reads `/dev/tty`: run the queue in a real terminal.

**Where Integrate lands.** It merges into the branch checked out at its `--root`, so setup points `--root` at the Main line:

| Main line is | Integrate `--root` |
|---|---|
| the branch checked out at the git root | the git root |
| checked out in another worktree | that worktree |
| neither | a new worktree `<git root>/.ship/main-line` (`git worktree add`), reused on a rerun |

## CLI

| Verb | Does |
|---|---|
| `ship start <key>` | Reads the WorkItem, then creates Delivery `<key>-<attempt>`. Rejected while the key has an open Delivery. |
| `ship next` | Asks the tracker for the next key (`null` → nothing to do), then as `start`. |
| `ship signal <delivery> <id> <result-json>` | Delivers a Result for command `<id>`. An id not awaited is ignored and journaled. |
| `ship stop <delivery> <outcome> <reason>` | Abandons the Delivery. `<outcome>` must be in `policy.outcomes`. |
| `ship changed <delivery>` | Re-reads the WorkItem from the tracker and applies the change. |
| `ship status [<delivery>]` | Read-only. No argument: every open Delivery. With one: that Delivery, even if Closed or Abandoned. |

**Output:** one JSON line on stdout.

```jsonc
// start, next, signal, stop, changed
{"delivery":"hello-1","issued":["hello-1/land-1"],"awaiting":"hello-1/land-1"}
// optional keys: "ignored":true, "rejected":true (+ "reason":"…"), "unapplied":[…] (exit 3), "errors":[{"id","info"}] (failed fires)
// status
{"deliveries":[{"delivery":"hello-1","at":"land","awaiting":"hello-1/land-1"}]}
```

`delivery` is `null` only when there is none yet (`next` with no key, a `start` that never saved). `at` is the Delivery's Position. `awaiting` is the awaited command id, or `null`.

| Exit | Meaning |
|---|---|
| 0 | applied, ignored or rejected |
| 1 | invalid CLI input; usage on stderr |
| 2 | config error; nothing touched |
| 3 | State save conflict did not clear after 5 tries; `unapplied` lists the signals to resubmit |
| 4 | State or Tracker call failed; if it failed before execution nothing ran, otherwise see the journal |
| 5 | an awaited adapter crashed or printed invalid output; journaled, remaining commands still ran |

## Happy path on fakes

Every port is the scripted fake except State (real files). The Principal is the
fake too: it prints `accepted`, and you answer each gate with `ship signal`, as
a person would. Run from the `ship/` directory:

```bash readme-happy-path
ship_root=$PWD
export PATH="$ship_root/bin:$PATH"
demo=$(mktemp -d "${TMPDIR:-/tmp}/ship-demo.XXXXXX")
cd "$demo"

# What the fake adapter answers, per <port>.<op>. Unscripted (principal.*) → accepted.
cat > script.json <<'EOF'
{ "replies": {
  "tracker.read":       { "status": "ok", "body": { "workItem": { "key": "hello", "title": "Greet by name", "body": "Say hello." } } },
  "tracker.update":     { "status": "ok", "body": {} },
  "workspace.setup":    { "status": "ok", "body": { "path": "/fake/ws/hello-1", "base": "main" } },
  "workspace.teardown": { "status": "ok", "body": {} },
  "define.run":         { "status": "ok", "body": { "criteria": ["greets Ada by name"], "runbook": ["run greet Ada"] } },
  "implement.run":      { "status": "ok", "body": { "changeset": "c1" } },
  "check.run":          { "status": "ok", "body": { "verdict": "pass" } },
  "integrate.run":      { "status": "ok", "body": { "verdict": "landed" } },
  "deploy.run":         { "status": "ok", "body": { "verdict": "live" } },
  "verify.run":         { "status": "ok", "body": { "verdict": "pass" } }
} }
EOF

fake='["bun", "'"$ship_root"'/src/adapters/fake.ts", "--script", "'"$demo"'/script.json"]'
cat > ship.config.json <<EOF
{ "projectId": "demo",
  "adapters": { "tracker": $fake, "workspace": $fake, "define": $fake, "implement": $fake,
                "check": $fake, "integrate": $fake, "deploy": $fake, "verify": $fake },
  "policy": { "tracker": { "outcomes": {
    "delivered": { "status": "done" }, "accepted_with_failure": { "status": "done" },
    "rolled_back": { "status": "reopened", "comment": true }, "abandoned": { "comment": true } } } } }
EOF
cat > machine.json <<EOF
{ "principal": $fake,
  "state": ["bun", "$ship_root/src/adapters/state/files.ts", "--dir", "$demo/state"] }
EOF
export SHIP_MACHINE_CONFIG="$demo/machine.json"

ship start hello
# → Setup, Define, then the Accept gate awaits: "awaiting":"hello-1/accept-1"
ship signal hello-1 hello-1/accept-1 '{"status":"ok","body":{"answer":"accept","by":"person"}}'
# → Implement, Check, then the Land gate awaits: "awaiting":"hello-1/land-1"
ship signal hello-1 hello-1/land-1 '{"status":"ok","body":{"answer":"approve","by":"person"}}'
# → Integrate, Deploy, Verify, Close, Teardown: "awaiting":null
ship status hello-1
# → {"deliveries":[{"delivery":"hello-1","at":"closed","awaiting":null}]}
```

For a real person at the terminal, set `"principal": ["bun", "<ship>/src/adapters/principal/tty.ts"]`.
It prints each gate with its evidence and a plain option list, then blocks on `/dev/tty` for the reply —
answered right there, in the same `ship` invocation, no `ship signal` needed.
