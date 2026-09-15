---
status: accepted
---

# Verification is triggered by an explicit claim, not inferred from a stopping agent

The Stop gate exists to stop the agent declaring a task done when it isn't. Two
independent faults made it inert.

**Nothing triggered it.** The gate was contract-driven — it blocked only when
`.claude/.harness/task-dod/<task_key>.json` existed, and that file is written by the
agent-invoked `dod-collect` skill, which never fired. In a sibling repo, `task-dod/` held
**0 files** while `done-state/` held 17, across 12 days.

**It was blind to committed work.** `hc__resolve_session_base`
(`harness-common.sh:797-812`) advances `HC_BASE` past every commit not in a commit
ledger, and that ledger is written by `completion-harness/scripts/commit-ledger.sh` — a
hook `dod` does not ship and which is disabled. So every commit reads as foreign,
`HC_BASE` walks to HEAD, and the committed range is always empty. This repo's owner works
on `main` and commits in logical bundles, so committing made the gate go quiet.

**Decision:** replace "guess when the task is done" with "react to an explicit claim".
The agent runs `dod/scripts/dod-complete-task.sh`, which **arms a latch** at
`task-dod/claim-<task_key>`. With no latch armed the gate is **silent** — that is what
stops it blocking at every turn end while work is legitimately in progress. With the
latch armed, Stop blocks until the changeset is *covered*: a verification result exists
for HEAD **and** the tree carries no product-surface dirt. Both halves are required;
verified-at-HEAD alone would let uncommitted work through. Exactly two things disarm the
latch — the gate, when verification covers the changeset, and `UserPromptSubmit`, the
user taking the turn back. A non-blocking reminder rides that same `UserPromptSubmit`
(`hookSpecificOutput.additionalContext`), re-firing every user turn while unverified
product work exists, and `TaskCompleted` writes an observe-only audit trail to
`task-log/`. Blindness to commits is fixed by reading `HC_BASE_ORIG` — assigned at
`harness-common.sh:762`, *before* the ledger-advance loop, and kept equal to `HC_BASE` in
task mode — instead of `HC_BASE`.

**The asymmetry rule governs the mechanism: an agent-authored signal may only ever make
the gate STRICTER, never looser.** `dod-collect` violated it — not writing the contract
was simultaneously the path of least resistance and the path to zero enforcement. So
arming the latch clears nothing, and skipping it buys nothing: the reminder fires
regardless. `UserPromptSubmit` is the missing discriminator. No hook fires when the
*agent* considers the task complete — `Stop` fires at every turn end, and `stop_reason`
is `"end_turn"` both when the agent is finished and when it is asking a question, which
is why a previous attempt blocked at the end of ~15 consecutive turns. But a hook does
fire when the **user** takes the turn back, and that separates the two cases. Being
user-authored, it may relax the gate without breaking the rule.

## Considered options

**Port `commit-ledger.sh` into `dod`.** Correct, and the largest: new hooks, new
registration, new failure surface. `HC_BASE_ORIG` reaches the same result in one word.

**Fail closed when no ledger infrastructure exists.** ~3 lines, and it matches
`hc_tree_status`'s "missing baseline → everything blocks" doctrine.

Rejected — but not for the reason it is tempting to give. Without a ledger,
`HC_BASE_ORIG` cannot distinguish the agent's commits from a human's either, so it
re-admits foreign commits into the changeset and mis-attributes exactly as fail-closed
does. The two options share that defect; it does not discriminate between them.

What discriminates is **blast radius**. Fail-closed puts the mis-attribution on the
*blocking* path: a human's mid-session commit traps the agent. `HC_BASE_ORIG` puts it
only on the *reminder* path, which is non-blocking and user-clocked — the cost of
over-counting a human commit is one extra line of context on one turn. The gate itself
never reads the changeset; it reads the latch and the working tree. Widening what the
reminder notices is cheap in a way that widening what the gate blocks on is not.

**Prose detection of the agent's claim.** `Stop`'s payload does carry
`last_assistant_message`, so it was available. Rejected as brittle, phrasing-dependent,
NLP in bash; an explicit script invocation is deterministic and strictly better.

**"No progress for N turns" as a completion signal.** Unusable here: this repo's main
agent orchestrates and delegates, so it legitimately writes nothing for many consecutive
turns while subagents work. No value of N is safe.

**A content fingerprint keyed to the changeset** — a git tree sha built through a
throwaway index. Designed in full, then dropped: a claim keyed to exact content dies on
any incidental byte (a pre-commit formatter, a stray `.pyc`, a `chmod`, `dod-verify`'s
own writes), so the agent's optimal play after claiming became "touch anything" and
complying could drop the claim. The latch plus a HEAD-keyed result covers the same ground
with no throwaway index, no unreferenced objects exposed to `git gc`, and no
commit-invariance edge cases (`chmod`, `.gitattributes`, CRLF, submodules, sparse
checkout).

**Putting the reminder on `Stop`.** Impossible: a Stop hook has two outputs, block or
silence, so a "soft reminder" there *is* a block.

**Putting the reminder on `PostToolUse`** (as the deleted `dod-nudge.sh` did). It fires
on essentially every content-changing tool call; 30-80 identical injections per task
desensitises the agent. It also deduped with a once-per-task marker, which let ignoring
the nudge buy permanent silence — an asymmetry violation.

## Consequences

**One block per user turn.** The category-scoped recursion brake (`dod-gate.sh`'s `block()`)
releases on the second Stop of a cycle. Enforcement is one firm block plus a reminder
that re-fires every turn, not a trap. Deliberate: FAIL-SAFE = ALLOW.

**Four routes to silence, all stated rather than assumed away.** `dod-gate.sh`
exits 0 unconditionally on detached HEAD and mid-merge/mid-rebase, so `git checkout
--detach` is a one-command bypass — left open, because closing it means blocking in a
state where the fail-safe doctrine says release. `/clear` re-pins the session baseline
and empties the changeset (user-triggered, so not an asymmetry violation). The latch
lives under `.claude/.harness`, where the agent's shell can delete it — still cheaper
than forging a schema-valid verification result. And gitignored / `.git/info/exclude`d
content stays invisible, inherited from `hc_tree_status`'s accepted gap at
`harness-common.sh:864-881`.

**Subagents run no dod at all.** Only the orchestrator claims: `Stop` does not fire for
subagents (that is `SubagentStop`, deliberately not registered) and `UserPromptSubmit`
fires only on real user turns.

**Two knobs move out of the agent-writable layer.** `artifact_paths` is read from
`.claude/done-config.json` directly rather than through `hc_cfg`, which consults
`.claude/.harness/session-config.json` first: `{"artifact_paths":["*"]}` there made every
path an artifact and silenced the gate. This mirrors `hc__detect_trunk`'s refusal to let
the session layer reach `trunk`. The session base sha is now shape-validated (40 or 64
lowercase hex, then confirmed to resolve to a commit) before it reaches git, because
`git rev-parse -q --verify` succeeds for any resolvable refname and `HEAD` written into
`baselines/<sid>.sha` would collapse the range.
