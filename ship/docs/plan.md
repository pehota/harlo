# ship — implementation plan (v1)

Status: plan, frozen for M0 on 2026-09-28; further findings go to the implementing session. Sources of truth: [`architecture.md`](architecture.md), [`../CONTEXT.md`](../CONTEXT.md), [`adr/`](adr/). Where this plan disagrees with them, they win. Each architecture amendment this plan made is marked **[amend, synced]**: the user accepted it on 2026-09-28 and it is synced into `architecture.md`. §8.1 lists them.

Legend:
- **[verified]**: checked on this machine on 2026-09-28.
- **[unverified]**: believed but not checked.
- **[amend, synced]**: an architecture amendment, accepted on 2026-09-28 and already synced into `architecture.md`.

---

## 1. Goal and scope

**Goal.** Build ship as a Bun + TypeScript bundle at `harlo/ship`. It carries one WorkItem from a tracker to a verified production release. A pure core drives it, and executable adapters sit behind ports.

### In scope (v1)
- **Pure core.** Two functions:
  - `start(policy, workItem, existing) → created | rejected`
  - `transition(policy, snapshot, signal) → {state, commands, entry}`

  They cover every row of §4: the 9 steps, the 4 gates, Blocked, Closed and Abandoned.
- **Runner.** It loads, applies, saves and then executes. It does CAS on save, loops on immediate results, and validates every boundary with ajv.
- **CLI.** Verbs `start`, `next`, `signal`, `stop` and `changed`, plus the read-only `status` **[amend, synced]**.
- **Config.** Project layer plus machine layer, validated with ajv. Secrets are resolved into each port's capability profile env.
- **Adapters.** File State, terminal Principal, and fakes for tests (M0). Then real adapters for both setups (M1–M3).

**Setups:**

| Setup | Tracker | Principal | Workspace | Integrate | Deploy | Verify | Define / Implement / Check |
|---|---|---|---|---|---|---|---|
| **Home** | md files (later GitHub issues) | terminal, then Telegram | git worktree | local merge | ask-principal (manual) | ask-principal (manual) | coding-agent adapter (Claude Code) |
| **Work** | Jira | terminal (Telegram if allowed) | git worktree | PR + auto-merge | GitHub Actions | e2e agent (fresh session) | coding-agent adapter (Claude Code) |

### Out of scope (v1)
- **Model Principal.** The type allows `by: "model"` and config can route to a model, but no model Principal adapter is built.
- **`accepted` mode for agent steps.** Agent adapters are sync in v1.
- **Principal asks back at a gate.** Per architecture: the adapter handles it, or the Principal answers "adjust" with a comment.
- **Anything done by the environment:**
  - listeners, bots and webhooks
  - reminders, expiry and timeouts
  - crash recovery and rollback
  - scheduling `next` and running several Deliveries in parallel

  ship ships no daemon.
- **Rollback after Close.** Signals on Closed are ignored.
- **Repo mode for the md tracker** (committing the task file to the main line). External-path mode only.
- **Emitted `.json` schema files, a linter beyond `tsc --noEmit`, a DB State adapter, journal replay.**

---

## 2. Module layout

```
ship/
  package.json              # bun, ajv, typescript; dev: fast-check; scripts: test, typecheck, check
  tsconfig.json             # strict, noEmit
  bin/ship                  # #!/usr/bin/env bun → src/cli.ts
  src/
    core/                   # pure: no I/O, no clock, no tool names (P5, P7)
      types.ts              # Step, Gate, Node, Position, Snapshot, Signal, Command, Entry, Policy
      ids.ts                # deliveryId, commandId, nextId(seq, name)
      start.ts              # start()
      transition.ts         # transition(): dispatch by position (Snapshot.at)
      gates.ts              # gate options, decide/ask command builders, evidence bundle
      steps.ts              # step → port/op/payload builders, tracker status fire
      start.test.ts         # table-driven
      transition.test.ts    # table-driven (§4)
      invariants.test.ts    # sweep of all rows: invariants I1–I6
    contracts/              # ajv schemas + TS types, single source (JSONSchemaType<T>)
      common.ts             # Result, Stdout, EvidenceItem, GateEvidence, Finding, WorkItem, Stdin envelope
      ports.ts              # registry: port → op → {payload, body} schemas
      snapshot.ts           # Snapshot schema (validated on load)
      config.ts             # project + machine config schemas
      contracts.test.ts
    runner/
      config.ts             # load layers, validate, resolve $secrets, build Policy
      spawn.ts              # run an adapter: argv, stdin, env, parse stdout, map exit
      state.ts              # State port client (load/save/list/journal via spawn)
      apply.ts              # the load → core → save → execute loop, CAS retry
      *.test.ts
    cli.ts                  # verbs, exit codes, one JSON line out
  adapters/                 # one executable per adapter; each takes <port> <op>
    state-files.ts          # M0
    principal-terminal.ts   # M0
    fake.ts                 # M0, tests only: scripted by a fixture file
    workspace-worktree.ts   # M1
    tracker-md.ts           # M1
    integrate-local.ts      # M1
    ask-principal.ts        # M1 (serves deploy + verify)
    agent-claude.ts         # M1 (serves define, implement, check; later verify)
    principal-telegram.ts   # M2
    tracker-github.ts       # M2
    tracker-jira.ts         # M3
    integrate-pr.ts         # M3
    deploy-gha.ts           # M3
    *.test.ts
  env/                      # reference environment scripts, not part of the core or Runner
    telegram-listener.ts    # M2
    poll-changed.sh         # M1: cron-able WorkItem change poller
    poll-stalled.sh         # M1: cron-able check for awaited commands never sent, orphaned by a dead Runner, or hung
    watch-pr.ts             # M3
    watch-deploy.ts         # M3
  test/
    e2e/lifecycle.test.ts   # CLI + Runner + fakes, full lifecycle scenarios
    e2e/readme.test.ts      # runs the README happy path against fakes (M0.23)
    property/lifecycle.property.test.ts  # fast-check: core + Runner in a simulated environment (M0.22)
    fixtures/               # fake scripts, configs
  docs/
    architecture.md  adr/  plan.md  adapters.md (M0: adapter authoring contract)
  README.md                 # M0: install, config, CLI
```

Tool names such as `claude` and `jira` appear only in `adapters/` and `env/`. `invariants.test.ts` also scans `src/core` and fails on any tool name (see M0.13).

---

## 3. Key types

### 3.1 Common shapes (`src/contracts/common.ts`)

```ts
type DeliveryId = string;          // "<key>-<attempt>", e.g. "PROJ-123-2"
type CommandId  = string;          // "<delivery>/<name>-<n>", e.g. "PROJ-123-2/land-1"
type PrincipalKind = "person" | "model";

type WorkItem = { key: string; title: string; body: string; url?: string };  // key: /^[A-Za-z0-9][A-Za-z0-9._-]*$/
type Finding  = { text: string; ref?: string };
type EvidenceItem = { label: string; text?: string; url?: string };            // P9: opaque, never read

type Result<Body = unknown> =
  | { status: "ok"; body: Body; evidence?: EvidenceItem[] }
  | { status: "failed"; info: string }                                        // could not run, changed nothing
  | { status: "question"; prompt: string; about: string;                      // step ports only; about: adapter-defined category [amend, synced]
      options?: string[]; evidence?: EvidenceItem[] };
type Stdout<Body = unknown> = Result<Body> | { status: "accepted" };

// what every adapter reads on stdin (argv: <exe...> <port> <op>)
type Stdin = {
  id: CommandId; delivery: DeliveryId; port: Port; op: string;
  workItem: WorkItem; workspace: string | null;
  payload: unknown; tools: string[];          // capability profile tools; secrets go in env only
};
```

### 3.2 Ports and ops (`src/contracts/ports.ts`)

`Port = "define"|"implement"|"check"|"integrate"|"deploy"|"verify"|"tracker"|"principal"|"workspace"|"state"`

Every adapter must also accept op `cancel` with payload `{target: CommandId}`. It exits 0 when there is nothing to cancel. The core sends `cancel` to the port of the target command (row `<port of target>.cancel` below).

**Step ports (op `run`):**

