# Implement DoD Harness v2

## Context

The `dod/` plugin fails at its job: it doesn't reliably guide the coding agent to
verify work before claiming done. Rather than patch it, we ran a full requirements
interview and produced a clean-sheet design — `docs/design-v2.md`, committed in
`cc55759`, 27 decisions each recorded with its rejected alternative.

**This plan implements that design.** The design is settled; nothing here re-opens it.
What remains is sequencing, reuse decisions, and two amendments the codebase forced.

Intended outcome: `/dod:define` writes a contract of typed requirements before code
is written; a `Stop` hook gates the done-claim; `/dod:verify` runs the checks and a
fresh-context reviewer; failures loop twice, then escalate.

**Scope:** `dod/` only. `completion-harness/` is a separate plugin with its own
version, docs and tests — untouched, and its fate decided after v2 is proven.

---

## Amendments to `docs/design-v2.md`

Two changes, agreed after exploring the codebase. Both must be written into the doc
as part of Phase 1 so doc and code stay in sync.

### A1 — Block form: JSON, not `exit 2`

§6.2 says block = `exit 2` + stderr. **Change to** `{"decision":"block","reason":"…"}`
on stdout + `exit 0`.

Why: it is the repo's existing convention (`dod/scripts/dod-gate.sh:145-161`), and
that file's header gives the reason — `exit 2` renders in the transcript as a hook
*error*, which is wrong for a deliberate gate decision. Harness errors keep `exit 1`,
so the two stay visibly distinct.

Revised exit contract:

```
stdout {"decision":"block","reason":"…"} + exit 0  → block  (verification failure)
silent + exit 0                                    → release (normal)
stderr one line + exit 1                           → release (harness error, noisy)
```

Consequence for tests: assert on parsed JSON (`jq -e '.decision == "block"'`), and
assert *release* as empty stdout — the existing suites' idiom.

### A2 — Category-scoped recursion brake

§5.1 releases whenever `stop_hook_active` is true. The existing gate is smarter
(`dod-gate.sh:145-163`): it records the *category* of the last block and releases only
when `stop_hook_active` is true **and** the category is unchanged. A block for a
*different* reason still blocks.

Adopt it. Without it, one spurious `stop_hook_active` releases the gate entirely; with
it, only a genuinely stuck loop releases.

---

## Phase 0 — Wipe and tag

1. Delete `dod/scripts/`, `dod/hooks/`, `dod/skills/`, `dod/agents/`, `dod/contracts/`,
   `dod/tests/`, `dod/docs/base-dod.md`, `dod/README.md`.
2. Keep `dod/.claude-plugin/plugin.json` (version continuity — the pre-push hook
   depends on it) and the `dod` entry in `.claude-plugin/marketplace.json`.
3. Commit `refactor(dod)!: wipe the v1 implementation ahead of the v2 rewrite`,
   then tag it `dod-v1-final` so every deleted line stays recoverable.

`run-tests.sh` globs `dod/tests/test-*.sh`, so an empty `dod/tests/` leaves the root
suite green rather than broken.

---

## Phase 1 — Walking skeleton

**Definition of the skeleton:** `/dod:define` writes a contract with the detected test
command as its single `check`; the agent arms a claim; the gate blocks; `/dod:verify`
runs that check and writes a result; the gate releases.

**In:** contract/result/state libs, `gitref.sh`, `io.sh`, `gate.sh`, both skills, a
claim script, `hooks.json` with `Stop` only.

**Out (Phase 2):** `guard.sh` (later decided, never built — see item 3 below
and D12), `track.sh`, `session.sh`, the reviewer, baseline worktree, cache,
escalation, waivers, e2e requirement, expiry.

**Kept in, despite being "depth":** the claim latch. Deferring it would mean testing a
gate with different engagement semantics from the real one. The *abandonment guard*
(`edits_this_prompt`) defers with `track.sh`.

**Landed during Phase 1, not originally scoped — found by live testing, now
part of the skeleton's contract:**

- **D28 — self-verify instruction.** `/dod:define` and `/dod:verify` tell the
  agent to run `/dod:verify` itself the moment it believes a task is done,
  same turn, never asking the user or waiting for the gate to block first.
  The gate block is the fallback, not the intended trigger.
- **D29 — confirmation gate, reverses D4.** `/dod:define` prints a fixed
  Verification/Expected-Result/Why-This-Verification table and **blocks**
  (no edit, no baseline recording, no `contract_write`) until the user
  replies yes/adjust/cancel. Confirmation covers both "the list is right" and
  "start working" as one gate — the agent proceeds into implementation
  immediately on "yes," same turn, no second prompt.
