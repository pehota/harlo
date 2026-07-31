# Handoff — remaining completion-harness fixes

Written 2026-07-31. Paste this whole file as your opening prompt in a fresh session.

---

## Context

Repo: `/Users/localadmin/Work/mine/harlo` (git root; the plugin lives in `completion-harness/`).

A previous session shipped 24 local commits fixing four classes of false block in the
Stop gate. All are **committed and unpushed**. `bash run-tests.sh` is **22/22 green**.
Start by confirming both:

```bash
cd /Users/localadmin/Work/mine/harlo
git log --oneline ac91e6c..HEAD    # ~24 commits, docs + fixes
git status --short                 # must be empty
bash run-tests.sh                  # must be 22/22
```

If those don't hold, stop and report before touching anything.

### What already shipped (do not redo)

- Review-log basenames must be 40/64 lowercase hex — a stray `HEAD.json` no longer
  resolves as a git rev and grants coverage.
- Verification carries across a HEAD move when `git rev-parse HEAD^{tree}` is unchanged
  (`head_tree`, `review_anchor_sha`, `base_sha` are writer-injected facts; the gate never
  enumerates the review-log directory).
- Missing tree baseline: still blocks, but no longer claims the agent introduced the
  listed paths.
- Missing changeset anchor (`HC_BASE` empty): honest message naming the cause and the
  restart remedy, plus recovery from a writer-stamped `base_sha` or the
  `current-session` marker's done-state. `HC_BASE_RECOVERED` is **never** assigned to
  `HC_BASE` — it feeds only coverage and the summary, never the two steps that grant a
  pass.
- `hc_state` / `hc_done_state_blocked` classify by tree, not sha.
- Baseline capture is atomic (temp + `mv`).
- `test-reap.sh` backdates fixtures portably — it was passing vacuously on macOS.
- Docs re-synced across `README.md`, `dod/base-dod.md`, `DOD.md`,
  `skills/done/dod-protocol.md`, `docs/design.md`, `docs/architecture.md`.

### The plugin is currently switched OFF

`~/.claude/settings.json` has `"completion-harness@harlo": false`. None of this code runs
until it is `true`. Flip it back when you want to exercise the gate for real.

---

## Standing rules for this work

1. **Reproduce before fixing.** Every item below is a claim. Write a failing test first.
   If it does not reproduce, report it REFUTED with the evidence and change nothing —
   two reviewers were wrong this way already, and both prescribed fixes would have been
   a no-op or a new hole.
2. **Never weaken a stated guarantee**: strict-on-missing-baseline, no self-review,
   un-forgeable green, no directory enumeration in the gate's candidate set, and
   nothing that grants a pass may read an agent-supplied payload field. If a fix needs
   to, STOP and report.
3. **Writer and gate must resolve the identical candidate set.** Every divergence found
   so far produced either a silent forever-block or a one-turn-later re-block. When you
   touch one side, check the other.
4. `run-tests.sh` must stay green after every commit. One commit per fix, conventional
   commits, explain WHY.
5. Docs-only changes go in their own commit. Do NOT execute the planned
   `.harness` → `.done-gate` rename in `tasks/todo.md`.

---

## Item 1 — the accusation survives in preflight (small, do first)

`completion-harness/scripts/done-preflight.sh:89` still prints:

> "the gate will treat ALL pre-existing files as yours and block forever"

That is the exact unattributable claim removed from `hc_tree_remediation` in `a3b600e`,
surviving one caller downstream. The verdict is right — it *is* a hard deadlock — but the
harness cannot know those files are the agent's, and saying so is what made a user
distrust the gate.

**Do:** reword to match `hc_tree_remediation`'s honesty (state that authorship cannot be
determined and every current change will be treated as blocking), keeping the remediation
sentence, which is correct and worth preserving. Then `grep` the whole tree for the same
*claim* — not the same function — in case a third copy exists.

**Test:** assert the preflight output does not assert authorship, and still names the
restart remedy.

---

## Item 2 — review severity is single-log while coverage is chain-wide

`done-gate.sh:526` calls `hc_review_blocking "$REVIEW_LOG" "$MIN_LEVEL"` on exactly ONE
resolved log. `hc_review_coverage_gap` (same file, line 545) unions `files_reviewed`
across the whole ancestor chain plus `EXTRA_ADMIT` / `CHAIN_ADMIT`.

So attestations are chain-wide but findings are not: once any HEAD-exact log exists, an
unresolved `high`/`critical` finding recorded in an older chain log stops gating, even
though that log's attestation is still being counted.

**Confirmed reproducible, and confirmed INHERITED** — a plain ancestor chain with no
anchor and no amend does it too, so it predates the tree-carry work. It is a real gap,
not a regression.

**A previous pass deliberately declined the naive fix.** Unioning only
`{REVIEW_LOG, anchor}` closes strictly less than the hole while making the gate look
stricter. Do the real thing: evaluate blocking severity across the same set of logs
coverage already walks, and block on the maximum.

**Watch out:** `tests/test-gate.sh` has 3 `parity_assert` cases pinning `hc_state` ↔ gate
reason. Widening severity will move some reasons. Update them deliberately — do not
loosen an assertion to make a test pass.

---

## Item 3 — a legacy anchorless done-state passes with coverage switched off

`hc_review_coverage_gap` returns the token `SKIP` when the base is empty
(`harness-common.sh:829-830`), and the gate treats `SKIP` as a pass
(`done-gate.sh:539-540`, documented as a deliberate no-regression degrade — before
coverage existed, there was no check at all).

Consequence today: a **legacy** done-state on the gate's own key, with no `base_sha` to
recover from, still passes with the coverage check silently off. The anchor recovery
added in `f1400e3` covers the modern path but not this one.

**Decide, then implement:** either (a) keep `SKIP` passing but make it *visible* — the
gate should say coverage was not computable, so it can never look like a verified pass;
or (b) require an anchor and block, accepting that pre-existing legacy states break.
(a) is the smaller, safer change; (b) is the honest one. **Ask before choosing (b)** —
it changes behaviour for states written before this work.

---

## Item 4 — `baselines/` age-reaping vs the anchor it anchors

`baseline-snapshot.sh:58-63` deletes anything under `.claude/.harness` older than 14
days, excluding `task-base/`, `tree-base/`, `review-log/` and `escalation-accept/`.
`baselines/` is **deliberately** not excluded — the comment at line 56 argues session
state is ephemeral because "the changeset is the session."

But `baselines/<sid>.sha` is exactly the changeset anchor whose absence produces the
no-anchor block, and the honest message added in `d3e6273` names age-reaping as one of
its three likely causes. So the harness reaps the thing it later blocks for missing.

**This is a tension to resolve, not an obvious bug.** Long-running sessions and
resumed-after-a-fortnight work are the cases that bite. Options: exclude
`baselines/*.sha` (keep reaping `*.dirty`, which really is ephemeral); or shorten
nothing and rely on the `base_sha` recovery, which now covers most of the hole; or leave
it and document the interaction where the reap policy is described.

**Recommend a call with reasoning rather than silently changing retention.**

---

## Optional cleanup

`grep -rn "ponytail:" completion-harness/` — if any deliberate shortcuts were left, they
carry their own upgrade path. Not required.

---

## Verification standard

Tests in scratch repos are necessary but not sufficient. The one thing that actually
proved the anchor work was watching the real Stop hook fire with the new message. When
you finish, flip the plugin on, run a session in a throwaway repo, and confirm the gate
behaves — do not grade the fix by whether the suite is green.

Do not push without being asked.