| Port | payload | `ok` body |
|---|---|---|
| define | `{ feedback?: string; answer?: string }` | `{ criteria: string[]; runbook: string[] }` |
| implement | `{ criteria; findings: Finding[]; feedback?; answer? }` | `{ changeset: string }` (opaque ref) |
| check | `{ criteria; changeset; answer? }` | `{verdict:"pass"}` \| `{verdict:"fix"; findings}` \| `{verdict:"decide"; about:"scope"\|"advisory"; findings}` |
| integrate | `{ changeset; answer? }` | `{verdict:"landed"}` \| `{verdict:"fix"; findings}` (a conflict is `question{about:"conflict"}`) |
| deploy | `{ changeset; answer? }` | `{verdict:"live"}` \| `{verdict:"not_live"; findings?}` |
| verify | `{ runbook; answer? }` | `{verdict:"pass"}` \| `{verdict:"fail"; findings}` |

**Service ports:**

| Port.op | Awaited? | payload | `ok` body |
|---|---|---|---|
| workspace.setup | yes | `{}` | `{ path: string }` |
| workspace.teardown | yes | `{ path }` | `{}` |
| tracker.update | yes at Close, fire elsewhere | `{ status: string }` (opaque, from config) | `{}` |
| tracker.comment | fire | `{ text }` | `{}` |
| principal.decide | yes | `Decide` | `{ answer: string; comment?: string; by: PrincipalKind }` |
| principal.ask | yes | `{ prompt; min: PrincipalKind; options?: string[]; evidence: GateEvidence }` | `{ answer: string; by: PrincipalKind }` |
| principal.notify | fire | `{ text; evidence?: GateEvidence }` | `{}` |
| `<port of target>.cancel` | fire | `{ target: CommandId }` | `{}` |

**Runner-only calls.** The core never issues these. They must return a result, never `accepted`.

| Port.op | payload | `ok` body |
|---|---|---|
| tracker.read | `{ key }` | `{ workItem: WorkItem }` |
| tracker.next **[amend, synced]** | `{}` | `{ key: string \| null }` |
| state.load | `{ delivery }` | `{ version: number; state: Snapshot } \| { version: 0; state: null }` |
| state.save | `{ delivery; version; state; entries: Entry[] }` | `{ saved: true } \| { conflict: true }` |
| state.list **[amend, synced]** | `{ key? }` | `{ deliveries: DeliveryId[] }` (no key = all) |
| state.journal | `{ delivery }` | `{ entries: Entry[] }` (read, audit only) |

```ts
type DecidePoint = "accept" | "decision" | "land" | "failure" | "blocked";  // blocked is a state, not a Gate
type GateEvidence = {
  workItem: WorkItem; criteria: string[] | null; runbook: string[] | null;
  changeset: string | null; findings: Finding[]; evidence: EvidenceItem[]; note?: string;
};
type Decide = { on: DecidePoint; options: string[]; min: PrincipalKind; evidence: GateEvidence };
```

**Gate options.** These are core constants, not config. The core branches on them.

| Point | Options |
|---|---|
| accept | `accept`, `adjust` |
| decision | `keep_going`, `accept`, `stop` |
| land | `approve`, `rework`, `rescope` |
| failure | `fix_forward`, `accept` |
| blocked | `retry`, `stop` |
| integrate conflict (`ask`) | `resolved`, `rework` (forced by the core) |

### 3.3 Core types (`src/core/types.ts`)

The core imports only its types from `contracts/`. It never imports ajv.

```ts
type Step = "setup"|"define"|"implement"|"check"|"integrate"|"deploy"|"verify"|"close"|"teardown";
type Gate = "accept"|"decision"|"land"|"failure";
type Node = Step | Gate;                                     // names are disjoint
type Position = Node | "blocked" | "closed" | "abandoned";  // where the Delivery is now
type Outcome = string;   // core derives "delivered" | "accepted_with_failure"; others come from stop, validated against policy.outcomes

type Command = {
  id: CommandId; port: Port; op: string; await: boolean; payload: unknown;
};
type Awaiting = Command & {
  node: Node | "blocked";                     // step/gate this command belongs to
  kind: "run" | "decide" | "ask";
  options?: string[];                          // decide + ask with options: the allowed answers
  about?: string;                              // ask: from the question
};

type Snapshot = {
  v: 1;
  delivery: DeliveryId;
  workItem: WorkItem;
  at: Position;
  blockedAt: Node | null;                      // set iff at = "blocked"
  awaiting: Awaiting | null;                   // invariant: at most one awaited command
  lastRun: Awaiting | null;                    // last step command issued; re-issued with the answer (Q3)
  blockedCmd: Awaiting | null;                 // the failed command; re-issued on Blocked → retry (B3)
  seq: Record<string, number>;                 // per id name, never reset
  retries: number;                             // consecutive `failed` on the current node
  fixRounds: number;
  workspace: string | null;
  criteria: string[] | null; runbook: string[] | null; changeset: string | null;
  findings: Finding[];                         // latest verdict's findings
  evidence: EvidenceItem[];                    // appended, never read (P9)
  outcome: Outcome | null; reason: string | null;
};

type Signal =
  | { kind: "result"; id: CommandId; result: Result }
  | { kind: "stop"; outcome: Outcome; reason: string }
  | { kind: "workItem_changed"; workItem: WorkItem };

type Note = "ignored_stale" | "ignored_terminal" | "invalid_answer" | "rejected_start"
          | "workitem_changed_late" | "workitem_unchanged";
type Entry = {                                 // Runner adds `time` (core has no clock)
  delivery: DeliveryId;
  signal: Signal
    | { kind: "start"; workItem: WorkItem }
    // Runner-written entries (never produced by the core): from = to = Snapshot.at, issued = []
    | { kind: "sent"; id: CommandId; pid: number; host: string;  // once the adapter process has started, before its exit
        started: string }                      // the process start time, read right after spawn (pid-reuse guard)
    | { kind: "accepted"; id: CommandId }      // the adapter printed `accepted`
    | { kind: "adapter_error"; id: CommandId };// crash or invalid stdout; `info` = stderr tail
  from: Position | null; to: Position; issued: CommandId[];
  by?: PrincipalKind;                          // on Principal answers (ADR 0005)
  note?: Note; info?: string;
};

type Policy = {
  fixRounds: number;                                            // default 2
  retryCap: { default: number } & Partial<Record<Node, number>>;
  minimum: {
    accept: PrincipalKind; land: PrincipalKind; failure: PrincipalKind; blocked: PrincipalKind;
    decision: { scope: PrincipalKind; advisory: PrincipalKind };
    question: Record<string, PrincipalKind>;                    // by question.about; unknown → "person"
  };
  outcomes: Outcome[];                                          // stop outcomes; default ["rolled_back","abandoned"]
  tracker: {
    steps: Partial<Record<Step, string>>;                       // status set when a step is entered
    outcomes: Record<Outcome, { status?: string; comment?: boolean }>;
  };
};

// entry points
start(p: Policy, w: WorkItem, existing: Snapshot[]):
  | { kind: "created"; state: Snapshot; commands: Command[]; entry: Entry }
  | { kind: "rejected"; delivery: DeliveryId; entry: Entry };   // entry journaled on the existing Delivery
transition(p: Policy, s: Snapshot, sig: Signal): { state: Snapshot; commands: Command[]; entry: Entry };
```

**Core invariants.** `invariants.test.ts` asserts these over every row:
- **I1.** At most one command with `await: true` per output. `state.awaiting` equals it, or is `null` when there is none.
- **I2.** Every issued id is `<delivery>/<name>-<n>` and unique. `seq[name]` only grows.
- **I3.** `cancel` is issued only for the previous `awaiting.id`, and always before the new commands.
- **I4.** Closed and Abandoned outputs issue no awaited command. Abandoned never issues `workspace.teardown`.
- **I5.** Ignored signals return the input state unchanged (deep-equal).
- **I6.** Every entry that applies a `principal.decide` or `principal.ask` Result carries `by`.

### 3.4 State on disk (file adapter)

```
<dir>/<delivery>/<version>.json   = { state: Snapshot, entries: (Entry & {time: string})[] }
```
- Save writes a tmp file, then `link(tmp, <version>.json)`. `EEXIST` means conflict. This is CAS, and the snapshot and its journal entries land in one atomic step. **[verified]** `linkSync` throws `EEXIST` under Bun 1.4.2 on macOS; Linux is **[unverified]**.
- Load reads the highest version. The journal is every `entries` array, concatenated in version order. It is append-only (ADR 0005).

### 3.5 Config

