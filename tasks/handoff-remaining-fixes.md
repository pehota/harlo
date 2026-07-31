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

> **Superseded 2026-07-31.** The worktree provisioning/teardown work added three
> suites (`test-pkg-probe.sh`, `test-worktree-detect.sh`, `test-worktree-ops.sh`).
> `run-tests.sh` is now **25/25**; the 22 above is the count as of this handoff.

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

## Item 5 — prevent the missing anchor instead of only reporting it

Everything shipped so far makes a missing anchor *legible* (honest message) or
*recoverable* (writer-stamped `base_sha`, marker fallback). None of it stops the anchor
going missing. Most of the ways it goes missing are preventable.

### 5a — four cheap preventions (one commit, low risk)

1. **Stop reaping the anchor.** `baseline-snapshot.sh:58-63` deletes anything under the
   state dir older than 14 days, excluding `task-base/`, `tree-base/`, `review-log/`,
   `escalation-accept/` — but not `baselines/`. So the harness deletes the exact file it
   later blocks for missing. Exclude `baselines/*.sha`; keep reaping `*.dirty`, which
   really is ephemeral. Update the comment at line 56, which currently argues the
   opposite.
2. **Make a sourcing failure loud.** The gate has no `set -u`, so if
   `harness-common.sh` fails to source, `$HC_BASE` expands to empty and the gate
   degrades into the *identical* symptom as a missing baseline. Two very different
   faults, one message. Add `set -u` or an explicit "library missing ⇒ hard error"
   guard so they stop aliasing.
3. **Refuse to write an empty task pin.** A present-but-empty `task-base/<key>.sha`
   reaches the same empty-`HC_BASE` state. Validate at write time.
4. **Treat a present-but-empty pin as corrupt, not as "no base."** Distinct message,
   distinct remedy.

None of these change what the gate accepts — they remove ways it loses the anchor, and
they stop three unrelated faults from producing one indistinguishable symptom.

### 5b — the actual root cause (a DESIGN QUESTION — do not implement unasked)

The anchor is keyed on **session identity**, which is not a property of the repository.
It is a runtime accident: it changes on resume, on compaction, when a hook does not fire,
when two sessions share a directory. Causes 2, 4 and 8 in the failure list are all
downstream of that single choice.

Git already knows where the work started, and does not care about session ids:

```
git merge-base HEAD @{u}
```

Properties, stated honestly:

- **Survives every session disruption**, because nothing is remembered — the anchor is
  recomputed from the repo each time.
- **Handles other people's commits BETTER than the current scheme.** Upstream commits
  pulled in become ancestors of both sides, so `merge-base` advances past them and they
  leave the changeset automatically. The pinned session baseline instead counts
  everything after the pin — in the motivating session, three unrelated upstream commits
  appeared inside "the agent's" diff for exactly this reason.
- **Breaks when the work leaves the unpushed window.** Push mid-session (which happened
  in the motivating session) and `merge-base HEAD @{u}` equals HEAD: the changeset reads
  empty and the gate would pass having verified nothing. **This is a bypass, and it is
  the blocking objection.** The same reasoning made an earlier pass decline to treat an
  empty base as "nothing to do."
- Two lesser edges: a branch with no upstream has no `@{u}` (fall back to `merge-base`
  with trunk — this is what the existing branch-keyed task mode already half-implements);
  and a colleague pushing directly onto the working branch would place their commits
  inside the changeset.

**The question to answer before writing any code:** is pushed work outside the gate's
remit, or does pushing not discharge verification? Everything else follows from that.

- If pushing **does** discharge it, `merge-base HEAD @{u}` is close to a drop-in and
  removes three failure modes at once.
- If pushing **does not**, the anchor needs a second, durable source for
  already-pushed-but-unverified work — and that source has to be something the agent
  cannot forge, which is the same constraint that shaped `head_tree` /
  `review_anchor_sha`.

Do not pick a side in a subagent. Put it to the user with the bypass stated plainly.

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
