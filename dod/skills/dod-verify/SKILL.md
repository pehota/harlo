---
name: dod-verify
description: Run the Definition-of-Done checks for the currently open contract and write a verification result. Invoke as /dod:verify. Use after implementation work, when claiming a task done, or when the Stop gate blocks asking for it.
---

# /dod:verify

Runs the contract's checks and judgements against the current changeset and
writes a `result.json` the gate can trust. Runs `check` requirements
directly and spawns `dod-reviewer` for `judgement` requirements (Phase 2
item 2). The baseline worktree, cache, and the pass-table's waiver/n/a
columns remain Phase 2 items still to land (`docs/design-v2.plan.md`).

**Run this yourself, without being asked.** The moment you believe a task
covered by an open contract is done, run `/dod:verify` in that same turn
before you stop — never tell the user to run it and never wait for the gate
to block first. A block is the fallback for when this was skipped, not the
intended trigger.

## Steps

1. **Load the contract.** Assert `status == "open"`:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/contract.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/result.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/gitref.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/state.sh"

   TASK_KEY=$(dod_task_key "$PWD")
   contract_read ".dod/$TASK_KEY/contract.json"
   ```
   If no contract is open, tell the user to run `/dod:define` first.

2. **Hash the diff.** `dod_diff_hash "$PWD" "$CONTRACT_BASELINE_SHA"` — the
   same function `gate.sh` uses, against the same baseline (never `HEAD`: a
   commit moves HEAD and would silently invalidate every prior result even
   when the working tree is unchanged). This value becomes the result's
   trust key.

3. **Run each `check` requirement's command.** Capture its exit code.
   `verdict` is `"pass"` if `exit == expect_exit`, else `"fail"`. Keep the
   command's output — needed for `/dod:verify`'s own summary and, in Phase 2,
   for `evidence/`.

4. **Run each `judgement` requirement by spawning `dod-reviewer`.** Use the
   `Task` tool with `subagent_type: dod-reviewer` (or the equivalent agent
   invocation for this environment) — never review the changeset yourself
   and write its verdict; the whole point of a judgement requirement is a
   **fresh, independent** reviewer that forms its own opinion.

   **Round 1** (no prior `result.json`, or the prior result's round is being
   superseded by fresh work — i.e. this is the first verify pass for the
   current diff_hash lineage): spawn in `full` mode.
   ```
   baseline_sha : $CONTRACT_BASELINE_SHA
   mode         : full
   task         : $CONTRACT_TASK
   requirements : $CONTRACT_REQUIREMENTS
   ```

   **Round 2+** (a prior `result.json` exists for this task with `blocking`
   findings from the `review` requirement — i.e. the agent already ran
   `/dod:verify` once, got a `fail` verdict on `review`, fixed something, and
   is verifying again): spawn in `delta_reconfirm` mode, passing the prior
   round's blocking findings back as `reconfirm`:
   ```
   baseline_sha : $CONTRACT_BASELINE_SHA
   mode         : delta_reconfirm
   delta_from   : <prior result's diff_hash>
   reconfirm    : <prior round's review findings with severity "blocking">
   task         : $CONTRACT_TASK
   requirements : $CONTRACT_REQUIREMENTS
   ```

   The reviewer's final message is JSON: `{"findings":[...], "reconfirm":[...],
   "verdict":"pass|fail"}` (full schema in `dod/agents/dod-reviewer.md`).
   Parse it — do not paraphrase or re-summarize it yourself, pass the
   `findings` array through to `result_write` as-is. The requirement's own
   `verdict` in `result.json` is the reviewer's `verdict` field: `"fail"` if
   any finding has `severity: "blocking"` or any `reconfirm` entry has
   `status != "fixed"`, else `"pass"`.

5. **Write the result** via `dod/lib/result.sh`'s `result_write` — do not
   construct or edit `result.json` any other way (N6):

   ```bash
   result_write ".dod/$TASK_KEY/result.json" \
     --diff-hash "$DIFF_HASH" \
     --baseline-sha "$CONTRACT_BASELINE_SHA" \
     --round "$((STATE_ROUND + 1))" \
     --requirements '[
       {"id":"tests","type":"check","verdict":"pass|fail","cmd":"...","exit":N},
       {"id":"review","type":"judgement","verdict":"pass|fail","findings":[...]}
     ]'
   ```

6. **Arm the claim latch** — the gate only engages once the agent has
   declared the task done:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-claim.sh" "$PWD" "$TASK_KEY"
   ```

7. **Print the pass table.** One row per requirement: id, verdict, and
   (checks) command or (judgements) blocking/advisory finding counts. On
   all-pass, tell the user the DoD is satisfied. On failure, list which
   requirements failed — for `review`, list every `blocking` finding's file,
   line, and summary; advisory findings are listed too but flagged as the
   user's decision, never auto-fixed (per the repo's standing rule: raise
   non-blocking findings, never silently fix or drop them). The gate's own
   block message will restate check failures, but the agent should not wait
   for the block to inform the user.

## After verify

Stop normally. The gate reads `result.json` against the current diff hash —
if you've verified and haven't edited anything since, it releases. If you
edit again after verifying, the diff hash changes and the gate will demand a
fresh `/dod:verify`.
