# queue

The environment-owned loop that drains the tracker, one Delivery at a time.
`ship next` picks the next `ready` WorkItem and starts its Delivery; the queue
drives that Delivery until it is `closed` or `abandoned`, then picks the next
one, until the tracker has nothing left.

## What it is and isn't

- It is environment code, `ship/env/queue.ts`: the "cron or loop" around
  `ship next` that plan.md §7 leaves to the environment. It runs the same
  per-pass loop as `env/drive.ts` (`env/drive-loop.ts`: `poll/changed.ts`,
  `poll/stalled.ts`, `ship status <delivery>`) for each Delivery it starts.
- It is **not** part of `ship`. `ship` never invokes it and ships no daemon.
- It **never answers a gate**. A person (or the configured Principal adapter)
  does; the queue waits meanwhile, like `env/drive.ts`.
- It **makes no decision about outcomes**. `closed` and `abandoned` both mean
  "move on": an abandoned item is already marked by the tracker mapping
  (its stop reason is a tracker comment — a config rule requires
  `comment: true` on every stop outcome).
- It runs **one Delivery at a time**. There is no `--concurrency` flag, on
  purpose: parallel Deliveries are discovery issue pehota/harlo#50.

## Base command

Run it from the project directory (where `ship.config.json` is):

```bash
bun env/queue.ts --ship <path to bin/ship> [--interval <ms>] [--grace <ms>] \
  [--max-runtime <ms>] [--lock <path>] --state <state-adapter argv…>
```

- `--ship <path>` — the `bin/ship` to call. Required.
- `--state <state-adapter argv…>` — the state adapter's own spawn argv, passed
  to `poll/stalled.ts`. Required. It takes **the rest of argv**, so every other
  flag must come before it (same gotcha as [`judge.md`](judge.md)).
- `--interval <ms>` — sleep between passes while a Delivery runs. Default 5000.
- `--grace <ms>`, `--max-runtime <ms>` — forwarded to `poll/stalled.ts` only
  when given.
- `--lock <path>` — the lockfile. Default `.ship-queue.lock` in the working
  directory.

Example, against the dogfood state:

```bash
bun env/queue.ts --ship bin/ship \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state
```

Each finished Delivery prints one line, `<delivery>: done at=<closed|abandoned>`,
after its progress lines.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | drained: `ship next` returned `delivery: null` |
| 1 | a `ship next` / `ship status` call failed (stderr has its output, and names the Delivery when `ship` printed one, e.g. on exit 5), the re-pick guard's own `ship stop` failed, or bad usage |
| 2 | the lockfile already exists: another queue holds it |
| 3 | re-pick guard fired (see below) |

## The lock

One queue per project. On start the queue creates the lockfile atomically
(fails if it exists) and writes a per-run token into it: its pid plus a random
id. It removes it on drain, on error and on SIGINT, SIGTERM or SIGHUP, but only
if the file still holds that token: a lock another queue took after this one's
was deleted as stale is left alone.

If the lockfile exists, the queue exits 2 with
`lock <path> exists: another queue holds it; delete it if stale`, and starts
nothing. A queue killed with SIGKILL leaves a stale lock; check the pid in it,
then delete the file by hand. The queue never guesses.

To stop a running queue, signal its **process group** (e.g. Ctrl-C at its
terminal, or `kill -TERM -<pgid>`), not just its pid. A signal sent only to the
queue's pid releases the lock at once while a running `ship` child can still be
finishing its apply — a new queue could then start alongside it.

## Orphans first

Before the first `ship next`, the queue runs `ship status` (no argument) and
drives every already-open Delivery to terminal — e.g. one left by an earlier,
interrupted run. Only then does it pick new work, so it never runs a second
Delivery alongside an open one.

## The re-pick guard

A WorkItem whose status never leaves `ready` would be picked forever. That
happens when no `policy.tracker.steps` entry moves it on start, and its outcome
mapping sets no status (e.g. `abandoned: { comment: true }` only).

The queue remembers every key it drove during the run. If `ship next` starts a
Delivery for a key it already handled, it stops that new Delivery:

```bash
ship stop <key>-<n> abandoned "<key> still ready after its Delivery ended: check policy.tracker.steps/outcomes"
```

prints the same reason on stderr and exits 3. The guard fires only after the
second `ship next` has already started a Delivery, so the policy must move
items out of `ready` early (e.g. `tracker.steps.define`). If that `ship stop` itself fails
(e.g. `abandoned` is not in `policy.outcomes`), stderr says the Delivery stays
open and the queue exits 1. Fix the config (e.g. give
`tracker.steps.define` an in-progress status), then fix the item's status by
hand.
