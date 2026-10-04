# judge

A read-only dev/debugging tool for a human to judge whether a step's real
output was actually good (e.g. tuning an adapter's prompt or model choice).
It renders a Delivery's real journal history: what each step-call was asked
(INPUT), what it returned (OUTPUT), and its reasoning when the adapter
populates it (REASONING).

## What it is and isn't

- It is a one-shot script, `ship/env/judge.ts`, for a human reading the
  journal. No gating, no verdict of its own — it only renders what already
  happened.
- It is **not** part of the shipped runtime. `ship` itself never invokes it,
  and it isn't part of any Delivery flow (Define/Implement/Check/Integrate/
  Deploy/Verify). It's a dev tool, run by hand, against a Delivery's journal.

## Base command

Run it from anywhere inside a set-up repo (one `env/setup.ts` wrote):

```bash
bun env/judge.ts [--repo <path>] [<delivery>] [--step <name>] [--root <main-line repo>]
```

- No `<delivery>` — lists every Delivery the repo's State holds, closed and
  abandoned included, most recent first, one line each: id, position (`at`),
  outcome when set, and `last` (the time of its latest journal entry). An
  empty State prints `no Deliveries`. Exit 0.
- `<delivery>` — the Delivery whose journal to render (`--delivery <id>`
  still works).
- `--repo <path>` — the repo. Default: the cwd's git root. Its State adapter
  is the one ship uses: `<repo>/ship.config.json` → `projectId` →
  `$SHIP_MACHINE_CONFIG`, else `~/.config/ship/<projectId>.json` → `state`.
  A missing or invalid file exits 1, naming the file and suggesting
  `bun <ship>/env/setup.ts`.
- `--root <main-line repo>` — the main-line repo sharing an object store with
  the Delivery's worktree. Default: the repo's git root. Implement's
  changeset is also shown as `git show <sha>` (best-effort: a torn-down
  worktree/branch's commit may be unreachable, in which case judge prints
  `commit not reachable (worktree/branch likely torn down)` instead).
- `--step <name>` — optional. Filter to one step's calls (e.g. `define`,
  `implement`, `check`). Omitted shows the whole journal, in chronological
  order.

Example, from the repo of the dogfood delivery `freetext-signal-1`:

```bash
bun env/judge.ts                      # which Deliveries are there?
bun env/judge.ts freetext-signal-1    # render one
```

## Override: `--state`

`--state <state-adapter argv…>` reads that State adapter instead of the
repo's config: no config lookup, and no default `--root` unless `--repo` is
given. Optional; for a State that no repo config names.

```bash
bun env/judge.ts freetext-signal-1 \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state
```

`--state` takes **the rest of argv** (same convention as `env/poll/stalled.ts`).
Any other flag — `--root`, `--step` — must come **before** `--state`. Put it
after, and it silently gets swallowed into the state adapter's own argv
instead of judge's, and the state adapter rejects it.

**Wrong** — `--step` lands after `--state`, gets passed to the state adapter,
and fails:

```bash
bun env/judge.ts freetext-signal-1 \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state \
  --step define
# error: state journal freetext-signal-1: unsupported: --step define
```

**Right** — `--step` before `--state`:

```bash
bun env/judge.ts freetext-signal-1 --step define \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state
```

## `--step` filtering

`--step <name>` shows one step's calls across **all** sequences/rounds — e.g.
both `define-1` and `define-2` after a fix-round rerun. Omitted, judge shows
the whole journal.

```bash
bun env/judge.ts freetext-signal-1 --step define
```

On `freetext-signal-1` this prints every `define-N` block in order:
`define-1`, `define-2`, `define-3`, `define-4` (each a separate call across
retries and an intervening clarifying question).

## "What ACs did Define actually generate?"

Run with `--step define`. The **last** `define-N` block's OUTPUT (Criteria /
Runbook) is the one Implement actually worked from — earlier `define-N`
blocks are prior rounds or retries, not the final ACs.

On `freetext-signal-1`, that's `define-4`'s OUTPUT (`define-1`/`define-2`
failed with "Not logged in", and `define-3` asked a clarifying question
instead of producing criteria — only `define-4` produced the Criteria/Runbook
Implement used).

## "How did Define react to an advisor's reply?"

Two cases, depending on when the delivery ran.

**Today, for an older delivery** (one that predates the payload/evidence
journaling): run judge unfiltered and manually find the triplet in the
output:

1. The `question (...)` OUTPUT of a `define-N` (or other step) block.
2. The very next `ask-N` block's OUTPUT — the literal reply text.
3. The next `define-N` block's OUTPUT — what Define produced after reading
   that reply.

Concrete example from `freetext-signal-1` (unfiltered run):

- `define-3` OUTPUT: `question (clarify): Design decision to confirm
  first: the free-text reply converter should be a new one-shot script...`
- `ask-1` OUTPUT (the very next block): the literal free-text reply —
  `"Yes to routing the Principal output to a file: ..."`
- `define-4` OUTPUT (the next block): the Criteria/Runbook Define produced
  after reading that reply.

**Going forward, for a delivery run after the payload/evidence journaling
landed**: the next `define-N`'s own INPUT section shows the actual payload it
received directly — no manual reconstruction needed.

## Empty INPUT/REASONING is expected, not a bug

For an older delivery (one recorded before the `payload` field or the
`evidence` population landed):

- INPUT can read
  ```
  (no payload recorded: this `sent` entry predates the `payload` field)
  ```
- There may be no REASONING section at all.

Both are expected for older deliveries — not a bug in judge. Every call in
`freetext-signal-1`, for example, shows the "no payload recorded" INPUT line,
because that delivery predates the `payload` field.

## USAGE and the Delivery total

Each step-call also gets a USAGE section: input, output, cache-read and
cache-write tokens, cost in USD, duration and turns, as the agent adapter
reported them for that call alone (`src/adapters/agent/claude/index.ts`
records a resumed session's cost as the difference from the session total).
It is shown for ok, question and failed results, and for crashed calls: those
have no `result` entry, so judge lists their `adapter_error` entry and reads
the `ship-usage: {json}` line the adapter wrote as the last line of stderr.
A call with no usage data (a gate's answer, a non-agent step, an older
delivery) shows `(none)`.

After the per-call blocks, `=== TOTAL <delivery> ===` sums each figure over
every call with usage, whatever its outcome, and says how many calls had no
usage data. With `--step`, the total covers only the filtered calls.
