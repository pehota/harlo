# ship

ship carries one WorkItem from a tracker to a verified production release.
A pure core moves each Delivery through fixed steps and gates. The Runner
around it loads and saves state and runs one executable adapter per port.

- Design: [`docs/architecture.md`](docs/architecture.md)
- Writing an adapter: [`docs/adapters.md`](docs/adapters.md)
- Terms: [`CONTEXT.md`](CONTEXT.md)
- Judging a step's real output (dev/debugging tool, not part of the shipped runtime): [`docs/judge.md`](docs/judge.md)

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
  map every stop outcome in `policy.outcomes`.

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
| `src/adapters/principal/index.ts` | principal | `[--out <file>]`, default `/dev/tty` |
| `src/adapters/fake.ts` | any | `--script <file>`. **Tests only.** |

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
  "workspace.setup":    { "status": "ok", "body": { "path": "/fake/ws/hello-1" } },
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
    "rolled_back": { "status": "reopened" }, "abandoned": { "comment": true } } } } }
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

For a real person at the terminal, set `"principal": ["bun", "<ship>/src/adapters/principal/index.ts"]`.
It prints each gate with its evidence and a paste-ready `ship signal …` line per option.
