---
name: dod-verify
description: Run the Definition-of-Done checks for the currently open contract and write a verification result. Invoke as /dod:verify. Use after implementation work, when claiming a task done, or when the Stop gate blocks asking for it.
---

# /dod:verify

Runs the contract's checks and judgements against the current changeset and
writes a `result.json` the gate can trust. Runs `check` requirements
directly, skipping ones already resolved for this exact diff or waived by
the user, and spawns `dod-reviewer` for `judgement` requirements, lazily
resolving pre-existing failures against a baseline worktree.

**Run this yourself, without being asked — and without asking.** The moment
you believe a task covered by an open contract is done, run `/dod:verify` in
that same turn before you stop. Do not tell the user to run it, do not wait
for the gate to block first, and do not ask the user whether you should run
it — not even for a trivial diff (a comment, a rename, a one-line change).
There is no diff small enough to justify checking in first: asking is the
same skipped-self-invoke failure mode as never running it at all, just
phrased as a question instead of silence. A block is the fallback for when
this was skipped, not the intended trigger, and neither is a permission
check.

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
   If no contract is open, tell the user to run `/dod:define` first — do
   not mark verification in progress for a contract that doesn't exist.

2. **Mark verification in progress**, once step 1 confirmed a contract is
   actually open:
   ```bash
   state_set_state ".dod/$TASK_KEY/state.json" "verifying"
   ```
   This, before the check battery or the reviewer runs, is what lets the
   gate tell you "wait, it's already running" instead of "run /dod:verify"
   if your turn ends (e.g. the background reviewer is still in flight)
   before the result gets written below.

3. **Hash the diff.** `dod_diff_hash "$PWD" "$CONTRACT_BASELINE_SHA"` — the
   same function `gate.sh` uses, against the same baseline (never `HEAD`: a
   commit moves HEAD and would silently invalidate every prior result even
   when the working tree is unchanged). This value becomes the result's
   trust key.

4. **Run each `check` requirement's command.** First check whether the
   contract waives it (`CONTRACT_WAIVERS`, from step 1's `contract_read`):
   if the requirement's `id` appears there, set `verdict` to `"waived"` and
   `reason` to the waiver's own `reason` text — do **not** run the command
   at all, and do not consult or populate the cache for a waived
   requirement (there is no exit code to cache). Otherwise, look up the
   cache:
   ```bash
   CACHED=$(state_cache_get ".dod/$TASK_KEY/state.json" "$DIFF_HASH" "$CMD")
   ```
   On a hit, reuse `$CACHED` as `verdict` and skip re-running the command —
   the key is `(diff_hash, cmd)`, so any change to the diff already changes
   `DIFF_HASH` and misses the cache automatically; nothing to invalidate by
   hand. On a miss, run the command, capture its exit code, set `verdict` to
   `"pass"` if `exit == expect_exit` else `"fail"`, then
   `state_cache_set ".dod/$TASK_KEY/state.json" "$DIFF_HASH" "$CMD" "$verdict"`.
   Keep the command's output on a miss — needed for `/dod:verify`'s own
   summary.

   **On a failing check only** (lazy, never eager for passing checks),
   resolve whether the failure is pre-existing or something this changeset
   introduced:
   ```bash
   WT=$(dod_baseline_worktree "$PWD" "$TASK_KEY" "$CONTRACT_BASELINE_SHA")
   ```
   If `WT` resolves, re-run **that one failing command** inside it (`cd "$WT"
   && <cmd>`, or the tool-appropriate equivalent — never the main working
   tree). Record the outcome as `baseline_verdict`: `"pass"` if it exits
   `expect_exit` there too (meaning the failure is **new**, introduced by
   this changeset — no escape, must fix), `"fail"` if it also fails at
   baseline (**pre-existing** — boyscout default is still to fix it, but it
   is not something this session broke). If the worktree can't be created
   (`WT` empty), omit `baseline_verdict` entirely rather than guessing — do
   not report "pre-existing" without having actually run the command at
   baseline. The worktree is a `git worktree` sharing this repo's `.git` and
   its own separate checkout at `.dod/$TASK_KEY/baseline-worktree` — created
   once per task and reused across every failing check in every round;
   `gate.sh` tears it down when the task passes (branch 10).

5. **Run each `judgement` requirement by spawning `dod-reviewer`.** Use the
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

6. **Write the result, then mark verification done.** Via `dod/lib/result.sh`'s
   `result_write` — do not construct or edit `result.json` any other way (N6):

   ```bash
   result_write ".dod/$TASK_KEY/result.json" \
     --diff-hash "$DIFF_HASH" \
     --baseline-sha "$CONTRACT_BASELINE_SHA" \
     --round "$((STATE_ROUND + 1))" \
     --requirements '[
       {"id":"tests","type":"check","verdict":"pass|fail","cmd":"...","exit":N},
       {"id":"lint","type":"check","verdict":"waived","cmd":"...","reason":"user: prototype spike"},
       {"id":"review","type":"judgement","verdict":"pass|fail","findings":[...]}
     ]'
   state_set_state ".dod/$TASK_KEY/state.json" "idle"
   ```
   Clear `state` back to `"idle"` right after — leaving it `"verifying"`
   only means a possible future turn gets a slightly misleading "wait,
   it's running" message for one round, not a correctness problem, but
   clear it promptly anyway.

7. **Arm the claim latch** — the gate only engages once the agent has
   declared the task done:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-claim.sh" "$PWD" "$TASK_KEY"
   ```

8. **Print the pass table.** One row per requirement — **every** requirement,
   with no exceptions for a waived or not-applicable one: id, verdict, and
   (checks) command or (judgements) blocking/advisory finding counts. A
   `"waived"` verdict's row states the waiver's `reason` verbatim, and an
   `"n/a"` verdict's row states why it doesn't apply — "passed" must never
   quietly mean "passed the ones that were actually checked." On all-pass
   (accounting for waived/n/a as satisfied), tell the user the DoD is
   satisfied. On failure, list which requirements failed — for a failing
   `check` with a `baseline_verdict`, state it plainly ("pre-existing — also
   fails at baseline" vs "new — passes at baseline, this changeset broke
   it"), since that distinction is exactly what tells the user whether to
   expect a fix in scope; for `review`, list every `blocking` finding's
   file, line, and summary; advisory findings are listed too but flagged as
   the user's decision, never auto-fixed (per the repo's standing rule:
   raise non-blocking findings, never silently fix or drop them). The
   gate's own block message will restate check failures, but the agent
   should not wait for the block to inform the user.

## After verify

Stop normally. The gate reads `result.json` against the current diff hash —
if you've verified and haven't edited anything since, it releases. If you
edit again after verifying, the diff hash changes and the gate will demand a
fresh `/dod:verify`.