```jsonc
// project: <repo>/ship.config.json
{
  "projectId": "harlo",
  "adapters": {                          // argv prefix; Runner appends <port> <op>
    "tracker":  ["bun", "adapters/tracker-md.ts", "--dir", "~/notes/harlo"],
    "workspace":["bun", "adapters/workspace-worktree.ts", "--main", "main"],
    "define":   ["bun", "adapters/agent-claude.ts"], "implement": ["..."], "check": ["..."],
    "integrate":["..."], "deploy": ["..."], "verify": ["..."]
  },
  "policy": {
    "fixRounds": 2,
    "retryCap": { "default": 1, "deploy": 0 },
    "minimum": { "accept": "person", "land": "person", "failure": "person", "blocked": "person",
                 "decision": { "scope": "person", "advisory": "model" },
                 "question": { "clarify": "model", "login": "person", "conflict": "person", "manual": "person" } },
    "outcomes": ["rolled_back", "abandoned"],
    "tracker": { "steps": { "implement": "in_progress" },
                 "outcomes": { "delivered": { "status": "done" },
                               "accepted_with_failure": { "status": "done", "comment": true },
                               "rolled_back": { "status": "reopened", "comment": true },
                               "abandoned": { "comment": true } } }
  }
}
// machine: $SHIP_MACHINE_CONFIG or ~/.config/ship/<projectId>.json
{
  "principal": ["bun", "adapters/principal-terminal.ts"],
  "state":     ["bun", "adapters/state-files.ts", "--dir", "~/.local/state/ship/harlo"],
  "secrets":   { "GH": { "env": "GH_TOKEN" } },
  "capabilities": { "integrate": { "env": { "GH_TOKEN": "$secrets.GH" }, "tools": ["git", "gh"] } }
}
```

**Validation rules:**
- The two layers have disjoint keys. Each schema rejects the other layer's keys.
- An undeclared `$secrets.X` is a config error.
- `policy.tracker.outcomes` must give a `status` for `delivered` and `accepted_with_failure`, because Close awaits it.
- Every entry in `policy.outcomes` must have a `policy.tracker.outcomes` mapping.

---

## 4. Core transition table

These rows are the test cases. Row shape: `state | signal | → position | commands | snapshot / entry`. The `state` and `→` columns name `Snapshot.at`.

Notation:
- `C` = `retryCap[node] ?? retryCap.default`.
- `N` = `policy.fixRounds`.
- `run X` = an awaited step command `X-n`, plus a fire `tracker.update{status}` when `tracker.steps[X]` is set. Entering a step or gate resets `retries = 0`.
- `decide G` = awaited `principal.decide` with the options from §3.2, `min` from policy, and the evidence bundle.
- `abandon(o, r)` = position `abandoned`, set `outcome` and `reason`. Fire `tracker.update` if `outcomes[o].status` is set. Fire `tracker.comment{text:"<o>: <r>"}` if `comment` is set. Fire `principal.notify`. No Teardown: the workspace is kept.
- A **result** row applies only when `signal.id === awaiting.id`. R1 covers every other case.

### 4.1 `start` (`start.test.ts`)

| # | existing Deliveries for key | → | commands | entry |
|---|---|---|---|---|
| S1 | none | created `k-1`, at `setup` | `workspace.setup k-1/setup-1` (await) | from null, to setup |
| S2 | `k-1` closed | created `k-2` | `setup-1` | |
| S3 | `k-1` abandoned, `k-2` closed | created `k-3` | `setup-1` | |
| S4 | `k-1` at `implement` | rejected on `k-1` | none | `rejected_start` |
| S5 | `k-1` blocked | rejected on `k-1` | none | `rejected_start` |
| S6 | snapshots for another key sharing a prefix (`k-12-1` for key `k-1`) | not counted | | Runner filters `state.workItem.key === key` |

### 4.2 Happy path

| # | state | signal | → | commands | snapshot / entry |
|---|---|---|---|---|---|
| H1 | setup | ok `{path}` | define | run define `{}` | workspace = path |
| H2 | define | ok `{criteria, runbook}` + evidence | accept | decide accept | criteria, runbook set; evidence appended |
| H3 | accept | answer `accept` | implement | run implement `{criteria, findings: []}` | entry.by |
| H3a | accept, policy `tracker.steps.implement = "in_progress"` | answer `accept` | implement | run implement, plus fire `tracker.update{status: "in_progress"}` | entry.by |
| H3b | accept, no `tracker.steps.implement` | answer `accept` | implement | run implement only; no `tracker.update` issued | entry.by |
| H4 | accept | answer `adjust` + comment | define | run define `{feedback: comment}` | |
| H5 | implement | ok `{changeset}` | check | run check `{criteria, changeset}` | changeset set |
| H6 | check | ok `{verdict: pass}` | land | decide land | findings = [] |
| H7 | land | answer `approve` | integrate | run integrate `{changeset}` | |
| H8 | integrate | ok `{verdict: landed}` | deploy | run deploy `{changeset}` | |
| H9 | deploy | ok `{verdict: live}` | verify | run verify `{runbook}` | |
| H10 | verify | ok `{verdict: pass}` | close | awaited `tracker.update close-n {status: outcomes.delivered.status}`; fire `tracker.comment` if configured | outcome = `delivered` |
| H11 | close | ok `{}` | teardown | run teardown `{path: workspace}` | |
| H12 | teardown | ok `{}` | closed | fire `principal.notify{text: "closed: <outcome>"}` | awaiting = null |

### 4.3 Fix rounds and the Decision gate

| # | state | signal | → | commands | snapshot / entry |
|---|---|---|---|---|---|
| F1 | check, fixRounds < N | ok `{fix, findings}` | implement | run implement `{criteria, findings}` | fixRounds+1, findings set |
| F2 | check, fixRounds = N | ok `{fix, findings}` | decision | decide decision, min = `decision.scope` | findings set |
| F3 | check | ok `{decide, about, findings}` | decision | decide decision, min = `decision[about]` | |
| F4 | decision | `keep_going` | implement | run implement `{criteria, findings}` | fixRounds = 0 |
| F5 | decision | `accept` | land | decide land | |
| F6 | decision | `stop` [+ comment] | abandoned | abandon(`abandoned`, comment ?? "stopped at decision") | no cancel (answer consumed) |
| F7 | land | `rework` [+ comment] | implement | run implement `{criteria, findings, feedback}` | fixRounds unchanged |
| F8 | land | `rescope` [+ comment] | define | run define `{feedback}` | fixRounds unchanged |
| F9 | integrate, fixRounds < N | ok `{fix, findings}` | implement | run implement | fixRounds+1 |
| F10 | integrate, fixRounds = N | ok `{fix, findings}` | decision | decide decision, min = `decision.scope` | |

### 4.4 Failure gate

| # | state | signal | → | commands | snapshot / entry |
|---|---|---|---|---|---|
| X1 | deploy | ok `{not_live, findings?}` | failure | decide failure | findings set |
| X2 | verify | ok `{fail, findings}` | failure | decide failure | findings set |
| X3 | failure | `fix_forward` | implement | run implement `{criteria, findings}` | fixRounds unchanged |
| X4 | failure | `accept` | close | awaited `tracker.update {status: outcomes.accepted_with_failure.status}` (+ fire comment) | outcome = `accepted_with_failure` |

### 4.5 Questions (step ports only)

| # | state | signal | → | commands | snapshot / entry |
|---|---|---|---|---|---|
| Q1 | step S ∈ {define … verify} | question `{prompt, about, options?}` | S | awaited `principal.ask <d>/ask-n {prompt, min: question[about] ?? person, options?, evidence}` | awaiting.kind = ask, node = S; lastRun = the step's awaited command |
| Q2 | integrate | question `{about: conflict}` | integrate | ask with options forced to `[resolved, rework]` | |
| Q3 | S, awaiting ask (no options, or answer ∈ options) | answer a | S | re-issue lastRun of S with `payload.answer = a`, new id | retries = 0 |
| Q4 | integrate, awaiting conflict ask | `resolved` | integrate | re-issue integrate `{changeset, answer: "resolved"}` | |
| Q5 | integrate, awaiting conflict ask | `rework` | implement | run implement `{criteria, findings}` | fixRounds unchanged |
| Q6 | awaiting ask with options | answer ∉ options | same | re-issue ask, new id | `invalid_answer` |

### 4.6 Retries and Blocked

