# task-dod

Task-DoD lifecycle plugin: an explicit skill records a per-task
Definition-of-Done contract before implementation starts; the agent then
explicitly **claims** the task is finished, and `Stop` blocks until that claim
is covered by a passing verification result.

Rationale: [ADR-0001 — the Definition of Done is fixed at task start, not
assembled at `/done`](../docs/adr/0001-task-dod-defined-at-task-start.md) for the
contract, and [ADR-0003 — verification is triggered by an explicit claim, not
inferred from a stopping agent](../docs/adr/0003-claim-triggered-verification.md)
for what makes the gate fire.

**The asymmetry rule** governs everything here: an agent-authored signal may
only make the gate **stricter**, never looser. Arming the claim latch clears
nothing; skipping it buys nothing, because the `UserPromptSubmit` reminder fires
every human turn while product work sits unverified. **Exactly one signal relaxes
the gate: a passing verification result for HEAD.** `UserPromptSubmit` used to
disarm the latch on the theory that it means "the user took the turn back"; it
does not — it fires on subagent hand-backs and background-task notifications too,
so that disarm was an agent-reachable bypass. It is gone.

Collection, claiming and verification are deliberately separate concerns with
their own triggers. A PostToolUse nudge previously tried to infer "the agent is
about to implement something" from changed file paths and repeatedly false-
positived; it also deduped with a once-per-task marker, so ignoring it bought
permanent silence. Collection is agent-invoked only, and the reminder now rides
`UserPromptSubmit` with no dedup marker at all.

## Lifecycle

```
dod-collect skill        dod-complete-task.sh            Stop
 (agent-invoked)          (agent-invoked)                 │
       │                        │                          ▼
       ▼                        ▼                 dod-gate.sh reads:
 dod-write.sh writes     arms the latch      task-dod/claim-<task_key>   ← no latch: SILENT
 task-dod/<task_key>     task-dod/           task-dod/<task_key>.json
 .json                   claim-<task_key>    task-dod/verified/<task_key>-<HEAD_SHA>.json
                                             + working tree (lib-classify.sh)
       │                                                   │
       │        dod-verify skill writes                    │
       └───────────────▶ the verified result ──────────────┘
                                                           │
UserPromptSubmit ──▶ dod-user-turn.sh: reminds only        ▼
                     (non-blocking, never touches the   covered → disarm,
                     latch) every HUMAN turn while      archive, allow
                     product work is uncovered
```

1. **Collect** (`skills/dod-collect/SKILL.md`, agent-invoked) — the skill's
   own `description` is the trigger: the agent invokes it when it's about to
   start implementation work, not on every file touch. It builds/confirms a
   requirements list with the user, then writes the contract via
   `scripts/dod-write.sh`. No hook, no automatic classifier.
2. **Write** (`scripts/dod-write.sh`, invoked by the model, not a hook) —
   creates or amends `.claude/.harness/task-dod/<task_key>.json`. First write
   must be schema-valid with non-empty `requirements`. Every write after that
   is append-only: existing requirement text can't be dropped or reworded, and
   `created_at` / `blast_radius` are immutable — only genuinely new
   requirements may be appended.
3. **Claim** (`scripts/dod-complete-task.sh`, agent-invoked) — the agent
   declares "I am finished" by arming the latch
   `task-dod/claim-<task_key>`. Deliberately dumb: it records the claim and
   nothing else, and must never grow a check. A script that both claims and
   clears is a bypass with a friendly name.
4. **Gate** (`scripts/dod-gate.sh`, `Stop`) — latch-driven:
   - No `claim-<task_key>` latch → allow, **silent**. Nothing was claimed, so
     there is nothing to hold the agent to. This is what stops the gate
     blocking at the end of every turn while work is still in progress.
   - Latched, but no contract *and* no verification result → **block**:
     completion was claimed without ever agreeing what done means.
   - Latched, contract present, no `task-dod/verified/<task_key>-<HEAD_SHA>.json`
     → **block**: verification hasn't run for this changeset.
   - Verification result for `HEAD_SHA` is malformed, or contains any
     `status: "fail"` entry → **block**: fix and re-verify.
   - Verified at `HEAD_SHA` but the working tree still carries product-surface
     changes → **block**: uncommitted work is by construction work the
     verification at HEAD could not have seen. Both halves are required for
     coverage.
   - Covered → disarm the latch, archive the contract to
     `task-dod/archive/<HEAD_SHA>.json`, allow. The next task starts clean.
