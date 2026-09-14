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

Invoke this skill at the point where you are about to start making product
changes for a task — not before, not automatically on every file touch.

**Collection is not one-shot.** The DoD can change mid-task: new
instructions surface, scope grows, the user adds a requirement. Whenever
that happens, re-run the fold/assemble procedure below (steps 1-5) and
write the updated list — the writer (`dod-write.sh`) is append-only, so
existing requirements are never dropped or reworded, only new ones are
added. Do not treat "a `task-dod/<task_key>.json` already exists" as a
reason to skip re-assembly; it is a reason to append to it.

Do not invoke this for:
- Read-only exploration, research, or discussion turns.
- Planning turns (plan mode) where no code is being written yet.
- Trivial one-line fixes where the user has not asked for a DoD-worthy task.

## What to do

Assemble the **effective DoD** by folding these sources together, low → high
precedence (higher wins on conflict), then dedupe into one requirements list:

1. **Base DoD** — read `${CLAUDE_PLUGIN_ROOT}/docs/base-dod.md`. Fold each
   checklist item in as a requirement (tests green, lint green if
   configured, app starts, changeset-scoped independent review, no open
   review findings, re-verified after fixes, verification real not
   synthetic, deploy target stated) — see step 5 below for which of these
   are config-conditional.
2. **Your own active instructions** — the standing completion / DoD /
   quality standards governing you this session, *however provided* (system
   prompt, project/user instructions, enterprise policy — no assumed file or
   location). This keeps the harness **setup-agnostic**: it adapts to
   whatever instructions you actually run under.
3. **Task-stated verifications** — from the user's request, draft a short
   list of concrete, verifiable requirements — each one something you can
   later check pass/fail, not a vague goal. Example: "Stop hook blocks only
   when a task-dod file exists and no matching verified-result exists" is
   verifiable; "improve the plugin" is not.
4. **Explicit user instructions this session.**
5. **Config-detected baseline** — run `dod-verify-detect.sh` to get the
   effective config, then seed baseline requirements **only when
   configured**: a `test` requirement always (tests are step 2 of
   verification unconditionally), a `lint` requirement only if a lint
   command is configured, an `app-start` requirement only if
   `start`/`start_check_cmd`/`deploy_check_cmd` is configured. Mirrors
   `dod-verify-triage.sh`'s own applicability logic so collection and
   verification never disagree about what's in scope:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-verify-detect.sh"
   ```

**Never silently drop a folded item:** each becomes a requirement, or — if
genuinely unenforceable — gets flagged to the user as a likely escalation
candidate with a reason; it is never dropped without a trace.

Then:

6. Assess blast radius: `low` (isolated, easily reverted), `medium`
   (touches shared code paths but contained), or `high` (crosses module
   boundaries, affects other consumers, hard to revert) — with a one-line
   reason.
7. Confirm the combined, deduped list with the user before writing it. This
   is a checkpoint, not a formality — the user may add, cut, or reword
   items.
8. Write the contract by piping JSON matching
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

9. Continue with implementation. The Stop hook (`dod-gate.sh`) will block
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