| # | state | signal | → | commands | snapshot / entry |
|---|---|---|---|---|---|
| B1 | node (step, gate or ask), retries < C | failed | same | re-issue the awaited command, new id | retries+1 |
| B2 | node, retries = C | failed | blocked | decide blocked `[retry, stop]`, min blocked | blockedAt = node; blockedCmd = the failed command (lastRun kept) |
| B3 | blocked | `retry` | blockedAt | re-issue blockedCmd, new id | retries = 0; blockedAt = null; blockedCmd = null |
| B4 | blocked | `stop` [+ comment] | abandoned | abandon(`abandoned`, comment ?? "stopped at blocked <node>") | |
| B5 | blocked | answer ∉ options | blocked | re-issue decide blocked, new id | `invalid_answer` |
| B6 | blocked, awaiting decide | failed | blocked | none | awaiting = null (the environment alerts) |
| B7 | gate | answer ∉ options | same | re-issue decide, new id | `invalid_answer`; retries unchanged |

Notes:
- The ask in B1 and B2 uses the cap of the asking step.
- An invalid answer (B5, B7) is an answer, not a failure. It does not count toward `C` (ADR 0004).

### 4.7 Delivery signals

| # | state | signal | → | commands | snapshot / entry |
|---|---|---|---|---|---|
| D1 | non-terminal, awaiting X | stop `{o, r}` | abandoned | `cancel{target: X}` then abandon(o, r) | Workspace kept |
| D2 | non-terminal, awaiting null (after B6) | stop `{o, r}` | abandoned | abandon(o, r) | |
| D3 | close or teardown (outcome already set) | stop `{o, r}` | abandoned | cancel + abandon(o, r) | outcome overwritten by o (stop wins) |
| W1 | any non-terminal | `workItem_changed` with title and body equal to the snapshot's | same | none | `workitem_unchanged`, state unchanged |
| W2 | setup, or blocked at setup | changed | same | none | workItem updated (Define has not run yet); blocked at setup stays blocked, so blockedAt is kept (a changed WorkItem does not fix a failed workspace; only `retry` or `stop` moves it) |
| W3 | define (incl. awaiting ask), or blocked at define | changed | define | cancel awaited (if any); run define `{}` | workItem updated; blockedAt = null when leaving Blocked |
| W4 | accept, or blocked at accept | changed | accept | cancel awaited (if any); decide accept (evidence.note = "workItem changed") | workItem updated; blockedAt = null when leaving Blocked |
| W5 | implement, check, decision (incl. asks), or blocked at one of these | changed | accept | cancel awaited (if any); decide accept, note as W4 | workItem updated; fixRounds and findings unchanged; blockedAt = null when leaving Blocked |
| W6 | land, integrate, deploy, verify, failure, close, teardown (incl. blocked there) | changed | same | fire `principal.notify{text: "WorkItem changed after Land; flow unchanged"}` | workItem updated; `workitem_changed_late` |

### 4.8 Ignored

| # | state | signal | → | commands | entry |
|---|---|---|---|---|---|
| R1 | any non-terminal, `id ≠ awaiting?.id` (incl. awaiting null) | result | same | none | `ignored_stale` |
| R2 | closed or abandoned | any | same | none | `ignored_terminal` |

Service-port `question` results and verdicts outside a port's schema never reach the core: the Runner rejects them (see §5.2).

---

## 5. Runner, CLI and adapter contract

### 5.1 CLI

| Verb | Runner does |
|---|---|
| `ship start <key>` | 1. `tracker.read{key}`. If it fails, exit 4 without calling the core. 2. `state.list{key}`, then load each Delivery and keep those whose `workItem.key === key`. 3. `core.start`. 4. If created, save as version 1, create-if-absent. If rejected, save the entry on the existing Delivery. 5. Execute the commands. |
| `ship next` | `tracker.next`. A `null` key gives `{delivery: null}` and exit 0. Otherwise it runs as `start`, so a key that already has a non-terminal Delivery is rejected (exit 0). |
| `ship signal <delivery> <id> <result-json>` | 1. The id must start with `<delivery>/`, else exit 1. 2. Load the Delivery. 3. If `id === awaiting.id`, validate the JSON against the Result schema for `awaiting.port/op` (invalid: exit 1). Otherwise skip validation, because the core will ignore it and journal it. 4. Apply. |
| `ship stop <delivery> <outcome> <reason>` | `outcome` must be in `policy.outcomes`, else exit 1. Then apply. |
| `ship changed <delivery>` **[amend, synced]** | `tracker.read{key}`, then apply `workItem_changed`. |
| `ship status [<delivery>]` **[amend, synced]** | Read-only: no core call, no save, no commands. No argument: `state.list{}`, load each Delivery, keep the non-terminal ones. With an argument: that Delivery only, even if terminal. A failed State read gives exit 4. |

**Output:** one JSON line, `{delivery, issued: [ids], awaiting: id|null, ignored?, rejected?, unapplied?, errors?}`.

**`status` output:** one JSON line, `{deliveries: [{delivery, at, awaiting}]}`, where `at` is `Snapshot.at` and `awaiting` is `awaiting.id` or `null`.

| Exit | Meaning |
|---|---|
| 0 | applied, ignored or rejected |
| 1 | invalid CLI input |
| 2 | config error; nothing touched |
| 3 | CAS conflict that did not clear after 5 tries; `unapplied` lists the pending signals for the environment to resubmit |
| 4 | State or Tracker read failed; nothing executed |
| 5 | awaited adapter crashed or printed invalid output; journaled, no signal applied, remaining commands still executed (§5.2, §5.3) |

### 5.2 Apply loop (`runner/apply.ts`)

```
queue = [signal]; crashed = false
while queue not empty:
  sig = queue.shift()
  for try in 1..5:
    {version, state} = State.load(d)
    out = core(policy, state, sig)
    if State.save(d, version+1, out.state, [out.entry + time]) == saved: break
  if not saved: exit 3 with unapplied = [sig, ...queue]
  for cmd in out.commands (cancels first):        # every command runs, whatever an earlier one returned
    p = spawn(cmd)                                  # Bun.spawn returns once the process exists
    if p is a spawn error: r = failed{info}         # ENOENT ran nothing; no sent entry
    else:
      started = startTime(p.pid)                     # read right after spawn (see Sent journal below)
      journal([sent{cmd.id, pid: p.pid, host, started}])  # before awaiting the exit
      r = await exit(p)
    note = []
    if cmd.await:
      if r is a valid Result: queue.push({kind: "result", id: cmd.id, result: r})
      if r is accepted:      note += accepted{cmd.id}   # queue no Result for cmd; continue with the rest
      if r is a crash:       note += adapter_error{cmd.id, info: stderr tail}; crashed = true
    else (fire): ignore stdout; on non-zero exit add {id, info} to errors
    if note not empty: journal(note)
if crashed: exit 5
exit 0

journal(entries) = save the unchanged state as the next version with entries + time;
                   on a conflict reload and save again (the entries do not depend on the state)
```