5. **User turn** (`scripts/dod-user-turn.sh`, `UserPromptSubmit`) — **reminder
   only.** It touches no state: when the changeset carries uncovered product
   work it injects a **non-blocking** reminder via
   `hookSpecificOutput.additionalContext`, and otherwise does nothing. No dedup
   marker: it fires every turn while the condition holds. It skips
   harness-generated turns — `<agent-message`, `<task-notification>`,
   `<cross-session-message`, and a leading `Another Claude session sent a
   message:` — which carry no decision point; anything unrecognised is treated
   as a human turn and the reminder fires (fail *toward* firing).
6. **Verify** (`skills/dod-verify/`, agent-invoked) — the real protocol: config
   detect, tests with a before/after checkpoint, app startup, task-specific
   checks, changeset-scoped review. It writes
   `task-dod/verified/<task_key>-<HEAD_SHA>.json`, the only thing that clears
   the gate. The `scripts/dod-verify-*.sh` helpers back it;
   `scripts/dod-stub-done.sh` is a **test/dev-only** stand-in and is never
   advertised to the agent as a remedy.
7. **Decision log** (`scripts/lib-log.sh`, sourced) — every terminal path of
   `dod-gate.sh`, `dod-user-turn.sh` and `dod-session-start.sh` appends one
   JSON line to `.claude/.harness/dod-log/<UTC date>.jsonl` recording the
   decision it took, including the silent early exits that are otherwise
   unobservable. Observe-only: it changes no decision, never writes to stdout,
   and always returns 0. It replaced a `TaskCompleted` audit trail, which was
   bound to an event that does not mean "a task was completed" in the sense
   this plugin gates on and recorded nothing in a real session.

## Files

| Path | Role |
|---|---|
| `hooks/hooks.json` | Registers `SessionStart`, `Stop`, `UserPromptSubmit` — never `TaskCompleted`, never `SubagentStop`, never `PostToolUse` |
| `skills/dod-collect/SKILL.md` | Agent-invoked: build + write the DoD contract |
| `skills/dod-verify/` | Agent-invoked: the real verification protocol; writes the result that clears the gate |
| `scripts/dod-gate.sh` | Stop hook: silent unless the claim latch is armed, then blocks until covered |
| `scripts/dod-complete-task.sh` | Agent-invoked claim: arms the latch and does nothing else |
| `scripts/dod-user-turn.sh` | UserPromptSubmit hook: reminds only (non-blocking), with a state-aware, two-step instruction; skips harness-generated turns; **never touches the latch** |
| `scripts/lib-log.sh` | Sourced decision log — `dod_log <hook> <decision> [detail]`, append-only JSONL, never breaks its caller |
| `scripts/dod-write.sh` | Model-invoked writer: create/amend the DoD contract |
| `scripts/dod-verify-*.sh` | Verifier helpers: detect / preflight / triage / write-result |
| `scripts/dod-stub-done.sh` | Test/dev stand-in that writes a passing verification result — **never named to the agent as a remedy** |
| `scripts/lib-classify.sh` | Product-vs-artifact path classifier — **used for gating**: sourced by `dod-gate.sh` and `dod-user-turn.sh`. Its `artifact_paths` is read from `.claude/done-config.json` directly, never through the agent-writable session-config layer |
| `scripts/harness-common.sh` | Trimmed shared identity/config resolver |
| `contracts/task-dod.schema.json` | JSON Schema for the DoD contract file |
| `contracts/task-dod-verified.schema.json` | JSON Schema for the verification result file |
| `docs/base-dod.md` | The base checklist a real verifier should check against |
| `tests/` | `test-dod.sh`, `test-dod-headless.sh`, fixtures |

## State files

All under `.claude/.harness/`:

| Path | Role |
|---|---|
| `task-dod/<task_key>.json` | The append-only DoD contract |
| `task-dod/claim-<task_key>` | **The claim latch.** Its existence is the whole signal; the content (armed-at UTC + HEAD sha) is a hint for a human. Disarmed by exactly ONE thing: `dod-gate.sh` on its covered path. It persists across turns and, in task mode, across sessions on the same branch. **Human escape hatch:** if a task was claimed and then abandoned, delete this file — the gate goes silent again. (Session mode keys the latch to the session id, so a new session orphans the old one; orphans are inert and are not reaped.) |
| `task-dod/verified/<task_key>-<HEAD_SHA>.json` | The verification result — the only thing that clears the gate |
| `task-dod/archive/<HEAD_SHA>.json` | The contract, archived once the changeset was covered |
| `dod-log/<UTC date>.jsonl` | Append-only decision log — one line per hook invocation, every terminal path |
| `dod-log/payloads/<ts>-<pid>.json` | **Temporary diagnostic**, capped at the 20 most recent. The question it was added to answer is resolved: no payload field marks origin, only the shape of `.prompt` does. Kept to discover a *new* harness wrapper type, which shows up as a reminder fired on an automated turn |
| `last-block/dod-<task_key>` | The last block category, for the category-scoped recursion brake |


