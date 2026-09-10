---
status: accepted
---

# The Definition of Done is fixed at task start, not assembled at `/done`

The effective DoD is currently folded together at `/done` time (`skills/done/dod-protocol.md`
Step 0.5) — at the *end* of the task. That means the gate can only verify what it can
rediscover at the end: tests, lint, app startup, an independent review, and whatever
`task_checks` the model happened to remember. DoD rule #1 is *"meets every stated
requirement"*, and nothing on disk records what those requirements were.

The protocol already names this failure itself (`dod-protocol.md:32-47`: capture
`task_checks` at task start, "they drift out of focus by the end otherwise") — but no
script stores them, so they only reach disk in Step 7, reconstructed from a faded memory
of the prompt.

**Decision:** the task's DoD becomes a first-class state file,
`.claude/.harness/task-dod/<task_key>.json`, written at task start and **append-only**.
Entries may be added (mid-task clarification) but never deleted or softened, and each
records its origin (`prompt` / `follow-up` / `derived`). It is required only when the
changeset touches the **product surface** — any path not matched by `artifact_paths`
(`docs/**`, `tasks/**`, `README*`, `CHANGELOG*`, `LICENSE*`) — so specs, plans and notes
carry no DoD.

Tracked in [#11](https://github.com/pehota/harlo/issues/11); a walking skeleton in `dod/`
proves the flow before anything is wired into the live bundle.

## Considered options

**In-context only** — the model just remembers the requirements. Rejected: this dies at
the first compaction, which is precisely the moment a forgotten requirement slips. It is
also the status quo, and the status quo is what prompted the change.

**Fold it into `done-state`**, written early and amended at `/done`. Rejected: it
collides with that file's meaning. `done-state` is *evidence of verification*; the task
DoD is *the contract being verified*. Two lifecycles — the contract is fixed at the start
and archived at the boundary, the evidence is stamped at HEAD and invalidated when HEAD
moves. One file cannot hold both without the gate having to guess which half it is
reading.

**Freeze it at write time.** Rejected: requirements genuinely arrive mid-task, and
freezing forces a fake task boundary every time one does.

**Let it be freely rewritable.** Rejected: this makes the file worthless — any
requirement the model cannot satisfy, it edits away. Append-only is the single property
that makes the file evidence rather than a scratchpad.

**Trust the writer script to enforce the shape.** Rejected: append-only is an invariant
*about the file*, and every other invariant in this harness is enforced structurally
(`contracts/*.schema.json`, validated in `test-contracts.sh`) rather than by trusting a
writer. Skipping that would make this the one piece of state the harness takes on faith.

## Consequences

**A second DoD-ish file now exists.** `task-dod/` and `done-state/` both hold DoD-shaped
data. The split is contract-vs-evidence and is the reason for this ADR: without it, the
duplication reads as an accident.

**The task boundary becomes load-bearing.** A task ends at the `verified_sha` stamped in
`done-state`; the next product-surface mutation past that SHA requires a fresh task DoD,
and the old one is archived keyed by that SHA. Two sequential tasks on one branch share a
`task_key`, so without this rule the second would inherit the first's contract.

**`artifact_paths` fails closed.** An unlisted path counts as product surface, so a new
directory over-triggers the DoD rather than silently escaping it. The default list is
deliberately directory-scoped and excludes a blanket `**/*.md`: in this repo
`completion-harness/DOD.md` and `skills/done/dod-protocol.md` *are* the harness's
behavioural contract, and a wildcard rule would exempt the highest-blast-radius edits
here.

**The trigger cannot be a `PreToolUse Write|Edit` hook.** Requiring the DoD means knowing
*which surface* changed, and Bash-driven mutations (`sed`, heredocs, short scripts) never
match that matcher and carry no `tool_input.file_path`. Detection is therefore derived
from the changeset (`hc_tree_status` + the commit ledger), which is tool-agnostic;
`.claude/.harness/**` is exempt so that writing the DoD file is not itself an arming
mutation.

**Enforcement is at the Stop gate, not a PreToolUse deny.** The requirement is "you
cannot *finish* without a DoD", and Stop is already where this harness enforces things.
A hard deny mid-edit would be a jarring failure mode for a file the model is about to
write anyway.