Rules:
- **Save before execute.** Nothing is sent until the state that awaits it is saved.
- **`accepted` stops nothing.** It means only "queue no Result for this command". The Runner carries on with the remaining commands.
- **A crash stops nothing either.** On an awaited adapter's crash (exit 5 case) the Runner journals `adapter_error`, executes the remaining commands, and only then exits 5. I1 means the remaining commands are fires.
- **Sent journal.** As soon as the adapter process has started, and before awaiting its exit, the Runner journals `sent{id, pid, host, started}`. `started` is the process start time, read right after spawn: on macOS `ps -o lstart= -p <pid>`, on Linux field 22 (`starttime`) of `/proc/<pid>/stat` **[unverified]** (both commands). After the exit it journals the outcome: the Result (as the core's entry when it is applied), `accepted{id}`, or `adapter_error{id}`. A spawn error (ENOENT) journals no `sent`. These entries are audit data: the core never reads them.
- **Crash between save and execute.** The command is lost and the core keeps waiting. The awaited id then has no `sent` entry, and the environment's stall check (`env/poll-stalled.sh`, §7) flags it. Per P6 and ADR 0004, the environment either delivers a Result or sends `stop`. The Runner never asks "already sent?", and the core stays clock-free.
- **Liveness is (pid, started).** The stall check counts a pid as alive only if the pid exists and its current start time equals `started`. A reused pid therefore counts as dead.
- **Crash during a synchronous adapter.** The `sent` entry exists, its process is gone, and no Result, `accepted` or `adapter_error` follows. The stall check flags it (§7). The adapter is not killed with the Runner: it becomes an orphan, keeps running, and its Result is lost when it exits. While it is alive it is not flagged as dead.
- **Hung adapter.** An awaited command with a live `sent` process whose age exceeds that port's `maxRuntime` is flagged "hung?". `maxRuntime` lives in the poller's own config (the environment), not in ship config; the clock lives only in `env/poll-stalled.sh`, next to the grace period. The core stays clock-free.
- **Remaining window.** A crash between process start and the `sent` write leaves a started command without its entry. It is rare, and the stall check flags it loudly as never sent; the person checking resolves it. This errs towards alerting (§7).
- **One signal per Delivery at a time.** CAS on save does this: on a conflict the Runner reloads and applies again, which is safe because the core is pure. Two parallel `start`s: one creates the Delivery, and the other retries, finds it non-terminal and is rejected. There is no lock file.
- **ajv at five points:**
  - config load
  - CLI result JSON
  - adapter stdout, against the Result schema for the command's port/op; a `question` from a service port counts as invalid
  - snapshot on load (corrupt: exit 4, never repaired)
  - stdin built for each adapter (a Runner bug guard)

### 5.3 Adapter invocation (`runner/spawn.ts`, `docs/adapters.md`)

- **argv:** `<config argv…> <port> <op>`.
- **stdin:** `Stdin` (§3.1).
- **stdout:** `Stdout`.
- **stderr:** logs; the Runner keeps the last 2 KB.
- **env:** `PATH`, `HOME`, plus the port's capability-profile `env` with secrets resolved. Nothing else is inherited.
- **cancel delivery.** `cancel{target}` is spawned like any fire command, on the target's port adapter (§3.2). The adapter, or a person acting on a stall flag, can also terminate an orphaned target process by the recorded `(pid, started)` pair from its `sent` entry: kill only if the pid's current start time still equals `started`.

| Adapter behaviour | Runner turns it into |
|---|---|
| exit 0, `{"status":"accepted"}` | waiting |
| exit 0, a valid Result (incl. an explicit `failed`) | that Result, fed back as a signal |
| exit 0, invalid JSON or fails the schema | `adapter_error`, no signal; remaining commands run, then exit 5 |
| exit ≠ 0 | `adapter_error`, no signal; remaining commands run, then exit 5 |
| spawn error (executable not found; provably ran nothing) | `failed{info}` |

**Resolution.** Only an explicit `failed` means "changed nothing" (architecture: "that is the adapter's contract"; ADR 0004). A crash may follow a side effect, so the core must not re-issue it.

**Adapter rule** (in `docs/adapters.md`): catch your own errors. Print `failed` only when you changed nothing; otherwise report through `ok` or `question`.

---

## 6. Milestones and steps

Rules for every step:
- **Test first.** Write the failing test, see it red, then implement.
- **Exempt from test-first:** docs, spike and dogfood steps (M1.8, M1.12, M3.8). They are checked by their "Done when", and a docs step that makes a runnable claim gets an e2e test (M0.23).
- **Green gate.** `bun run check` (`tsc --noEmit` + `bun test`) passes.
- **Commits.** One conventional commit per step.
- **Tables.** Core tests use `test.each` tables, one row at a time **[verified]**: `test.each` works in `bun:test` 1.4.2.

### M0 — walking skeleton (full lifecycle on fakes)

- [x] **M0.1 Scaffold.**
  - Test: `smoke.test.ts` imports `src/core/types.ts` and asserts a trivial constant.
  - Impl: `package.json` (ajv ^8.20, typescript), strict `tsconfig.json`, scripts `test`, `typecheck` and `check`, and `bin/ship`.
  - Done when `bun run check` is green.
- [x] **M0.2 Ids.**
  - Test: table for `deliveryId("PROJ-123", 2) = "PROJ-123-2"`, `nextId(seq, "land")` giving `land-1` then `land-2`, key regex accept/reject, and `parseCommandId`.
  - Impl: `core/ids.ts`.
  - Done when the table is green.
- [x] **M0.3 Contract schemas.**
  - Test: valid/invalid table for `Result`, the check `ok` union, `Decide` and `Stdin`, plus type tests pairing `JSONSchemaType<T>` with each type.
  - Impl: `contracts/common.ts`, `contracts/ports.ts` with a registry lookup `schemaFor(port, op)`.
  - Done when every port/op in §3.2 has a schema and the tests are green.
  - **[verified]** `JSONSchemaType<T>` accepts `oneOf` discriminated unions with `const` and optional (`nullable`) fields under ajv 8.20 and TS 7.0.2.
- [x] **M0.4 `start`.**
  - Test: rows S1–S6, one at a time.
  - Impl: `core/start.ts`.
  - Done when S1–S6 are green, including their entries.
- [x] **M0.5 Happy path, part 1.**
  - Test: rows H1–H6, including H3a (a step with a configured status fires `tracker.update`) and H3b (no status configured: no fire).
  - Impl: `transition.ts` dispatch, `steps.ts` builders, `gates.ts` decide builder and evidence bundle.
  - Done when H1–H6 are green.
- [x] **M0.6 Happy path, part 2.**
  - Test: rows H7–H12, including Close's `tracker.update` and the Closed notify.
  - Done when H7–H12 are green.
- [x] **M0.7 Ignored.**
  - Test: rows R1–R2, with state deep-equal (I5).
  - Done when green.
- [x] **M0.8 Fix rounds.**
  - Test: rows F1–F10.
  - Done when green.
- [x] **M0.9 Failure gate.**
  - Test: rows X1–X4.
  - Done when green.
- [x] **M0.10 Questions.**
  - Test: rows Q1–Q6.
  - Done when green.
- [x] **M0.11 Retries and Blocked.**
  - Test: rows B1–B7, plus a cap of 0 (the first `failed` goes straight to Blocked).
  - Done when green.
- [ ] **M0.12 Delivery signals.**
  - Test: rows D1–D3 and W1–W6, including W3–W5 entered from Blocked (blockedAt = null) and W2 blocked at setup (blockedAt kept).
  - Done when green.
- [ ] **M0.13 Invariants.**
  - Test: `invariants.test.ts` runs every row fixture from M0.4–M0.12 and asserts I1–I6. It also scans `src/core/**` with the word-boundary regex `\b(claude|dod|jira|telegram|github|gh|git)\b` and fails on a match. It strips `//` and `/* */` comments before matching.
  - Caveat: the scan is a guard, not a proof. A tool name built from parts (`"gi" + "t"`) passes it, and an English word in a string literal that matches (for example `"git"` in a message) fails it on purpose.
  - Done when green.
- [ ] **M0.14 File State adapter.**
  - Test: table for save v1 → load, `EEXIST` conflict, highest-version load, list by key (`PROJ-1` vs `PROJ-12`), list all, journal order across versions, and a corrupt file failing load.
  - Impl: `adapters/state-files.ts --dir`.
  - Done when green by piping JSON into the executable.
- [ ] **M0.15 Spawn.**
  - Test: fixture bash adapters returning ok, accepted, failed, invalid JSON, schema-invalid, exit 1 and ENOENT. Also:
    - a parent secret env var is absent in the child and the profile env is present
    - a `cancel` command spawns the target's port adapter with argv `<port> cancel` and stdin payload `{target}`; it is a fire, so a non-zero exit lands in `errors`
  - Impl: `runner/spawn.ts`.
  - Done when each row maps as in §5.3.
- [ ] **M0.16 Config.**
  - Test: table for valid, cross-layer key, unknown port, missing key, undeclared `$secrets`, a missing `delivered.status`, and an outcome without a mapping.
  - Impl: `runner/config.ts`.
  - Done when green, with exit 2 on each invalid case.
- [ ] **M0.17 Apply loop.**
  - Test, with an in-process fake State and fake spawn:
    - an immediate-result chain runs until `accepted`
    - save happens before execute (spawn sees the saved version)
    - a persistent conflict after an immediate Result gives exit 3 with `unapplied`
    - an adapter crash gives exit 5 and an entry with `signal: {kind: "adapter_error", id}` and the stderr tail in `info`
    - a failed fire command lands in `errors`
    - each spawn that started a process journals `sent{id, pid, host, started}`, with the child's pid and the start time read right after spawn (the fake spawn supplies it); an `accepted` stdout adds `accepted{id}`; ENOENT journals no `sent`
    - journal order: `sent{id}` is written before the adapter exits (a fake adapter that blocks until the test sees `sent` in the fake State, then exits)
    - commands `[cancel A, decide B → accepted, notify C]`: C is sent, and the journal holds `sent{A}`, `sent{B}`, `accepted{B}`, `sent{C}`
    - commands `[cancel A, decide B → crash, notify C]`: C is still sent, then exit 5
  - Impl: `runner/apply.ts`.
  - Done when green.
- [ ] **M0.18 CLI.**
  - Test: subprocess tests per verb and exit code, including:
    - an id from another Delivery (exit 1)
    - an answer outside the options reaching the core (exit 0, `invalid_answer`)
    - a stop outcome not in config (exit 1)
    - `next` with a null key
    - `next` returning a key that already has a non-terminal Delivery (rejected, exit 0)
    - `status` with no argument lists only non-terminal Deliveries as `{deliveries: [{delivery, at, awaiting}]}`; `status <d>` returns that one; neither writes a State version
    - two parallel `start`s giving one Delivery
  - Impl: `src/cli.ts`.
  - Done when green.
- [ ] **M0.19 Fakes.**
  - Test: the fake adapter replays a fixture script (per port, the nth call returns the nth scripted stdout) and records its stdin.
  - Impl: `adapters/fake.ts` serving tracker, workspace, every step port and principal, driven by `--script`.
  - Done when the fixture replay is green.
- [ ] **M0.20 Terminal Principal.**
  - Test: `decide` and `ask` print the gate, options, evidence and a paste-ready `ship signal <d> <id> '{"status":"ok","body":{"answer":"…","by":"person"}}'` line to `--out` (default `/dev/tty`), and return `accepted`. `notify` prints and returns `ok`. `cancel` prints "withdrawn".
  - Impl: `adapters/principal-terminal.ts`.
  - Done when green.
- [ ] **M0.21 End-to-end on fakes.**
  - Test: `test/e2e/lifecycle.test.ts` drives `bin/ship` with a fake config through these scenarios:
    - happy path to Closed
    - fix round
    - N rounds to Decision, then `keep_going`
    - Land `rework` and `rescope`
    - question and answer
    - integrate conflict `resolved` and `rework`
    - failed to Blocked, then `retry`
    - Failure gate accept giving `accepted_with_failure`
    - `stop` mid-step (cancel issued, no teardown)
    - `changed` before and after Land
    - a stale duplicate Result
    - duplicate `start`

    Each asserts the final position (`Snapshot.at`), the journal sequence and the adapter stdin log.
  - Done when every scenario is green.
- [ ] **M0.22 Property tests.**
  - Test: `test/property/lifecycle.property.test.ts` uses fast-check. It drives the real core and Runner against a simulated environment (in-process fake State and fake adapters). The simulation may, at any point:
    - crash the Runner between load, apply, save and execute
    - duplicate, reorder or drop signals; a dropped signal is eventually followed by a `stop`
    - send `workItem_changed` or `stop` at any time

    The simulated Principal answers with a `by` at or above the `min` it was sent (the adapter's contract, ADR 0003). Invariants checked on every run, over the journal and the final snapshots:
    - Integrate is issued only after a Land `approve` by a Principal at or above the Land minimum
    - Deploy is issued only after Integrate `landed`
    - Close is entered only after a Verify `pass` or a Failure gate `accept`
    - a Result is applied only if its id is awaited
    - command ids are never reused
    - at most one non-terminal Delivery per WorkItem
    - Closed and Abandoned are absorbing
    - fix rounds ≤ N between Principal decisions
    - no silent stall: every non-terminal, non-Blocked Delivery has an awaited command that either has a `sent` entry with a live process (pid and `started` match) younger than `maxRuntime`, an `accepted` entry, or is flagged by the stall check (never sent, dead, or "hung?")

    Stall-check cases in the simulation (fake spawn models pids, start times and liveness):
    - a synchronous adapter running longer than the grace period but shorter than `maxRuntime` is not flagged
    - orphans: when the simulated Runner dies, its adapter does not die with it. It keeps running (not flagged while younger than `maxRuntime`, flagged "hung?" once older), then exits with its Result lost. Once its process is gone with no outcome entry, it is flagged.
    - pid reuse: the dead adapter's pid is reused by an unrelated process with a different start time; it still counts as dead and is flagged.
  - Impl: crash-injection hooks in the fake State and fake spawn; no change to the core.
  - Done when green over the default fast-check run count, with a fixed seed recorded for any failure found.
- [ ] **M0.23 Docs.**
  - Test: `test/e2e/readme.test.ts` extracts the happy-path shell block from `README.md` and runs it against the fake config. It must reach Closed.
  - Impl:
    - `README.md` (install, config, CLI, including `status`)
    - `docs/adapters.md` (the stdin/stdout/exit contract, the rule on crash vs `failed`, `cancel`, idempotency on id)
    - check that `architecture.md` still matches the code; the **[amend, synced]** items were synced on 2026-09-28
  - Done when the README test is green and a fresh agent can run the happy path from the README alone.

**M0 is done when:**
- All steps are checked and `bun run check` is green.
- A manual run with terminal Principal plus fakes reaches Closed, with the person pasting the printed signals.
- A fresh-agent review has passed.

### M1 — shared real adapters and the Home setup MVP (terminal Principal)

Why first: M1 has no external accounts and can dogfood on harlo. Every adapter below except the md tracker is reused by the Work setup.

- [ ] **M1.1 git-worktree Workspace.**
  - Test: in a temp repo, `setup` creates worktree `<root>/<delivery>` on branch `ship/<delivery>` from the main line and returns `{path}`. `teardown` removes the worktree and the branch. Both are idempotent (a second call gives `ok`). `cancel` is a no-op.
  - Impl: `adapters/workspace-worktree.ts --main <branch> --root <dir>`.
  - Done when green.
- [ ] **M1.2 md-file tracker: read, next, update.**
  - Test: `<dir>/<key>.md` with frontmatter `status:`. `read` gives key = file slug, title from the H1 or frontmatter `title`, and body = the text above the `<!-- ship:log -->` marker. `next` gives the first file (sorted by name) with `status: ready`, or null. `update` rewrites only the frontmatter `status`.
  - Impl: `adapters/tracker-md.ts --dir`.
  - Done when green.
- [ ] **M1.3 md-file tracker: comment.**
  - Test: `comment` appends a line below `<!-- ship:log -->`, and `read` then returns an unchanged body. A later `ship changed` therefore hits W1 (no self-echo).
  - Done when green.
- [ ] **M1.4 WorkItem change and stall pollers.**
  - Test: a bats-free shell test runs both scripts against the fakes.
    - `env/poll-changed.sh` calls `ship changed <d>` for each Delivery in `ship status`.
    - `env/poll-stalled.sh` reads `ship status`, then pipes `{delivery}` into the configured State adapter's `state journal`. A process counts as alive only if its pid exists and its current start time equals the `sent` entry's `started` (macOS `ps -o lstart= -p <pid>`, Linux `/proc/<pid>/stat` field 22 **[unverified]**). It flags each Delivery whose `awaiting` id:
      - has no `sent` entry, and its last entry is older than a grace period (the environment's clock, not the core's): "never sent"; or
      - has a `sent` entry whose `host` is not the poller's host: "unknown host". §7 puts the State directory on a local filesystem, so poller and Runner share a host; a foreign host is flagged loudly, never skipped silently; or
      - has a `sent` entry whose process is not alive, and no Result, `accepted` or `adapter_error` entry: "dead"; or
      - has a `sent` entry whose process is alive, no outcome entry, and an age (now − `started`) above `maxRuntime` for its port: "hung?". `maxRuntime` per port is the poller's own config (environment), not ship config.

      `accepted` commands are not pid-checked: their work continues elsewhere. This is an environment check; the clock lives only here, next to the grace period, and the core stays clock-free and never reads these entries. Cases:
      - sent, process alive, younger than `maxRuntime` (no flag)
      - sent, process alive, older than `maxRuntime` ("hung?")
      - not sent and old (flag); not sent and within the grace period (no flag)
      - awaiting null (no flag)
      - `accepted` with a dead pid (no flag)
      - `sent.host` ≠ the poller's host ("unknown host")
      - pid alive but its start time ≠ `started` (pid reused: "dead")
      - (a) a synchronous adapter running longer than the grace period, within `maxRuntime` (no flag)
      - (b) the Runner killed during a synchronous adapter: `sent` present, process gone, no Result ("dead")
  - Impl: `env/poll-changed.sh`, `env/poll-stalled.sh`. The flag is one line on stdout per Delivery, for cron mail or an alert hook.
  - Done when green.
- [ ] **M1.5 Local-merge Integrate: landing.**
  - Test: in temp repos, rebase `ship/<d>` onto the main line, `merge --ff-only` into the main line, then push if a remote is configured. Returns `ok{landed}`.
  - Impl: `adapters/integrate-local.ts`.
  - Done when green.
- [ ] **M1.6 Local-merge Integrate: conflict.**
  - Test: a conflicting change makes the adapter abort the rebase and return `question{about: "conflict", prompt, evidence}`. When re-issued with `answer: "resolved"`, it retries the rebase.
  - Done when green.
- [ ] **M1.7 ask-principal (Deploy and Verify).**
  - Test: with no `answer`, the adapter returns `question{about: "manual", prompt, options}`: `[live, not_live]` for deploy, `[pass, fail]` for verify. When re-issued with an answer, it returns the matching `ok{verdict}`, and for a negative answer `findings: [{text: answer}]`.
  - Impl: `adapters/ask-principal.ts`.
  - Done when green.
- [ ] **M1.8 Spike: coding-agent CLI (timebox 2h).**
  - Test: a manual script confirms, for the headless CLI:
    - structured JSON output against a schema
    - resuming a session by id
    - a working directory set to the workspace
    - an exit code on auth failure

    Record the findings in `docs/adapters.md`.
  - Done when every item above is marked verified or not in `docs/adapters.md` and in the headless coding-agent row of §8.3.
- [ ] **M1.9 Agent adapter: Define.**
  - Test: a fake agent binary (injected via `--agent-bin`) returns structured output, and the adapter maps it to `ok{criteria, runbook}`, or to `question{about: "clarify"}` when the output carries a question field.
  - Impl: `adapters/agent-claude.ts define run`.
  - Done when green on the fake. A manual run on a real WorkItem produces criteria and a runbook.
- [ ] **M1.10 Agent adapter: Implement.**
  - Test: with the fake agent, the adapter:
    - commits in the workspace and returns `ok{changeset: "ship/<d>@<sha>"}`
    - stores the session id in its own state file, keyed by Delivery
    - resumes that session when payload has `findings`, `feedback` or `answer`
    - never returns `failed` after any commit
  - Done when green on the fake plus one real run.
- [ ] **M1.11 Agent adapter: Check.**
  - Test: the adapter always starts a fresh session (P8; it asserts no resume flag) and maps output to the `pass`, `fix` and `decide` verdicts.
  - Done when green on the fake plus one real run.
- [ ] **M1.12 Home dogfood.**
  - Test: a manual end-to-end run on one real harlo WorkItem: md tracker, worktree, the agent adapter, local merge, ask-principal, terminal Principal.
  - Done when the WorkItem is Closed, the journal is complete, and every issue found is fixed or logged.

### M2 — Home setup complete

- [ ] **M2.1 Telegram Principal: decide.**
  - Test: with a mocked Bot API over HTTP, `decide` sends a message with inline buttons, each carrying a short token. The adapter state file maps token → `{delivery, id, answer}`. It returns `accepted`.
  - Impl: `adapters/principal-telegram.ts`.
  - Done when green.
- [ ] **M2.2 Telegram Principal: ask, notify, cancel.**
  - Test: `ask` without options is a force-reply message; `ask` with options uses buttons. `notify` is a plain message. `cancel` edits the message to "withdrawn".
  - Done when green.
- [ ] **M2.3 Telegram listener.**
  - Test: a mocked `getUpdates` gives a callback, and the listener runs `ship signal <d> <id> {ok, answer, by: person}`. A reply to a force-reply resolves through the reply's message id. An unknown or expired token gets a "withdrawn" reply.
  - Impl: `env/telegram-listener.ts`, long-poll, no inbound port.
  - Done when green, plus one real round trip on a phone.
- [ ] **M2.4 GitHub issues tracker.**
  - Test: with a fake `gh` on PATH:
    - read gives key `<repo>-<n>`, title and body
    - update sets or clears a status label
    - comment
    - next is a label query
    - label changes and comments leave title and body unchanged (W1)
  - Impl: `adapters/tracker-github.ts`.
  - Done when green.

### M3 — Work setup

- [ ] **M3.1 Jira tracker: read and next.**
  - Test: with a mocked REST API, `read` maps summary and description to title and body (ADF to plain text), and `next` runs a configured JQL query.
  - Impl: `adapters/tracker-jira.ts`.
  - Done when green.
- [ ] **M3.2 Jira tracker: update and comment.**
  - Test: a status maps to a transition id from adapter config. A comment posts. A transition with no mapping gives `failed` (changed nothing).
  - Done when green.
- [ ] **M3.3 Jira change detection.**
  - Test: the poller runs `ship changed` for active Deliveries. ship's own transitions and comments give W1.
  - Impl: reuses `env/poll-changed.sh`.
  - Done when green.
- [ ] **M3.4 PR Integrate adapter.**
  - Test: with a fake `gh`, the adapter pushes `ship/<d>`, creates the PR, enables auto-merge and returns `accepted`. `cancel` closes the PR. It is idempotent on the command id (an existing PR is reused).
  - Impl: `adapters/integrate-pr.ts`.
  - Done when green.
- [ ] **M3.5 PR watcher.**
  - Test: with a fake `gh`:
    - merged gives `ship signal … ok{landed}`
    - failed checks give `ok{fix, findings}` (check names plus log-tail refs)
    - a merge conflict gives `question{about: conflict}`
  - Impl: `env/watch-pr.ts`.
  - Done when green.
- [ ] **M3.6 GitHub Actions Deploy adapter and watcher.**
  - Test: with a fake `gh`, the adapter finds or triggers the run for the landed SHA and returns `accepted`. The watcher sends `ok{live}` on success or `ok{not_live, findings}` on failure. An optional health-probe URL is supported.
  - Impl: `adapters/deploy-gha.ts`, `env/watch-deploy.ts`.
  - Done when green.
- [ ] **M3.7 e2e Verify agent.**
  - Test: with the fake agent, a fresh session (P8) gets the runbook plus the prod URL from the capability env and maps its output to `ok{pass|fail, findings}`. Prod credentials are present only in the verify profile.
  - Impl: `agent-claude.ts verify run`.
  - Done when green on the fake plus one real run against staging or prod.
- [ ] **M3.8 Work dogfood.**
  - Test: one real Jira WorkItem through PR, Actions and Verify, with the terminal Principal.
  - Done when it is Closed and the journal is complete.

---

## 7. Environment requirements

The Runner starts no listeners. The environment must provide what follows.

### Common (both setups)
- **Runtime:** Bun ≥ 1.4 **[verified 1.4.2 locally]**, git, and `bin/ship` on PATH.
- **State directory:** writable, on a local filesystem (hard links must work).
- **Crash duty (P6).**
  - If `ship` exits 5, the Delivery stays waiting. The environment alerts a person, who then sends the Result by hand or sends `stop`.
  - If `ship` dies between save and execute, the awaited command was never sent, and its id has no `sent` entry in the journal. A cron or loop running `env/poll-stalled.sh` flags it; the person then acts as for exit 5. The check keeps time in the environment, so the core stays clock-free.
  - If `ship` dies while a synchronous adapter runs, the adapter is orphaned: it keeps running and its Result is lost. Once its process (pid plus start time) is gone with no Result, `accepted` or `adapter_error`, `env/poll-stalled.sh` flags it; while it runs past its port's `maxRuntime` it is flagged "hung?". The person acts as for exit 5, and may terminate the orphan by its `(pid, started)` pair.
  - Remaining window: if `ship` dies between process start and the `sent` write, the command may have run but looks never sent. It is rare, and the check flags it loudly; the person checks the adapter's side effects before sending a Result or `stop`. This errs towards alerting.
  - On exit 3, it resubmits the signals in `unapplied`.
- **Coding agent:** the CLI installed and authenticated (subscription login or an API key in the capability env). **[unverified]** headless and structured-output behaviour, pending spike M1.8.
- **Change detection:** a cron or loop running `env/poll-changed.sh`.
- **Stall detection:** a cron or loop running `env/poll-stalled.sh` on the Runner's host, with its alert wired to a person, and its own config giving the grace period and `maxRuntime` per port.

### Home

| Need | Detail |
|---|---|
| Listeners | Telegram long-poll listener, run as a user service (launchd or systemd), from M2. Before that, a person at a terminal pastes the printed `ship signal` lines. |
| Secrets | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (principal); `GH_TOKEN` (integrate push, GitHub issues tracker); agent auth |
| Other | md task directory outside the repo; git remote for the main line, if pushing |

### Work

| Need | Detail |
|---|---|
| Listeners | Jira poller (polling recommended: a webhook into the corporate network is **[unverified]**); PR watcher; Actions run watcher; Principal channel (terminal, or Telegram if company policy allows) |
| Secrets | `JIRA_BASE_URL`, `JIRA_EMAIL`, `JIRA_API_TOKEN` (tracker); `GH_TOKEN` with repo and workflow scope (integrate, deploy); agent auth; prod or staging test credentials and URL (verify profile only) |
| Other | branch protection allowing auto-merge; the Jira transition-id map in the tracker adapter's config; a browser for the e2e Verify agent |

---

## 8. Decisions, assumptions and follow-ups

### 8.1 Decisions (all 14 accepted by the user on 2026-09-28)

1. **Architecture amendments A1–A5** **[amend, synced]**. **Decided:** accept all five; synced into `architecture.md`.
   - A1 `tracker.next`; A2 `state.list{key?}`; A3 the `ship changed <delivery>` verb; A4 `question{about, options?}`, where `about` is an adapter-defined category mapped in config to a Minimum Principal (unknown → `person`); A5 `about: scope|advisory` on Check's `decide` verdict.
   - Why: `next`, the Minimum Principal for questions and the Decision gate, and the Integrate conflict branch cannot be built without them.
2. **Crash vs `failed`.** **Decided:** a non-zero exit or invalid stdout from an awaited adapter becomes exit 5 with no signal; the environment or a person then acts.
   - Why: it is the only reading that keeps ADR 0004's "re-issue is safe" true. Treating a crash as `failed` is simpler but can repeat a side effect.
3. **Recovering a lost command** (crash between save and execute, or exit 5). **Decided:** v1 recovers only by a Result sent by hand, or by `stop` then `start`. The `sent` journal entry plus `env/poll-stalled.sh` detects the loss (§5.2, §7).
   - Why: YAGNI. Add `ship reissue <delivery>` later if this proves painful; it would be a Runner verb and must not become a core check.
4. **`ship status [<delivery>]`** **[amend, synced]**. **Decided:** add it as a read-only verb (§5.1).
   - Why: pollers (M1.4) and people need the non-terminal Deliveries with their position and awaiting id.
5. **Decision gate options.** **Decided:** `[keep_going, accept, stop]`.
   - Why: the diagram's "fix / keep going" is one answer, `keep_going`.
6. **Fix-round counting.** **Decided:** keep as tabled. Counted: Check `fix` and Integrate `fix`. Not counted: Land `rework`/`rescope`, `fix_forward`, and conflict `rework`. `workItem_changed` back to Accept resets neither fix rounds nor findings.
   - Why: the glossary says "a return from a check", and the only stated reset is `keep_going`.
7. **Minimum Principal for questions.** **Decided:** `question.about` is mapped in `policy.minimum.question`; unknown values default to `person`. The Decision gate reached through N rounds uses `decision.scope`.
   - Why: strictest by default.
8. **`stop` during Close or Teardown.** **Decided:** it overwrites the `delivered` outcome with `stop`'s outcome.
   - Why: the environment owns rollback, and it is journaled.
9. **Blocked with the Principal unreachable (B6).** **Decided:** the Delivery waits until `stop` or `changed`; no retry is possible without the environment.
   - Why: as the architecture states. Revisit alongside decision 3.
10. **Principal and State adapters live in the machine config layer.** **Decided:** yes.
    - Why: both are machine-specific.
11. **Capability profiles apply to every port** **[amend, synced]**. **Decided:** yes, not only step ports.
    - Why: tracker and principal adapters need secrets too.
12. **Milestone order.** **Decided:** M1 (shared, then Home MVP), M2 (Home complete), M3 (Work).
    - Why: M1 needs no external accounts and dogfoods on harlo.
13. **Lint.** **Decided:** `tsc --noEmit` counts as lint for v1.
    - Why: YAGNI. Add a linter only if the repo adopts one.
14. **Orphaned adapters.** **Decided:** no process-group tricks to make adapters die with the Runner. An orphan is detected by the stall check (dead or "hung?") and terminated through `cancel{id}` or by a person, by its recorded `(pid, started)` pair (§5.2, §5.3).
    - Why: children already share the Runner's process group by default, a SIGKILL on the Runner alone does not kill them, and macOS has no reliable parent-death signal.

### 8.2 Conflicts between the planning parts, and how each was resolved

| Topic | Resolution | Basis |
|---|---|---|
| Crash or bad output → `failed` (contracts, runner) vs no signal (adapters) | no signal, exit 5; spawn ENOENT → `failed` | ADR 0004, arch "failed … changed nothing" |
| Core checks `by` against `min` | no check; `by` journaled only | ADR 0003, ADR 0005 |
| `blocked` inside `Gate` | removed; `DecidePoint` adds it | CONTEXT (four gates) |
| `State.count` vs `State.list` | `list`; the core decides what is terminal | arch: attempt counted "in State"; P1 |
| Integrate conflict detection (the core's gap G1) | `question.about = "conflict"` on integrate; the core forces `[resolved, rework]` | arch edge-case table |
| Conflict `options` from the adapter vs the core | the core owns them for the conflict; other questions may carry adapter options | P4 (gates and branching belong to the core) |
| Lock file vs CAS | CAS via versioned `link`; no lock | arch "one signal at a time"; the runner part's crash-safety point |
| Journal as a third core output | a single `entry` per application; the Runner stamps `time` and saves it with the snapshot | ADR 0005; keeps the core pure (extends ADR 0002's signature) |
| Gate options in config vs in the core | core constants; config keeps only the Minimum Principal per gate and decision kind **[amend, synced]** | P1: the core branches on them |
| Self-echo in change detection | W1: the core ignores an unchanged title and body, and the adapters keep their own writes out of both | pure comparison; no world check (ADR 0004) |
| `workItem_changed` during Setup | stay in Setup and update the data (sending it to Accept would skip Setup); Blocked at Setup stays Blocked, because a changed WorkItem does not fix a failed workspace: only `retry` or `stop` moves it | new row W2 |
| Runner-side `inputs` / listeners config | dropped from the machine layer; the environment owns listeners **[amend, synced]** | P6, ADR 0004 |
| Adapter state location | each adapter owns its own file | P5 |

### 8.3 Assumptions and their status

| Assumption | Status |
|---|---|
| Bun 1.4.x with `bun:test` `test.each` | **[verified]** Bun 1.4.2 |
| `JSONSchemaType<T>` with `oneOf` unions and optional fields type-checks | **[verified]** ajv 8.20.0, TypeScript 7.0.2, 2-variant unions; larger unions **[unverified]** |
| `linkSync` throws `EEXIST` atomically | **[verified]** macOS / Bun 1.4.2; Linux **[unverified]** |
| Headless coding-agent CLI: structured output, session resume, a question field, exit codes | **[unverified]**; spike M1.8 |
| Whether a quality-check plugin can serve as the Check adapter's internals | **[unverified]**; not read on purpose; adapter choice only |
| A Jira webhook can reach the machine from the corporate network | **[unverified]**; plan uses polling |
| Telegram `callback_data` limit (≈64 bytes) | handled by short tokens either way; exact limit **[unverified]** |
| A green Actions run means "live" | **[unverified]**; optional health probe in M3.6 |
| "Moshi" as a mobile SSH client for the terminal Principal | **[unverified]**; not needed by the plan |
| Hard links work in the chosen state directory (not every network or FUSE mount supports them) | **[unverified]** per machine |
| Process start time as a pid-reuse guard: macOS `ps -o lstart= -p <pid>`, Linux `/proc/<pid>/stat` field 22 `starttime` | **[unverified]** both commands |

### 8.4 Follow-ups

- **Formal model.** If the M0.22 property tests find interleaving bugs, the follow-up is a Quint or TLA+ model of core + Runner + environment, checking the same invariants.