## Contract shape

`.claude/.harness/task-dod/<task_key>.json` (written by `dod-collect` /
`dod-write.sh`):

```json
{
  "task_key": "...",
  "created_at": "...",
  "blast_radius": { "tier": "low|medium|high", "reason": "..." },
  "requirements": [
    { "text": "...", "origin": "prompt|follow-up|derived", "added_at": "..." }
  ]
}
```

`task_key` is always injected/overwritten by the writer from the resolved
identity — callers cannot mis-key it.

## Verification-result shape

`.claude/.harness/task-dod/verified/<task_key>-<verified_sha>.json` — a
**separate file** from the contract, which stays append-only and is never
mutated by verification:

```json
{
  "task_key": "...",
  "verified_sha": "...",
  "checked_at": "...",
  "results": [
    { "requirement_index": 0, "status": "pass|fail|skipped", "evidence": "..." }
  ]
}
```

`requirement_index` is the 0-based index into the collected contract's
`requirements[]` array — a stable reference back to the immutable contract
without duplicating requirement text.

## Design notes

- **The asymmetry rule.** An agent-authored signal may only make the gate
  stricter. Arming the latch clears nothing; skipping it buys nothing. The only
  relaxing signal is a passing verification result for HEAD.
- **There is no origin discriminator.** No hook fires when the *agent* considers
  the task complete: `Stop` fires at every turn end and `stop_reason` is
  `"end_turn"` both when the agent is finished and when it is asking a question.
  `UserPromptSubmit` is not the missing signal either — it fires on subagent
  hand-backs, background-task notifications and cross-session messages, and its
  payload carries no field marking origin (`prompt_id` differs on every injected
  turn, automated ones included). So the gating path does not look at origin at
  all.
- **Blast radius decides where content sniffing is allowed.** The reminder may
  guess a turn's origin from the shape of `.prompt`, because a wrong guess costs
  one extra line of context. The gate may not, because a wrong guess there fails
  open and silently voids the gate.
- **Fail-safe = allow.** Every unexpected condition (no jq, non-git, detached
  HEAD, mid-rebase, an unloadable classifier) releases the `Stop` hook. The one
  exception — the entire point of the plugin — is an armed claim latch with no
  verification covering the changeset.
- **Coverage is two halves.** Verified-at-HEAD *and* no product-surface dirt in
  the working tree. Verified-at-HEAD alone would let uncommitted work through.
- **Recursion brake is category-scoped**, not blanket. A repeated identical
  block category under `stop_hook_active` is released; a *different* category
  (e.g. `"dod-no-verify"` → `"dod-verify-failed"`) still blocks. Consequence:
  enforcement is **one firm block per user turn**, plus a reminder that
  re-fires every turn. Deliberate — never trap the user. This is also what makes
  a persistent latch safe: an unverified claim blocks once per turn-end cycle and
  then releases, forever, rather than trapping anyone.
- **The reminder has no dedup marker.** A once-per-task nudge is exactly the
  thing an agent can outlast.
- **Append-only is enforced by the writer, not the schema** — a schema can't
  compare a write against the prior file on disk.
- **Known routes to silence**, stated rather than assumed away: detached HEAD
  and mid-merge/mid-rebase release unconditionally, so `git checkout --detach`
  is a one-command bypass; `/clear` re-pins the session baseline and empties the
  changeset; the latch lives under `.claude/.harness`, where the agent's shell
  can delete it; and gitignored / `.git/info/exclude`d content is invisible to
  the tree classifier.
- **Subagents run no dod at all.** Only the orchestrator claims. `Stop` does not
  fire for subagents (that is `SubagentStop`, deliberately not registered). A
  subagent's hand-back *does* raise `UserPromptSubmit` in the orchestrator, but
  that turn now reaches only the reminder, which skips it.
