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

Run it from anywhere inside a set-up repo (one `env/setup.ts` wrote):

```bash
bun <ship>/env/queue.ts [--repo <path>] [--interval <ms>] [--grace <ms>] \
  [--max-runtime <ms>] [--lock <path>]
```

- `--repo <path>` — the repo. Default: the cwd's git root. `ship` and the
  pollers run with the repo root as their working directory (`ship` reads
  `ship.config.json` from there), so the queue works from anywhere.
- `--interval <ms>` — sleep between passes while a Delivery runs. Default 5000.
- `--grace <ms>`, `--max-runtime <ms>` — forwarded to `poll/stalled.ts` only
  when given.
- `--lock <path>` — the lockfile. Default `.ship-queue.lock` in the repo root.

The State adapter is the one ship uses: `<repo>/ship.config.json` →
`projectId` → `$SHIP_MACHINE_CONFIG`, else `~/.config/ship/<projectId>.json`
→ `state`. A missing or invalid file exits 1, naming the file and suggesting
`bun <ship>/env/setup.ts`. `bin/ship` is this checkout's.

### Overrides (optional)

- `--ship <path>` — another `bin/ship`.
- `--state <state-adapter argv…>` — another State adapter's spawn argv. It
  takes **the rest of argv**, so every other flag must come before it (same
  gotcha as [`judge.md`](judge.md)).

Given both and no `--repo`, nothing is resolved: every call runs in the
working directory and the lock defaults to `.ship-queue.lock` there.

Each finished Delivery prints one line, `<delivery>: done at=<closed|abandoned>`,
after its progress lines.

## Exit codes

| Exit | Meaning |
|---|---|
| 0 | drained: `ship next` returned `delivery: null` |
| 1 | a `ship next` / `ship status` call failed (stderr has ship's stderr, and names the Delivery when `ship` printed one, e.g. on exit 5), the re-pick guard's own `ship stop` failed, or the repo/config cannot be resolved |
| 2 | the lockfile already exists: another queue holds it |
| 3 | re-pick guard fired (see below) |

## The lock

One queue per project. On start the queue creates the lockfile atomically
(fails if it exists) and writes a per-run token into it: its pid plus a random
id. It removes it on every exit (drain, errors, exit 3, SIGINT, SIGTERM, SIGHUP)
except SIGKILL, but only if the file still holds that token: a lock another queue took after this one's
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

## Stall recovery

Each pass also runs `poll/stalled.ts` (the same check `env/drive.ts` prints
for a human). If it flags the current Delivery's awaited step **"dead"**
(its process is gone and no `result`/`accepted`/`adapter_error` entry was
ever journaled for it), the queue stops that Delivery as abandoned right
away:

```bash
ship stop <delivery> abandoned "<awaiting id>: dead (stalled, no outcome entry)"
```

then moves on to the next one, the same as any other `closed`/`abandoned`
Delivery. Unlike the re-pick guard, this is not an error: the queue exits 0
normally once the tracker drains.

Other stall flags ("never sent", "hung?", "unknown host") only print, as
before — they are not an unambiguous crash, so the queue leaves them for a
human to judge (`env/drive.ts`, or reading the printed flag).

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