- These are prose-only enforcement (skill instructions), not mechanism.
  **Stays prose-only** (see item 3 below, D12 revised in `docs/design-v2.md`):
  no `guard.sh` was ever built — a `PreToolUse` gate was considered twice and
  rejected both times, most recently in favor of the same self-invoke-first,
  human-fallback pattern D28 already uses for `/dod:verify`.

### Files

| File | Contents |
|---|---|
| `dod/lib/io.sh` | `dod_hook_read` (one `jq … \| @tsv`, not 8 forks), `dod_block`, `dod_release`, `dod_fail_open`, `dod_log` |
| `dod/lib/gitref.sh` | `dod_task_key`, `dod_diff_hash`, `dod_is_ancestor` |
| `dod/lib/contract.sh` | schema + `contract_read/write/validate` — **sole owner of contract.json** |
| `dod/lib/result.sh` | schema + `result_read/write/validate` |
| `dod/lib/state.sh` | schema + `state_read/write` + mutators (`state_arm_latch`, `state_bump_round`) |
| `dod/hooks/gate.sh` | decision tree, branches 0,1,2,3,5,7,8,10 |
| `dod/hooks/hooks.json` | `Stop` → `gate.sh`, timeout 10 |
| `dod/skills/dod-define/SKILL.md` | derive + `contract_write` |
| `dod/skills/dod-verify/SKILL.md` | run checks + `result_write` + print pass table |
| `dod/scripts/dod-claim.sh` | arms the latch |
| `dod/tests/test-helpers.sh` | ported `ok/bad/eq`, `make_repo`, `run_gate` |
| `dod/tests/test-{gate,contract,result,state,gitref}.sh` | one suite per unit |

### Ported functions

Wipe first, then deliberately re-introduce these five — **rewritten to the new
structure, not copy-pasted**. Originals recoverable at tag `dod-v1-final`.

| From | To | Change on the way |
|---|---|---|
| `harness-common.sh:182-200` `hc_read_hook_input` | `io.sh` `dod_hook_read` | collapse 8 `jq` forks into one |
| `harness-common.sh:426-432` + `:256-258` task key | `gitref.sh` `dod_task_key` | sanitise **once** inside the resolver (v1 re-sanitised at 3 call sites) |
| `lib-log.sh:48-85` `dod_log` | `io.sh` | verbatim — keep the "never writes stdout" invariant |
| `dod-gate.sh:145-163` `block`/`clear_last_block` | `gate.sh` | keep the category-scoped brake (A2) |
| `dod-verify-detect.sh:33-133` detection cascade | `dod:define` battery detector | Phase 2; drop the config read/write/upgrade half |

**Deliberately not ported:** `hc_validate` + `contracts/*.schema.json` (external schema
files contradict N6 — validation lives inside each lib), the commit-ledger machinery
(~280 lines, already dead in `dod/`), `dod-verify-triage.sh` (it *is* the old 10-step
gate design).

### Sequence (TDD on libs + gate; skills verified by exercising the flow)

1. `test-helpers.sh` — ported, no assertions of its own.
2. `gitref.sh` — tests first: task key from branch, sanitisation, diff hash stability
   (identical tree → identical hash; touched file → different hash), ancestor check.
3. `contract.sh` / `result.sh` / `state.sh` — tests first, each covering: write→read
   round-trip, malformed input rejected, **and the N6 invariant** (a requirement that is
   neither `check` nor `judgement` is rejected).
4. `io.sh` — tests first: `dod_hook_read` parses a payload and degrades to defaults
   without jq; `dod_block` emits exactly one JSON object; `dod_log` writes nothing to
   stdout.
5. `gate.sh` — tests first, **one case per branch**, asserting block-vs-release and the
   reason text, following the v1 suites' `is_block` / empty-stdout idiom.
6. Skills + `dod-claim.sh` — written against the now-green libs.
7. `hooks.json`, then end-to-end by hand.

### Bash conventions (from the existing code — follow strictly)

- `#!/bin/bash`, **no `set -e`, no `set -u`, no pipefail** in hooks and libs; guard every
  `git`/`jq` call individually. (Root-level CLI scripts may use `set -u`.)
- `dod_*` public, `dod__*` private, `SCREAMING_SNAKE` globals.
- `PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"`;
  sourced libs locate themselves via `BASH_SOURCE[0]`.
- Guarded sourcing + a no-op stub if a lib is missing, so absence never changes behaviour.
- `jq` always `2>/dev/null`; construct with `jq -n --arg`, never string interpolation;
  validate numerics with a `case` glob before comparing.
