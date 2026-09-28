# ship — architecture

Status: draft, from the design grilling of 2026-09-25. Amended 2026-09-28 from
implementation planning (A1–A5, `status`, configuration layers; see
[`plan.md`](plan.md) §8.1). Terms are defined in [`../CONTEXT.md`](../CONTEXT.md).

ship carries one WorkItem from a tracker to a verified production release.
A deterministic core drives a fixed lifecycle; everything that varies between
projects and machines (tracker, Principal channel, coding agent, CI, deploy,
storage) sits behind ports and is filled by adapters chosen in config.

## Principles

| # | Principle |
|---|---|
| P1 | **Control flow lives in the core, never in a model.** A step's next state is decided only by its port's typed result. |
| P2 | **The core handles one Delivery per invocation.** Parallelism, queuing and staying reachable are the environment's concern. |
| P3 | **The core runs only when signalled.** It never calls and waits: given a signal it returns the new state and the commands to issue. The Runner around it loads and saves state and carries out the commands; every result comes back as a signal through the input port. |
| P4 | **Gates belong to the core.** A decision is routed to the configured Principal by construction; the worker doing a step never decides its own gate. |
| P5 | **The core knows *what* work happens, never *who* does it.** Tools, agents and sessions are adapter internals. |
| P6 | **The environment owns delivery of results.** Crashes, delays, backoff and alerts between a command and its signal are the environment's concern; the core stays waiting until the next signal or a `stop`. |
| P7 | **The core has no clock.** No timers or timeouts inside it; reminders, escalation and expiry belong to adapters and the environment, and reach the core only as signals (e.g. `stop{outcome: abandoned, reason: "no answer"}`). |
| P8 | **No worker grades its own work.** Check and Verify run independently of the worker that implemented; how that is achieved is the adapter's concern. |
| P9 | **Every gate carries what the Principal needs to decide.** The decision, the allowed answers, and the evidence the steps produced (acceptance criteria, findings, links to the changeset and runs). The core passes that evidence through; it does not interpret it. |

## L1 — System context

```mermaid
flowchart LR
  trig["Trigger source<br/>(person, cron, webhook, agent)"]
  pr["Principal<br/>(person on Telegram / terminal,<br/>or advisor model)"]
  ship(["ship<br/>delivers one WorkItem"])
  tr["Tracker<br/>(Jira, md files, GitHub issues)"]
  ag["Coding agent<br/>(Claude Code, …)"]
  vcs["VCS / CI<br/>(git, GitHub Actions, …)"]
  prod["Production<br/>(app, email, side effects)"]
  st["State storage<br/>(files, DB, remote)"]

  trig -- "start / next / signal / stop / changed / status" --> ship
  ship <-- "ask · decide · notify" --> pr
  ship --> tr
  ship --> ag
  ship --> vcs
  ship --> prod
  ship --> st
```

## L2 — Containers

```mermaid
flowchart TB
  subgraph IN["Input"]
    T["Trigger port<br/>start · next · signal · stop<br/>changed · status"]
  end

  subgraph CORE["Core (deterministic, one Delivery)"]
    L["Lifecycle state machine<br/>steps + gates"]
  end

  R["Runner<br/>load · apply · save · execute commands"]

  subgraph STEP["Step ports — what work"]
    D["Define<br/>acceptance criteria + runbook"]
    I["Implement"]
    C["Check<br/>change check"]
    G["Integrate<br/>land on main line"]
    P["Deploy<br/>release, wait until live"]
    V["Verify<br/>release check"]
  end

  subgraph SVC["Service ports — support"]
    TR["Tracker<br/>read · next · update · comment"]
    PR["Principal<br/>ask · decide · notify"]
    S["State<br/>load · save · list · journal"]
    W["Workspace<br/>setup · teardown"]
  end

  T --> R
  R --> L
  R --> D & I & C & G & P & V
  R --> TR & PR & S & W
```

Each port is served by an **executable adapter** chosen in config, speaking a
JSON contract (stdin/stdout + exit code), validated against the port's schema.
An adapter's stdout is either **the result** (the work finished within the call,
e.g. a git merge) or **`accepted`** (the result arrives later as a signal, e.g.
a Telegram answer or a CI run). The Runner turns a stdout result into a signal,
so the core sees one path either way.
One adapter may serve several ports and share whatever it likes between them
(e.g. one coding-agent adapter serving Define, Implement and Check — within P8).
Tracker writes are tracker data, never part of a Delivery's changeset: they
never go through the Workspace or the Land gate. Where they land is the Tracker
adapter's concern — e.g. a markdown-file adapter configured per project writes
either to a file outside the repo, or commits only the task file directly to
the main line.
Tools such as an MCP `ask` server for in-step questions are adapter internals;
the core only sees the resulting `question` signal.

