# task-dod

Task-DoD lifecycle plugin: an explicit skill records a per-task
Definition-of-Done contract before implementation starts, then `Stop` blocks
until that contract has a passing verification result.

Rationale: [ADR-0001 — the Definition of Done is fixed at task start, not
assembled at `/done`](../docs/adr/0001-task-dod-defined-at-task-start.md).

Collection and verification are deliberately separate concerns with their own
triggers — a PostToolUse nudge previously tried to infer "the agent is about
to implement something" from changed file paths and repeatedly false-
positived (firing on read-only/discussion turns, on file deletion, on any
path outside a small allowlist). Collection is now agent-invoked only.

## Lifecycle

```
dod-collect skill                          Stop
   (agent-invoked)                          │
        │                                    ▼
        ▼                          dod-gate.sh reads:
  dod-write.sh writes        task-dod/<task_key>.json
  task-dod/<task_key>.json   task-dod/verified/<task_key>-<HEAD_SHA>.json
        │                                    │
        │         dod-stub-done.sh writes    │
        └────────────────▶ verified result ──┘
                    (test/dev stand-in for the real /done)
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
3. **Gate** (`hooks/dod-gate.sh`, `Stop`) — purely structural, no classifier
   involved:
   - No `task-dod/<task_key>.json` on disk → allow, silent. Nothing was
     collected, so there's nothing to verify.
   - A contract exists but no `task-dod/verified/<task_key>-<HEAD_SHA>.json`
     → **block**: verification hasn't run for this changeset yet.
   - A verification result exists for `HEAD_SHA` but contains any
     `status: "fail"` entry → **block**: fix and re-verify.
   - A verification result exists for `HEAD_SHA` with zero failures → allow,
     and archive the contract to `task-dod/archive/<HEAD_SHA>.json`. The next
     task starts clean — no live contract until `dod-collect` runs again.
4. **Verify (stub)** (`scripts/dod-stub-done.sh`) — a stand-in for the real
   verification protocol, used by the gate/tests to simulate "the checklist
   ran". It reads the collected contract and writes a trivially-passing
   result (one `pass` per requirement) to
   `task-dod/verified/<task_key>-<HEAD_SHA>.json`. **Building a real
   verification skill/protocol that actually runs checks per requirement
   (tests, lint, app-start, review — see
   [`docs/base-dod.md`](docs/base-dod.md)) is future work** — this plugin
   only wires the lifecycle around it.

## Files

| Path | Role |
|---|---|
| `hooks/hooks.json` | Registers the `Stop` gate only — no PostToolUse hook |
| `skills/dod-collect/SKILL.md` | Agent-invoked: build + write the DoD contract |
| `scripts/dod-gate.sh` | Stop hook: blocks missing/failing verification |
| `scripts/dod-write.sh` | Model-invoked writer: create/amend the DoD contract |
| `scripts/dod-stub-done.sh` | Test/dev stand-in that writes a passing verification result |
| `scripts/lib-classify.sh` | Product-vs-artifact path classifier — retained but **not used for gating**; not called from `dod-gate.sh` or any hook |
| `scripts/harness-common.sh` | Trimmed shared identity/config resolver |
| `contracts/task-dod.schema.json` | JSON Schema for the DoD contract file |
| `contracts/task-dod-verified.schema.json` | JSON Schema for the verification result file |
| `docs/base-dod.md` | The base checklist a real verifier should check against |
| `tests/` | `test-dod.sh`, `test-dod-headless.sh`, fixtures |

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

- **Fail-safe = allow.** Every unexpected condition (no jq, non-git, detached
  HEAD, mid-rebase) releases the `Stop` hook. The one exception — the entire
  point of the plugin — is a collected DoD contract with no passing
  verification result for the current `HEAD_SHA`.
- **Recursion brake is category-scoped**, not blanket. A repeated identical
  block category under `stop_hook_active` is released; a *different* category
  (e.g. `"dod-no-verify"` → `"dod-verify-failed"`) still blocks, so a
  verification write inside a block-response cycle can't accidentally
  suppress a following block for a different reason.
- **Append-only is enforced by the writer, not the schema** — a schema can't
  compare a write against the prior file on disk.
- **No automatic re-trigger.** Once a contract is archived, Stop stays quiet
  on later product changes until `dod-collect` is invoked again — this
  plugin does not infer "you should have collected a DoD" from a changeset;
  that inference was the source of the plugin's original false positives.
