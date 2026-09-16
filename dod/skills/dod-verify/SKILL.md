---
name: dod-verify
description: Run the Definition-of-Done checks for the currently open contract and write a verification result. Invoke as /dod:verify. Use after implementation work, when claiming a task done, or when the Stop gate blocks asking for it.
---

# /dod:verify

Runs the contract's checks against the current changeset and writes a
`result.json` the gate can trust. **Skeleton (Phase 1):** runs `check`
requirements only and reports pass/fail. The baseline worktree, cache,
judgement/reviewer orchestration, and the pass-table's waiver/n/a columns are
Phase 2 (`docs/design-v2.plan.md`).

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

2. **Hash the diff.** `dod_diff_hash "$PWD"` — the same function `gate.sh`
   uses. This value becomes the result's trust key.

3. **Run each `check` requirement's command.** Capture its exit code.
   `verdict` is `"pass"` if `exit == expect_exit`, else `"fail"`. Keep the
   command's output — needed for `/dod:verify`'s own summary and, in Phase 2,
   for `evidence/`.

4. **Write the result** via `dod/lib/result.sh`'s `result_write` — do not
   construct or edit `result.json` any other way (N6):

   ```bash
   result_write ".dod/$TASK_KEY/result.json" \
     --diff-hash "$DIFF_HASH" \
     --baseline-sha "$CONTRACT_BASELINE_SHA" \
     --round "$((STATE_ROUND + 1))" \
     --requirements '[{"id":"tests","type":"check","verdict":"pass|fail","cmd":"...","exit":N}]'
   ```

5. **Arm the claim latch** — the gate only engages once the agent has
   declared the task done:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-claim.sh" "$PWD" "$TASK_KEY"
   ```

6. **Print the pass table.** One row per requirement: id, verdict, command.
   On all-pass, tell the user the DoD is satisfied. On failure, list which
   requirements failed and their exit codes — the gate's own block message
   will restate this, but the agent should not wait for the block to inform
   the user.

## After verify

Stop normally. The gate reads `result.json` against the current diff hash —
if you've verified and haven't edited anything since, it releases. If you
edit again after verifying, the diff hash changes and the gate will demand a
fresh `/dod:verify`.
