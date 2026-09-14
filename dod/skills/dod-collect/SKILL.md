---
name: dod-collect
description: Collect and record the Definition of Done for the current task before implementation begins. Use this when you are about to start implementing a change (writing/editing product code, not just discussing or exploring) and no task-specific DoD has been recorded yet for this session — build a short list of concrete, verifiable requirements with the user and write them to the task-dod contract. Do not use for read-only, discussion-only, or planning-only turns.
---

# dod-collect

Records a per-task Definition of Done (DoD) **contract** before implementation
starts. This is the collection half of the dod plugin's lifecycle; the
verification half (checking the contract was satisfied) is a separate
concern and not this skill's job.

## When to run this

Invoke this skill once, at the point where you are about to start making
product changes for a task — not before, not automatically on every file
touch. If a `task-dod/<task_key>.json` already exists for this session,
do not invoke this again; append-only amendments to that file happen through
`dod-write.sh` directly if new requirements surface later (see below), not by
re-running collection from scratch.

Do not invoke this for:
- Read-only exploration, research, or discussion turns.
- Planning turns (plan mode) where no code is being written yet.
- Trivial one-line fixes where the user has not asked for a DoD-worthy task.

## What to do

1. From the user's request, draft a short list of concrete, verifiable
   requirements — each one something you can later check pass/fail, not a
   vague goal. Example: "Stop hook blocks only when a task-dod file exists
   and no matching verified-result exists" is verifiable; "improve the
   plugin" is not.
2. Assess blast radius: `low` (isolated, easily reverted), `medium`
   (touches shared code paths but contained), or `high` (crosses module
   boundaries, affects other consumers, hard to revert) — with a one-line
   reason.
3. Confirm the list with the user before writing it. This is a checkpoint,
   not a formality — the user may add, cut, or reword items.
4. Write the contract by piping JSON matching
   `dod/contracts/task-dod.schema.json` into `dod-write.sh`:

   ```bash
   echo '{
     "created_at": "<ISO8601 timestamp>",
     "blast_radius": { "tier": "low|medium|high", "reason": "<why>" },
     "requirements": [
       { "text": "<requirement text>", "origin": "prompt|follow-up|derived", "added_at": "<ISO8601 timestamp>" }
     ]
   }' | bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-write.sh"
   ```

   `task_key` is injected automatically by the writer from the resolved
   session/task identity — do not set it yourself. The writer enforces
   append-only history: `created_at` and `blast_radius` become immutable
   after the first write, and existing requirement text can never be
   dropped or reworded, only added to.

5. Continue with implementation. The Stop hook (`dod-gate.sh`) will block
   completion until a matching verification result exists for this
   contract — that is a separate skill/process, not something this skill
   runs.

## What this skill does NOT do

- It does not run tests, lint, or any check — that is verification's job.
- It does not decide whether verification passed — it only records what
  "done" means for this task.
- It is not triggered by a hook. If you skip it, no DoD gets collected, and
  the Stop gate has nothing to check against — that is deliberate: this
  plugin's automatic PostToolUse nudge was removed because it false-
  positived on non-implementation turns.
