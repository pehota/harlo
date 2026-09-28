# Writing a ship adapter

An adapter is one executable. It serves one or more ports. The Runner spawns
it once per command, feeds it JSON on stdin, and reads one JSON line from
stdout. Types: [`plan.md`](plan.md) §3.1–§3.2, schemas in
[`../src/contracts/`](../src/contracts/). Terms: [`../CONTEXT.md`](../CONTEXT.md).

## The contract

| Channel | What |
|---|---|
| **argv** | `<config argv…> <port> <op>`. The config gives the prefix; the Runner appends port and op. |
| **stdin** | One `Stdin` JSON object (below). |
| **stdout** | One JSON line: a Result, or `{"status":"accepted"}`. |
| **stderr** | Your logs. The Runner keeps the last 2 KB and journals it on a crash. |
| **exit** | `0` whenever you printed a valid reply. Anything else is a crash. |
| **env** | Only `PATH`, `HOME` and your port's capability-profile `env` (secrets resolved). Nothing else is inherited. |

```ts
type Stdin = {
  id: CommandId | null;        // "<delivery>/<name>-<n>"; null on every Runner-only call
  delivery: DeliveryId | null; // "<key>-<attempt>"
  port: Port; op: string;
  workItem: WorkItem | null;
  workspace: string | null;    // the Workspace path, once Setup returned it
  payload: unknown;            // per port/op (plan §3.2)
  tools: string[];             // capability profile tools; secrets come only through env
};
```

**Core commands** always carry `id`, `delivery` and `workItem`.
**Runner-only calls** (`tracker.read`, `tracker.next`, `state.*`) are the Runner's own
reads and writes, not core commands:

| Runner-only call | `id` | `delivery` | `workItem` |
|---|---|---|---|
| `state.load`, `state.save`, `state.journal` | null | set | null |
| `tracker.read` from `ship changed` | null | set | null |
| `tracker.read` from `start` / `next` | null | null | null |
| `tracker.next`, `state.list` | null | null | null |

## Replies

| status | Meaning | Who may print it |
|---|---|---|
| `ok{body, evidence?}` | done; `body` per port/op | every port |
| `failed{info}` | **could not run and changed nothing** | every port |
| `question{prompt, about, options?, evidence?}` | need an answer from the Principal first | **step ports only** (define, implement, check, integrate, deploy, verify) |
| `accepted` | the Result comes later, through `ship signal` | core commands only, never Runner-only calls |

- A red verdict is an `ok`: `{"status":"ok","body":{"verdict":"fix","findings":[…]}}`.
- `accepted` means only "no Result yet". Someone (you, a bot, CI, a person)
  later runs `ship signal <delivery> <id> '<result-json>'` with the same `id`.
- `evidence` is passed to the Principal as is. The core never reads it.

## What the Runner makes of it

| Adapter behaviour | Runner turns it into |
|---|---|
| exit 0, `{"status":"accepted"}` | waiting (journaled `accepted`) |
| exit 0, a valid Result (incl. an explicit `failed`) | that Result, fed to the core as a signal |
| exit 0, invalid JSON, or fails the port/op schema (e.g. a `question` from a service port) | `adapter_error`, no signal; remaining commands run, then exit 5 |
| exit ≠ 0 | `adapter_error`, no signal; remaining commands run, then exit 5 |
| spawn error (executable not found) | `failed{info}` — it provably ran nothing |

Fire commands (notify, comment, `cancel`, tracker.update outside Close): stdout
is ignored. A non-zero exit shows up in the CLI output's `errors`; nothing else
changes.

## Crash vs `failed`

**Catch your own errors.** Print `failed` only when you changed nothing.
Otherwise report through `ok` or `question`.

- `failed` → the core re-issues the command (new id), up to the retry cap, then
  Blocked. Safe only because nothing happened.
- A crash may follow a side effect, so the core never re-issues it. It is
  journaled; the environment or a person resolves it with `ship signal` or
  `ship stop`.

## `cancel{target}`

Every adapter must accept op `cancel` with payload `{"target": "<command id>"}`.

- It is sent to the port that ran the target, when a Delivery signal made that
  command moot (`stop`; a WorkItem change sending it back to Accept; or a
  WorkItem change at Define, which cancels Define and re-runs it).
- Stop the target's work if it is still running.
- **Nothing to cancel → exit 0** (print `{"status":"ok","body":{}}`). A finished,
  unknown or synchronous target is not an error.
- An orphaned target process may be killed by the `(pid, started)` pair from its
  `sent` journal entry, only while the pid's start time still equals `started`.

## Idempotency on the command id

- The `id` names one instance of one step or gate. The core never reuses it: a
  retry or re-ask gets a new id.
- If the same `id` reaches you again (a person re-ran a command by hand), treat
  it as the same command: reuse what the first call made (e.g. an existing pull
  request) and do not repeat side effects.
- Put the `id` wherever an external system lets you tag work (branch, PR, message),
  so a later `ship signal` can carry it back.
