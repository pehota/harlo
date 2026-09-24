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

**Settle your own observations first.** Before running `/dod:verify`,
handle every note an implementer subagent returned and everything you
noticed yourself about the changeset: a suspected bug or spec violation →
fix it (delegate the fix) before verifying; everything else (polish,
wording, "could mention", anything the checks or the reviewer already
cover) → drop it. None of it reaches the user as a finding or a decision,
and none of it is passed to `dod-reviewer` as a hint — that would bias the
independent review.

## Steps

1. **Load the contract.** Assert `status == "open"`:
   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/contract.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/result.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/gitref.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/state.sh"

   TASK_KEY=$(dod_task_key "$PWD")
   contract_read ".dod/$TASK_KEY/contract.json"
   state_read ".dod/$TASK_KEY/state.json"
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

4. **Run each `check` requirement's command.** First, the `e2e` and
   `scenario` requirements specifically: for each, if its `applicable` field
   is `false`, set `verdict` to `"n/a"` and `reason` to its recorded `reason`
   from the contract — do **not** attempt to run its `cmd` (it's `null` by
   construction) and do not consult or populate the cache for it. If
   `applicable` is `true`, treat it like any other check requirement from
   here on.

   `docs` is handled differently — it never has a `cmd`, applicable or not.
   If `applicable` is `false`, set `verdict` to `"n/a"` and `reason` to its
   recorded `reason`, same as e2e/scenario. If `applicable` is `true`, do
   **not** attempt to run anything for it here — its verdict is decided in
   step 5 by whether `dod-reviewer` confirms every path in its `doc_paths`
   was actually updated; carry `doc_paths` through to the reviewer call
   unchanged (it's already part of `$CONTRACT_REQUIREMENTS`) and set `docs`'s
   final `verdict` from the reviewer's findings: `"fail"` if any finding in
   the reviewer's `findings` array carries `requirement_id: "docs"` with
   `severity: "blocking"`, else `"pass"`. At review depth `scope` (step 5)
   the reviewer does not check docs: set an applicable `docs`'s `verdict` to
   `"waived"` with `reason` `"review at scope depth"`. Use `requirement_id` for this
   check, never infer it from a finding's `file` path matching a
   `doc_paths` entry — the field exists precisely so attribution doesn't
   depend on string matching.

   For every other `check` requirement (and an applicable `e2e` or
   `scenario`), check
   whether the contract waives it (`CONTRACT_WAIVERS`, from step 1's
   `contract_read`):
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

   **Every round, first compute the reviewer's context inputs:**
   ```bash
   CHANGED_STANDARDS=$(dod_changed_standards "$PWD" "$CONTRACT_BASELINE_SHA")
   ```
   - `brief` — from `$CONTRACT_BRIEF`: its `path` if `applicable:true`, else
     `n/a: <its reason>`.
   - `changed_standards` — `$CHANGED_STANDARDS` (a JSON array, recomputed
     every round, never carried over).
   - `depth` — `scope` if `$CONTRACT_WAIVERS` has an entry with
     `id: "review"` (the user consented to a scope-only review), else `full`.

   **Round 1** (no prior `result.json`, or the prior result's round is being
   superseded by fresh work — i.e. this is the first verify pass for the
   current diff_hash lineage — or the prior result's `review` findings
   contain a blocking `lens:"scope"`, `kind:"creep"` finding, i.e. that review
   stopped at the scope lens and lenses 2-6 never ran): spawn in `full` mode.
   ```
   baseline_sha : $CONTRACT_BASELINE_SHA
   mode         : full
   task         : $CONTRACT_TASK
   works_when   : $CONTRACT_WORKS_WHEN
   requirements : $CONTRACT_REQUIREMENTS
   brief        : <brief path | n/a: reason>
   changed_standards : $CHANGED_STANDARDS
   depth        : full | scope
   ```

   **Round 2+** (a prior `result.json` exists for this task with `blocking`
   findings from the `review` requirement, none of them a `lens:"scope"`,
   `kind:"creep"` finding — i.e. the agent already ran `/dod:verify` once,
   got a `fail` verdict on `review` from a review that ran every lens, fixed
   something, and is verifying again): spawn in `delta_reconfirm` mode,
   passing the prior round's blocking findings back as `reconfirm`:
   ```
   baseline_sha : $CONTRACT_BASELINE_SHA
   mode         : delta_reconfirm
   delta_from   : <prior result's diff_hash>
   reconfirm    : <prior round's review findings with severity "blocking", except lens "scope">
   task         : $CONTRACT_TASK
   works_when   : $CONTRACT_WORKS_WHEN
   requirements : $CONTRACT_REQUIREMENTS
   brief        : <brief path | n/a: reason>
   changed_standards : $CHANGED_STANDARDS
   depth        : full | scope
   ```
   Leave `lens: "scope"` findings out of `reconfirm` — the scope check
   re-runs over the full changeset every round and re-raises any that still
   hold. After a creep stop — whether the user chose revert or accept &
   amend — the next round is always Round 1 (`full`), so the original
   changeset gets every lens and an impact trace.

   **After the user's advisory decision** (`state_read` gives a non-empty
   `$STATE_DECISIONS`, see "Advisory decision" below): add
   `blocking_only : true` to either mode's inputs — the reviewer reports
   blocking findings only.

   The reviewer's final message is JSON: `{"depth":"...","findings":[...],
   "impact_trace":[...],"reconfirm":[...],"verdict":"pass|fail"}` (full
   schema in `dod/agents/dod-reviewer.md`). Parse it — do not paraphrase or
   re-summarize it yourself, pass the `findings` array, `depth` and
   `impact_trace` through to step 6 as-is, every finding with its `lens`
   (and a scope finding's `kind`). The requirement's own
   `verdict` in `result.json` is the reviewer's `verdict` field: `"fail"` if
   any finding has `severity: "blocking"` or any `reconfirm` entry has
   `status != "fixed"`, else `"pass"`.

6. **Write the result, then mark verification done.** Via `dod/lib/result.sh`'s
   `result_write` — do not construct or edit `result.json` any other way (N6):

   ```bash
   RFILE=".dod/$TASK_KEY/result.json"
   ROUND=$(result_next_round "$RFILE" "$CONTRACT_BASELINE_SHA")
   REQUIREMENTS=$(jq -nc --arg depth "$REVIEW_DEPTH" \
       --argjson findings "$REVIEW_FINDINGS" \
       --argjson impact_trace "$REVIEW_IMPACT_TRACE" '[
       {"id":"tests","type":"check","verdict":"pass|fail","cmd":"...","exit":N},
       {"id":"lint","type":"check","verdict":"waived","cmd":"...","reason":"user: prototype spike"},
       {"id":"review","type":"judgement","verdict":"pass|fail","depth":$depth,"findings":$findings,"impact_trace":$impact_trace},
       {"id":"docs","type":"check","verdict":"pass|fail|n/a","doc_paths":[...]}
     ]')
   result_write "$RFILE" \
     --diff-hash "$DIFF_HASH" \
     --baseline-sha "$CONTRACT_BASELINE_SHA" \
     --round "$ROUND" \
     --requirements "$REQUIREMENTS"
   state_set_state ".dod/$TASK_KEY/state.json" "idle"
   ```
   `$REVIEW_FINDINGS` is the reviewer's `findings` array from step 5,
   unchanged — every finding keeps its `lens` and, for scope findings, its
   `kind` (the gate reads `lens:"scope"` + `kind:"creep"` to stop instead of
   asking for a fix). `$REVIEW_DEPTH` and `$REVIEW_IMPACT_TRACE` are the
   reviewer's `depth` string and `impact_trace` array, also unchanged
   (`impact_trace` is `[]` after a creep stop or at depth `scope`) — the
   `review` entry records them as `docs/design-v2.md` §6.4 documents;
   `result_write` stores extra fields as given.
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
   (checks) command or (judgements) finding counts — a failing round's
   judgement row states its blocking count only (its advisories, if any, are
   ignored per "Failing round" below); the passing/decision round's
   judgement row states both blocking (always 0 there) and advisory counts.
   A `"waived"` verdict's row states the waiver's `reason` verbatim, and an
   `"n/a"` verdict's row states why it doesn't apply — "passed" must never
   quietly mean "passed the ones that were actually checked." For `docs`,
   the row states `n/a` with the contract's reason, `pass` if the reviewer
   confirmed every `doc_paths` entry was updated, or `fail` with which
   path(s) it found missing or stale (`dod/base-dod.md`, `dod-define` step 4).
   At review depth `scope`, the `review` row states "scope depth" with the
   user's waiver reason verbatim, and `docs` states `waived — review at
   scope depth`.

   Findings you show come **only** from this round's reviewer `findings[]` —
   never add your own, and never promote implementer
   notes, reviewer prose outside `findings[]`, or your own observations into
   findings or user decisions (those were settled before verify, see above).
   Advisories are never auto-fixed. Then, by outcome — exactly one applies:

   - **Scope creep — a blocking `lens:"scope"`, `kind:"creep"` finding.**
     This is the user's decision, never a fix: do **not** delegate any fix,
     for the creep or anything else this round. Show each creep finding
     (file, line, summary), then ask the user, per finding: **revert** (undo
     the change) or **accept & amend** (widen the task to include it). Then
     stop. On **revert** → delegate reverting exactly those hunks, then run
     `/dod:verify`. On **accept & amend** → run `/dod:define` to amend the
     contract, widening the task and keeping the baseline (see its amend
     section), then run `/dod:verify`. Either way that next review runs in
     `full` mode (step 5) — the creep stop skipped lenses 2-6.
   - **Failing round** (no creep). List which requirements failed: for a failing
     `check` with a `baseline_verdict`, state it plainly ("pre-existing —
     also fails at baseline" vs "new — passes at baseline, this changeset
     broke it"); for `review`, every `blocking` finding's file, line, and
     summary. Then delegate the fixes — a `kind:"gap"` finding is a normal
     fix: the implementer completes the missing part of the task. Every fix
     delegation passes the context brief's path (when applicable) and tells
     the implementer to read it before editing. Do not list advisories or raise them as decisions: a failing
     round's advisories are ignored — only the final passing round's review
     raises the advisories the user decides on (a gate escalation is the
     one exception, see "After verify"). The gate's block
     message will restate check failures; don't wait for it to inform the
     user.
   - **All pass, advisories, `$STATE_DECISIONS` is `[]`** (the user has not
     decided yet). The contract stays open awaiting the user. Show **one**
     advisory table, every advisory once: id, file:line, short summary, and
     your fix/skip recommendation with its reason. Ask the user to decide fix or skip per
     id, then stop — the gate lets you stop while the decision is pending.
   - **All pass, and no advisories or `$STATE_DECISIONS` non-empty.** Tell
     the user the DoD is satisfied; the gate closes the contract when you
     stop. The decision is asked once per contract: once recorded, raise no
     advisory as a decision again — not even a new one this round.

## After verify

Stop normally. The gate reads `result.json` against the current diff hash —
if you've verified and haven't edited anything since, it releases. If you
edit again after verifying, the diff hash changes and the gate will demand a
fresh `/dod:verify`.

If the gate escalates (budget exhausted / no progress), that round is final:
report its unresolved findings and — unlike a normal failing round — also
list that round's advisories from
`result.json`'s `findings[]` once — file:line, summary — then stop. Do not
ask a fix/skip decision: the contract closes as escalated, so nothing
records or gates one.

## Advisory decision

On the user's reply to step 8's advisory table, record one decision per
advisory id of that result, through `lib/state.sh` only (N6). It rejects a
reply that leaves an advisory undecided — ask again for the missing ones:

```bash
result_read ".dod/$TASK_KEY/result.json"
state_record_decisions ".dod/$TASK_KEY/state.json" \
  '[{"id":"a1","decision":"fix"},{"id":"a2","decision":"skip"}]' \
  "$RESULT_DIFF_HASH" "$RESULT_ADVISORY_IDS"
bash "${CLAUDE_PLUGIN_ROOT}/scripts/dod-claim.sh" "$PWD" "$TASK_KEY"
```

- **All skip** → stop; the gate closes the contract.
- **Any fix** → fix only those (delegate, passing the context brief's path
  as for any fix), then run `/dod:verify`. That
  round's review is blocking-only (step 5); the gate blocks a close until
  the changeset has changed and been re-verified.