### Commands and signals

The core is `(state, signal) → (state′, commands)`. It returns **commands**, each
carrying an id, for the Runner to send, and records what it awaits. Signals reach it through the input port in two
kinds:

| Kind | Examples | Matched by |
|---|---|---|
| **Result** | a step's result, a gate's answer, `retry` from Blocked | the awaited command id |
| **Delivery signal** | `start`, `stop`, `workItem_changed` | the Delivery id only |

| Signal result | Core reaction |
|---|---|
| `ok{…}` | advance to the next step or gate |
| `failed{info}` | re-issue up to the step's retry cap (config, immediate, no delay), then `Blocked` |
| `question{prompt, about, options?}` | route to the Principal at the Minimum Principal for `about`; send the answer back to the same step as a new command |

A `question` carries `about`, an adapter-defined category (e.g. `clarify`,
`login`, `conflict`) that config maps to a Minimum Principal; an unknown `about`
gets `person`. It may carry `options`, the allowed answers. Only step ports
raise questions.

`failed` means the step **could not run and changed nothing** (e.g. the app
under test did not start). That is the adapter's contract; a step that had a side
effect reports it in `ok` or raises a `question`. The core may therefore re-issue
a `failed` command safely. Delays and backoff are the environment's (P6).

Check, Deploy and Verify carry a **verdict** inside `ok`, because a red result is
an answer, not a failure.

| Check signal | Core does |
|---|---|
| `ok{verdict: pass}` | → Land gate |
| `ok{verdict: fix, findings}` | → Implement with the findings, up to N rounds (config, default 2) |
| `ok{verdict: decide, about, findings}` | → Decision gate; `about` is `scope` or `advisory` and picks the Minimum Principal |
| N fix rounds used | → Decision gate: keep going, accept, or stop |
| `failed{info}` | re-issue up to the retry cap, then Blocked |

Deploy: `ok{verdict: live}` → Verify, `ok{verdict: not_live}` → Failure gate.
Verify: `pass` → Close, `fail` → Failure gate.
Integrate: `ok{verdict: landed}` → Deploy, `ok{verdict: fix, findings}` (e.g. red
CI on the pull request) → Implement, counted as a fix round.

A Principal's answer is a signal like any other. Whether it completes a step
("deployed" → Deploy is `ok`) or re-issues it ("logged in" → run again) is
defined by the step.

Rules:

- The command id identifies one instance of a step or gate. A **Result** whose
  id the core is not waiting for (duplicate, stale answer) is ignored.
  **Delivery signals** are always applied.
- When a Delivery signal makes an outstanding command moot (`stop`, or
  `workItem_changed` sending it back to Accept), the core issues `cancel{id}`;
  the environment carries it out.
- One signal is applied per Delivery at a time.
- **Save before execute.** The Runner saves the state that awaits a command
  before it sends the command. As soon as the adapter process has started,
  before awaiting its exit, it journals `sent{id, pid, host, started}`
  (`started` = the process start time, so a reused pid is not mistaken for the
  adapter); after the exit it journals the Result, `accepted{id}` or
  `adapter_error{id}`. A command lost to a crash between save and send has no
  `sent` entry; a Runner that dies while a synchronous adapter runs leaves an
  orphaned adapter whose Result is lost, and a `sent` entry with no outcome.
  The environment detects these from the journal (never sent, process gone,
  or alive past a per-port `maxRuntime`: "hung?"), so the core stays
  clock-free and never reads these entries.
- An `accepted` answer only means "no Result yet"; the Runner still sends the
  remaining commands. An adapter crash is journaled, the remaining commands are
  still sent, and no signal is applied.
- The core never checks the outside world; the environment guarantees a signal arrives
  or someone sends `stop`.

Exact types are settled in implementation planning.

## Delivery lifecycle

