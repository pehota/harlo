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

```bash
bun env/judge.ts --delivery <id> --state <state-adapter argv…> [--root <main-line repo>] [--step <name>]
```

- `--delivery <id>` — the Delivery whose journal to walk. Required.
- `--state <state-adapter argv…>` — the state adapter to read the journal
  from, e.g. `bun src/adapters/state/files.ts --dir <state dir>`. Required.
  `--state` takes **the rest of argv** — see the gotcha below.
- `--root <main-line repo>` — optional. The main-line repo sharing an object
  store with the Delivery's worktree. When given, Implement's changeset is
  also shown as `git show <sha>` (best-effort: a torn-down worktree/branch's
  commit may be unreachable, in which case judge prints
  `commit not reachable (worktree/branch likely torn down)` instead).
- `--step <name>` — optional. Filter to one step's calls (e.g. `define`,
  `implement`, `check`). Omitted shows the whole journal, in chronological
  order.

Example, against the dogfood delivery `freetext-signal-1`:

```bash
bun env/judge.ts \
  --delivery freetext-signal-1 \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state
```

## The `--state` gotcha

`--state` takes **the rest of argv** (same convention as `env/poll/stalled.ts`).
Any other flag — `--root`, `--step` — must come **before** `--state`. Put it
after, and it silently gets swallowed into the state adapter's own argv
instead of judge's, and the state adapter rejects it.

**Wrong** — `--step` lands after `--state`, gets passed to the state adapter,
and fails:

```bash
bun env/judge.ts --delivery freetext-signal-1 \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state \
  --step define
# error: state journal freetext-signal-1: unsupported: --step define
```

**Right** — `--step` before `--state`:

```bash
bun env/judge.ts --delivery freetext-signal-1 --step define \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state
```

## `--step` filtering

`--step <name>` shows one step's calls across **all** sequences/rounds — e.g.
both `define-1` and `define-2` after a fix-round rerun. Omitted, judge shows
the whole journal.

```bash
bun env/judge.ts --delivery freetext-signal-1 --step define \
  --state bun src/adapters/state/files.ts --dir ~/.local/state/ship/dogfood/state
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