- Every file opens with a header block stating purpose, contract, exit codes, and *why* —
  including rejected alternatives.

---

## Phase 2 — Depth (after the skeleton runs end-to-end)

Ordered by what most reduces risk:

1. `track.sh` + abandonment guard — completes the claim rule.
2. `dod-reviewer` agent + the `judgement` path — the gate the design exists for.
3. ~~`guard.sh` — contract-before-first-edit.~~ **Resolved, not built** — D12
   revised (`docs/design-v2.md`). Live-tested 2026-09-17: a `PreToolUse`
   guard was considered twice and rejected both times — first as
   unenforceable (no non-heuristic "implementation started" signal exists
   without either denying every edit unconditionally or D2's already-deferred
   content/path heuristics), then, after a live test showed the agent
   skipping `/dod:define` for a whole task, rejected again on a simpler
   ground: the fix is the same self-invoke-first/human-fallback pattern D28
   already uses for `/dod:verify`, not a hard lock on `Edit`/`Write`.
   Numbering below is unchanged so history stays legible; treat this slot as
   permanently skipped, not "next."
4. ~~Escalation: branches 4, 6, 9 + the two-step release.~~ **Done** —
   branches 6 and 9 shipped (`dod/hooks/gate.sh`, D21 two-step release, D26
   budget=2 + no-progress brake). Branch 4 (baseline-not-ancestor expiry)
   also shipped, live-tested 2026-09-18: `dod_is_ancestor` wired into
   `gate.sh` right after the status check, sets `contract.status :=
   "expired"` and tears down the baseline worktree. **Scope note found by
   the same live test:** branch 4 only fires when history is *rewritten*
   under the baseline (rebase, force-push, `commit --amend`) — a
   killed/crashed session with an untouched baseline is a still-ancestor,
   perfectly valid SHA, so branch 4 never fires for it and the contract
   stays `open` forever. That is a separate, still-undesigned mechanism (no
   TTL / no-session-liveness-check exists), deliberately left open —
   not part of this item's scope.
   **Hardened 2026-09-18** (found by `completion-harness:dod-reviewer` on
   commit ea6bcaa): `dod_is_ancestor`'s boolean contract collapsed `git
   merge-base --is-ancestor`'s exit 1 ("confirmed not an ancestor") and any
   other non-zero exit (typically 128 — a bad/unresolvable SHA, a shallow
   clone missing the needed history, a transient git I/O error) into the
   same "non-zero" bucket, so `gate.sh` branch 4 silently expired a
   perfectly good open contract on a harness failure with no error logged
   (violating §7.4's fail-open discipline). Fixed by adding
   `dod_is_ancestor_status` (`dod/lib/gitref.sh`), which exposes the raw
   exit code; `gate.sh` now branches three ways — exit 1 expires, exit 0
   proceeds, anything else routes through `dod_fail_open` + `exit 1`,
   leaving `contract.json` untouched. Covered by
   `dod/tests/test-gitref.sh` (all three exit codes) and
   `dod/tests/test-gate.sh` (a malformed-SHA case proving the contract
   stays `open` and stderr carries `dod gate error`).
5. ~~Baseline worktree + pre-existing-failure resolution.~~ **Done** —
   `dod_baseline_worktree`/`dod_baseline_worktree_remove` (`dod/lib/gitref.sh`,
   D18), invoked lazily from `/dod:verify` step 4 on a failing check only,
   torn down by `gate.sh` on both terminal status transitions — branch 10
   (pass) and branch 6 (escalated); without the latter the worktree leaked
   forever once a task escalated, since branch 3 releases every later Stop
   before branch 6 runs again (found by review, fixed same session). Tracked
   by the worktree's own presence/sha on disk, not a `state.json` field (see
   design-v2.md §6.5).
6. ~~Cache on `(diff_hash, cmd)`.~~ **Done** — `state_cache_get`/
   `state_cache_set` (`dod/lib/state.sh`), keyed on a hash of the command so
   `:` in a command can't collide with the diff_hash delimiter, capped at 200
   entries. `/dod:verify` step 4 checks the cache before running a `check`
   requirement's command and records the verdict after a miss. No explicit
   invalidation: a changed diff already changes `diff_hash`, which misses
   the cache for free (§7.3 of the design doc).
7. ~~`session.sh` — preflight, cancel-on-clear, error banner.~~ **Done** —
   `dod/hooks/session.sh`, registered on both `SessionStart` and
   `SessionEnd` (one script, dispatching on `hook_event_name`; the two
   events never fire concurrently with each other so this doesn't hit the
   §4 "one event, one script" race). Preflight checks `git`/`jq`, gated by
   a marker file keyed to `plugin.json`'s version so it's paid once per
   version (N3). Cancel-on-clear fires on `SessionStart` with
   `source == "clear"`: an **open** contract on the current branch is set
   `cancelled` and its baseline worktree torn down; a contract already
   `passed`/`cancelled`/`escalated` is left alone. Error banner: a
   `systemMessage` naming the count of `.dod/errors.log` lines appended
   since the last acknowledged read (line-count marker, not content diff —
   simplest thing that satisfies "print once, don't nag forever"). Bare
   `SessionEnd` (e.g. closing the terminal, not `/clear`) is a no-op by
   design — the contract survives so resuming the same branch later finds
   it still open, per §7.1's "a `/clear` mid-task... cancels it" being
   specific to `/clear`, not every session end.
8. Waivers, e2e requirement, `/dod:cancel`, amend/`--new`:
   - ~~Waivers.~~ **Done** — `contract.sh`'s `--waivers`/`CONTRACT_WAIVERS`
     already existed but `contract_read` never set the latter (fixed).
     `/dod:define` step 3.5 extracts a waiver only from the user's own
     explicit words (never inferred from task size or shape) and shows it
     in the confirmation table as `WAIVED` with the user's reason verbatim.
     `/dod:verify` step 4 checks `CONTRACT_WAIVERS` before running a check's
     command — a waived id skips the command entirely and records
     `verdict: "waived"` with the waiver's reason; `result.sh` already
     tallied `waived`/`na` in `summary` and `gate.sh` already only counts
     `verdict == "fail"` as blocking, so no gate change was needed. The
     pass table (step 8) now states every waived/n/a row's reason
     explicitly, never silently omitting it. Also stripped "Phase N item"
     / decision-ID references out of both `SKILL.md` files while touching
     them — build-history bookkeeping has no business being read by the
     agent as runtime instruction.
   - e2e requirement (always-present invariant), `/dod:cancel`, amend/
     `--new` remain undone.

---

## Verification

**Phase 1 is done when all four hold, each stated with how it was verified:**

1. **Requirements** — every skeleton behaviour in the table above demonstrated.
2. **Real flow, not the diff** — in a scratch git repo with the plugin enabled:
   `/dod:define` → edit a file → arm the claim → observe the gate block → `/dod:verify`
   → observe release. Then the negative case: a deliberately failing check must block
   and name the failure. Transcript captured.
3. **Fresh-agent review** — independent reviewer on the changeset, running `git diff`
   itself. Blocking findings fixed; non-blocking findings batched and raised for your
   decision, never silently fixed or dropped.
4. **Green** — `bash run-tests.sh` passes; `bash check-version.sh dod <base> <head>`
   returns 0 (the pre-push hook auto-bumps `dod/.claude-plugin/plugin.json` otherwise).

**Interference check (N1), explicitly:** a session with no contract, and a session with
a contract but a question-only turn, must both produce empty gate stdout. This is the
NFR most likely to regress silently, so it gets its own test case rather than riding
along.

**In practice, verification exceeded this checklist.** Three real bugs surfaced only
through live use, not the scratch-repo walkthrough or the test suite:

- `dod_diff_hash` self-poisoned on `.dod/`'s own writes (the walkthrough's own
  `/dod:verify` call broke the very gate it was trying to satisfy).
- The claim latch never reset across an amend, silently gating an unrelated
  question-only turn (found by the independent reviewer, not by any test written in
  advance of the bug).
- `dod_diff_hash` used `git diff HEAD` instead of a fixed baseline, so a commit with
  zero net tree change still invalidated a just-passed result — found by a **second,
  independent Claude Code session** live-driving the same walkthrough and reporting
  the block it hit, not by this session's own testing.

Two more skill-instruction gaps (D28, D29 above) were found the same way: a human
actually running the scenario and reporting "the agent didn't do X." None of these five
would have been caught by criterion 4 (green tests) alone — criterion 2's live exercise,
run more than once and by more than one session, is what actually found them.

---

## Risks

| Risk | Mitigation |
|---|---|
| `completion-harness` stays enabled and its gate fires during the build | Known. Test in a scratch repo, not this one. Disable it if it interferes. |
| Wipe deletes something we later want | Tagged `dod-v1-final`; ported functions listed explicitly above. |
| Gate bug wedges a real session | Fail-open discipline + category-scoped brake, both covered by tests before `hooks.json` is written. |
| Doc and code drift | A1/A2 written into `docs/design-v2.md` in the same phase, per the repo's own "trust the code, re-sync the doc" rule. |