```mermaid
stateDiagram-v2
  [*] --> Setup
  Setup --> Define
  Define --> AcceptGate
  AcceptGate --> Implement: accepted
  AcceptGate --> Define: adjust
  Implement --> Check
  Check --> Implement: fix (≤ N rounds)
  Check --> DecisionGate: decide / N rounds used
  Check --> LandGate: pass
  DecisionGate --> Implement: fix / keep going
  DecisionGate --> LandGate: accept
  LandGate --> Integrate: approved
  LandGate --> Implement: reject, rework
  LandGate --> Define: reject, re-scope
  Integrate --> Deploy: landed
  Integrate --> Implement: fix (red CI) / rework (conflict)
  Integrate --> DecisionGate: fix, N rounds used
  Deploy --> Verify: live
  Verify --> Close: pass
  Deploy --> FailureGate: not live
  Verify --> FailureGate: fail
  FailureGate --> Implement: fix forward
  FailureGate --> Close: accept
  Close --> Teardown
  Teardown --> Closed
  Closed --> [*]
  Blocked
  note left of Blocked
    from any step or gate: failed past cap;
    retry → that step; stop → Abandoned
  end note
  Abandoned --> [*]

  note right of Define
    every step: command → wait → signal;
    failed past retry cap → Blocked
    (Principal: retry re-issues the step);
    stop{outcome, reason} → Abandoned from any
    non-terminal state;
    workItem_changed before Land → AcceptGate
  end note
```

### Off the happy path

| State | Entered when | Leaves by |
|---|---|---|
| waiting (flag on a step) | a command is outstanding | its signal |
| Blocked | a step stays `failed` past its retry cap | Principal signal `retry` (re-issue the step) or `stop` |
| Abandoned (terminal) | `stop{outcome, reason}` from any non-terminal state | — |
| Closed (terminal) | Teardown finishes | — |

- `stop{outcome, reason}`: `outcome` is a typed enum (`rolled_back`,
  `abandoned`, extendable in config) that drives the Tracker mapping; `reason` is
  free text for the journal and for people. The core never parses `reason`.
- A failed deploy (`ok{verdict: not_live}`) goes to the Failure gate, not Blocked:
  the main line has already changed, so the Principal decides.
- **Workspace:** `setup` runs first; `teardown` runs after Close. On Abandoned
  the workspace is kept for inspection.
- An Integrate conflict comes back as a `question` to the Principal.
- **The WorkItem changed** (`workItem_changed` signal, detected by the environment,
  which calls `changed <delivery>`; the Runner re-reads the WorkItem from the Tracker):
  before the Land gate → back to the Accept gate showing the change; at Land or
  later → journal it and notify the Principal, flow unchanged.
- **Rollback is not a core concern.** The environment (or the Principal) rolls back and
  signals the core — `stop{outcome, reason}` or whatever the setup needs.
- **Outcome.** Outcomes the core reaches on its own path are derived from it
  (Verify pass → `delivered`; Failure gate accept → `accepted_with_failure`).
  Outcomes decided outside arrive typed in `stop{outcome}`. The Tracker is
  updated per outcome from config:

| Outcome | Tracker (example config) |
|---|---|
| `delivered` | WorkItem → Done |
| `accepted_with_failure` | Done + comment |
| `rolled_back` | WorkItem reopened |
| `abandoned` | unchanged + comment with reason |

### Edge cases

| State | Signal | Core does |
|---|---|---|
| Integrate | conflict (`question`) | answer "resolved" → re-issue Integrate; "rework" → Implement |
| Blocked | on entry | issue Principal `decide{retry \| stop}`, giving `retry` an id |
| Blocked | Principal adapter `failed` | stay Blocked, issue nothing; the environment alerts; only a Delivery signal moves it |
| Define | `workItem_changed` | cancel Define, re-issue it with the new WorkItem |
| any gate | answer outside the allowed options | re-ask: re-issue the gate with a new id; invalid answer journaled |
| any gate | Principal adapter `failed` | re-issue up to the gate's retry cap, then Blocked |
| any gate | Principal asks back | out of scope in v1; the adapter handles it, or the Principal answers "adjust" with a comment |
| Decision gate | "keep going" | fix-round counter resets |
| Closed / Abandoned | any signal | ignored, journaled |

**`next`** asks the Tracker for the next ready WorkItem (`tracker.next`) and then
follows the same rule as `start`.

**Starting a Delivery.** `start <workItem>` is handled before any Delivery
exists: it is rejected (journaled, no commands) if the WorkItem already has a
non-terminal Delivery; otherwise it creates Delivery `<key>-<attempt>`, where
attempt is the number of that WorkItem's earlier Deliveries in State plus one.

### Gates

| Gate | Decides | Minimum Principal (v1 default) |
|---|---|---|
| Accept | acceptance criteria + runbook | person |
| Decision | findings from the change check (scope, advisories) | person for scope, model for advisories |
| Land | integrate onto the main line (may deploy) | person |
| Failure | release check or deploy failed: fix forward, or accept | person |

**Questions from steps** are not gates: a step raises `question{prompt, about, options?}`,
the core routes it to the Principal with its context (P9) and sends the answer
back to the step. The Minimum Principal comes from config per `about`, e.g.
model for `clarify`, person for `login` or `conflict`; an unknown `about` gets
person.

