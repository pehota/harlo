# task-dod

Task-DoD lifecycle plugin: nudges the agent to write a per-task Definition-of-Done
contract when a changeset touches product surface, then blocks `Stop` until that
contract exists and `/done` has run against it.

Rationale: [ADR-0001 — the Definition of Done is fixed at task start, not
assembled at `/done`](../docs/adr/0001-task-dod-defined-at-task-start.md).

## Lifecycle

```
PostToolUse (Bash|Write|Edit)          Stop
        │                                │
        ▼                                ▼
  dod-nudge.sh  ──writes──▶  task-dod/<task_key>.json  ◀──reads── dod-gate.sh
   (fires once,                    (dod-write.sh)          (blocks / allows)
    can't block)
```

1. **Nudge** (`hooks/dod-nudge.sh`, `PostToolUse` on `Bash|Write|Edit`) — the
   first time a changeset touches product surface with no task DoD on disk,
   emits a one-line reminder (`systemMessage` + `additionalContext`) and drops
   a marker so it fires at most once per task. Cannot block; fails silently on
   any missing dependency.
2. **Write** (`scripts/dod-write.sh`, invoked by the model, not a hook) —
   creates or amends `.claude/.harness/task-dod/<task_key>.json`. First write
   must be schema-valid with non-empty `requirements`. Every write after that
   is append-only: existing requirement text can't be dropped or reworded, and
   `created_at` / `blast_radius` are immutable — only genuinely new
   requirements may be appended.
3. **Gate** (`hooks/dod-gate.sh`, `Stop`) — blocks with a JSON reason when the
   changeset touches product surface and either no task DoD exists, or a DoD
   exists but `/done` hasn't run (checked via the stub-done marker). Otherwise
   allows, and on a clean pass archives the DoD to
   `task-dod/archive/<verified_sha>.json` and stamps the verified boundary.
4. **Stub `/done`** (`scripts/dod-stub-done.sh`) — a stand-in for the real
   `/done` checklist, used by the gate/tests to simulate "the checklist ran".
   The real `/done` middle (tests, lint, app-start, fresh-agent review) is out
   of scope for this plugin; see [`docs/base-dod.md`](docs/base-dod.md) for
   that checklist.

## Product vs. artifact surface

`scripts/lib-classify.sh` decides what counts as "product surface" that
requires a DoD. One rule, fail-closed: a changed path is product **unless** it
matches an `artifact_paths` glob. Default globs:

```
docs/** tasks/** README* CHANGELOG* LICENSE*
```

`docs/**`/`tasks/**` match the directory or anything beneath it; `NAME*`
matches by basename anywhere in the tree. Everything else — including new,
unlisted top-level directories — is product, so unfamiliar areas over-trigger
the DoD rather than silently escape the gate. Configurable via `hc_cfg
artifact_paths`.

## Files

| Path | Role |
|---|---|
| `hooks/hooks.json` | Registers the `PostToolUse` nudge and `Stop` gate |
| `scripts/dod-nudge.sh` | PostToolUse hook: one-shot reminder |
| `scripts/dod-gate.sh` | Stop hook: blocks missing/unverified DoD |
| `scripts/dod-write.sh` | Model-invoked writer: create/amend the DoD contract |
| `scripts/dod-stub-done.sh` | Test/dev stand-in for the real `/done` |
| `scripts/lib-classify.sh` | Product-vs-artifact path classifier |
| `scripts/harness-common.sh` | Trimmed shared identity/config resolver |
| `contracts/task-dod.schema.json` | JSON Schema for the DoD contract file |
| `docs/base-dod.md` | The base checklist `/done` verifies against |
| `tests/` | `test-dod.sh`, `test-dod-headless.sh`, fixtures |

## Contract shape

`.claude/.harness/task-dod/<task_key>.json`:

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

## Design notes

- **Fail-safe = allow.** Every unexpected condition (no jq, non-git, detached
  HEAD, mid-rebase, classifier unavailable) releases the `Stop` hook. The one
  exception — the entire point of the plugin — is a product-surface changeset
  with no task DoD.
- **Recursion brake is category-scoped**, not blanket. A repeated identical
  block category under `stop_hook_active` is released; a *different* category
  (e.g. "no-dod" → "dod-no-done") still blocks, so the DoD-write step inside a
  block-response cycle can't accidentally suppress the following /done-not-run
  block.
- **Append-only is enforced by the writer, not the schema** — a schema can't
  compare a write against the prior file on disk.