Minimum Principal per gate (and per decision kind: `scope`, `advisory`) is
configurable; the long-term aim is model Principals for all gates. A gate's
options are core constants, because the core branches on them.

## Waiting and waking

```mermaid
sequenceDiagram
  participant Core
  participant Run as Runner
  participant St as State adapter
  participant Pr as Principal adapter
  participant Env as Environment (bot, webhook, CI)

  Core-->>Run: new state (awaiting land-1) + command{id: land-1, decide}
  Run->>St: save (waiting on land-1)
  Run->>Pr: decide(gate, options, evidence)
  Run->>St: journal sent{land-1, pid, host, started}
  Pr-->>Run: accepted
  Run->>St: journal accepted{land-1}
  Run->>Run: exit
  Note over Env: hours later, the reply arrives
  Env->>Run: ship signal (delivery, land-1, approve)
  Run->>St: load
  Run->>Core: apply signal
  Core-->>Run: new state + next commands
  Run->>St: save, then execute the next commands
```

The same shape covers every wait: a Principal's answer, a finished agent step,
a CI run, a merged pull request, a manual homelab deploy confirmed by reply.

If the Runner dies after the save but before the send, `land-1` is awaited but
has no `sent` entry. If it dies while a synchronous adapter runs, the adapter
is orphaned: it keeps running, and its Result is lost when it exits. The stall
check counts the process alive only while its pid's start time still matches
`started`; it flags the command once the process is gone with no Result,
`accepted` or `adapter_error`, or as "hung?" while it runs past its port's
`maxRuntime` (the environment's config and clock). A `sent` entry from another
host is flagged as "unknown host", never skipped. A person sends the Result by
hand or sends `stop`, and may terminate the orphan by its `(pid, started)`
pair. An `accepted` command is not pid-checked: its work continues
elsewhere. The one remaining window, a crash between process start and the
`sent` write, is rare and flagged as never sent, so it errs towards alerting.

## State

The State port stores a **snapshot** (current state of the Delivery — the source
of truth) and an **append-only journal** (every step result and every decision
with the kind of Principal who made it, plus the Runner's `sent`, `accepted` and
`adapter_error` entries — audit only, never replayed). Ops: `load`, `save`
(compare-and-swap on version), `list{key?}` (a WorkItem's Deliveries, or all),
`journal`.

**Status.** `status [<delivery>]` is read-only: it lists the non-terminal
Deliveries (or one) as `{deliveries: [{delivery, at, awaiting}]}`, where `at`
is the Delivery's position. It never calls the core.

## Configuration

| Layer | Holds |
|---|---|
| Project (in the repo) | adapter per port, minimum Principal per gate and per decision kind (incl. question `about`) and for Blocked, Tracker status per step and outcome, retry cap per step and gate, fix-round limit N |
| Machine (outside the repo) | Principal channel, State adapter, secrets, capability profile per port |

Gate options are core constants, not config. Listeners (bot, webhook, cron)
are not configured in ship: the environment runs them (P6).

## Checks

| Check | Step | Proves |
|---|---|---|
| Change check | Check | the changeset meets the acceptance criteria before it lands |
| Release check | Verify | the end-user outcome in production — e2e (often browser-driven) and side effects (e.g. an email delivered and correct), following the runbook |

The runbook is drafted in Define from the acceptance criteria, before any code,
and accepted at the same gate.

## Decided

Rationale for the hard-to-reverse choices lives in [`adr/`](adr/):
executable adapters (0001), signal-driven core (0002), core-owned gates (0003),
the environment owns delivery, time and rollback (0004), snapshot + journal (0005).

| Decision | Choice |
|---|---|
| Architecture | ports and adapters; executable adapters with JSON contracts |
| Stack | Bun + TypeScript + ajv |
| Parallelism | multiple core invocations, each in its own workspace (e.g. a git worktree) provided by the Workspace port |
| Retries | the core re-issues a `failed` command up to a per-step or per-gate cap, immediately; delays and backoff are the environment's |
| Input | `start <workItem>`, `next`, `signal <delivery> <id> <result>`, `stop <delivery> <outcome> <reason>`, `changed <delivery>`; read-only `status [<delivery>]` |
| State | snapshot + journal |
| Identity | Tracker adapter returns a stable, slug-safe WorkItem key; Delivery = `<key>-<attempt>` (e.g. `PROJ-123-2`); command id = `<delivery>/<step>-<n>` (e.g. `PROJ-123-2/land-1`) |
| Location | `ship/` bundle in harlo |

## Open

- Nothing open at architecture level. Implementation plan: [`plan.md`](plan.md).
