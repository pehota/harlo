---
name: dod-define
description: Open a Definition-of-Done contract for the current task before implementation begins. Invoke as /dod:define [task text]. MANDATORY self-invoke, before your first edit, the moment a task is clear — do not wait to be asked, do not treat this as optional.
---

# /dod:define

Opens a DoD contract for the current task. Every contract carries the
detected test command plus a `judgement` requirement for an independent
review, and any waivers the user stated in free text.

**Run this yourself, before your first edit, every time.** Not optional,
not a fallback — the moment a task's shape is clear, call this before
touching any file, the same way you self-invoke `/dod:verify` when you
believe the task is done. Skipping it is a compliance failure, not a style
choice; `track.sh`'s nudge and the user running it themselves are the
safety net for when you fail, not the plan.

## Steps

1. **Preflight.** Confirm this is a git repository (`git rev-parse --git-dir`).
   If not, refuse and say why — do not open a contract outside a git repo.
   Confirm `jq` is on PATH; if missing, refuse and name the install command.

2. **Task capture.** If the user gave task text as an argument, use it
   verbatim (`task_source: "argument"`). Otherwise derive one sentence from
   the current conversation (`task_source: "conversation"`).

3. **Detect the test command.** Look for, in order: `package.json` `scripts.test`
   (`npm test` / the project's package manager equivalent), a `Makefile` `test`
   target (`make test`), `cargo test` (`Cargo.toml` present), `pytest`
   (`pyproject.toml` / `setup.py` present). Use the first match. If nothing is
   detected, ask the user for the test command — do not guess a command that
   might not exist.

3.4. **Decide e2e applicability, right now, with a recorded reason.** Every
   contract carries an `e2e` requirement — never absent. Decide at definition
   time (not later, not left to the reviewer): does this task add or change
   a user-facing flow? If yes, set `applicable:true` and give it a `cmd` (the
   project's e2e runner, e.g. `npm run e2e`, `playwright test` — detect it
   the same way as step 3, or ask if none is detectable and the task truly
   needs one). If no — a pure refactor, an internal tooling change, docs,
   test-only changes — set `applicable:false` with a short concrete `reason`
   ("pure refactor, no user-facing change", "internal harness script, no
   e2e flow exists"). Never leave `e2e` out of the requirements array and
   never fabricate a reason that doesn't hold up.

3.5. **Extract waivers from the user's own words.** A waiver excuses a
   specific requirement from blocking, on the user's authority alone — it is
   never something the agent decides for itself. Only recognise a waiver
   when the user's task text (or a reply during confirmation, step 4)
   explicitly names a requirement and excuses it — "skip lint for this, it's
   a prototype spike," "don't bother with e2e, pure refactor," "waive the
   review, I've already eyeballed it." Silence about a requirement is not a
   waiver; inferring one because a task "looks small" is exactly the
   silent-skip failure mode this harness exists to prevent. Each waiver
   becomes `{"id": "<requirement id>", "reason": "user: <their words,
   paraphrased>"}` — the `"user: "` prefix marks it as user-sourced, never
   agent-invented, and is load-bearing for the pass table (step 8 of
   `/dod:verify`) and any later audit of why a requirement didn't gate.

4. **Present the verification table and wait for confirmation — this
   blocks.** Before writing anything, show the user exactly what will
   decide "done", using this template:

   ```
   Here's how I will verify the task is done:

   | Verification | Expected Result | Why This Verification |
   |---|---|---|
   | <cmd>         | exit 0           | <one clause: detected/task-stated/protocol> |
   | e2e (<cmd> or N/A) | exit 0 or N/A | <applicable: task-stated reason / inapplicable: your reason from step 3.4> |
   | independent code review | no blocking findings | protocol-required |
   | lint          | WAIVED           | user: prototype spike |

   Does this look right? (yes / adjust / cancel)
   ```

   The review row is **always present** — every contract carries a
   `judgement` requirement for `dod-reviewer`, not just check commands. The
   e2e row is likewise **always present** (step 3.4) — if inapplicable, its
   "Expected Result" reads `N/A` and "Why This Verification" carries your
   recorded reason, never silently dropped from the table because it isn't a
   real command. A waived requirement (step 3.5) still gets its own row —
   "Expected Result" reads `WAIVED` and "Why This Verification" carries the
   user's own reason verbatim, never omitted from the table just because it
   won't block.

   One row per requirement. "Why This Verification" is never blank — say
   where the requirement came from (`auto-detected` from step 3,
   `task`-stated, `protocol`-required, or the user's waiver text). Do **not**
   proceed to step 5 (baseline recording) or step 6 (contract write) until
   the user replies. `yes` (or equivalent) continues; a correction updates
   the requirements **and waivers** and re-shows the table; `cancel` aborts —
   no baseline is recorded and no contract is written.

   **Why this blocks:** a printed "Contract Opened" table that nobody has to
   look at is a formality, not a check — exactly as ignorable as no
   confirmation at all. The verification list IS the definition of done for
   this task; the user must actually see and accept it before it starts
   governing the gate.

   **This blocks implementation too, not just the contract write.** Do not
   make any edit toward the task — not a "quick start while waiting," not a
   speculative first file — until the user has replied. The table you're
   showing is what the user is being asked to approve; starting work before
   they answer defeats the confirmation regardless of whether `contract.json`
   itself is written yet. If you're already mid-implementation when you
   realize a contract should exist (a follow-up `/dod:define` after the fact),
   say so plainly rather than silently back-dating the baseline.

5. **Record the baseline**, immediately after confirmation, immediately
   before writing the contract:
   ```
   HEAD_SHA=$(git rev-parse HEAD)
   ```
   Minimise the window between snapshotting HEAD and allowing edits.

6. **Write the contract** via `dod/lib/contract.sh`'s `contract_write` — do
   not construct or edit `contract.json` any other way (N6: `contract.sh` is
   the sole owner):

   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/contract.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/gitref.sh"

   TASK_KEY=$(dod_task_key "$PWD")
   contract_write ".dod/$TASK_KEY/contract.json" \
     --task-key "$TASK_KEY" \
     --task "<task text>" \
     --task-source "argument|conversation" \
     --session-id "<session id if known, else empty>" \
     --baseline-sha "$HEAD_SHA" \
     --requirements '[
       {"id":"tests","type":"check","cmd":"<detected cmd>","expect_exit":0,"source":"auto-detected"},
       {"id":"e2e","type":"check","cmd":"<e2e cmd>","expect_exit":0,"source":"task","applicable":true,"reason":"<why it applies>"},
       {"id":"review","type":"judgement","agent":"dod-reviewer","source":"protocol"}
     ]' \
     --waivers '[{"id":"lint","reason":"user: prototype spike"}]'
   ```
   If e2e is inapplicable (step 3.4), its entry takes this shape instead —
   `cmd` and `expect_exit` **both `null`**, `applicable:false`, and a
   non-empty `reason`; never mix an `applicable:true`/`false` field with the
   other branch's `cmd`/`expect_exit` shape, `contract_write` rejects it:
   ```
   {"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"<why it doesn't apply>"}
   ```
   Omit `--waivers` (or pass `'[]'`) when step 3.5 found none — do not
   fabricate an empty-reason waiver just to fill the flag.

7. **Confirm the contract is open** with a short one-line note (SHA + "ready
   to start") — the verification table already shown in step 4 is the
   substance; don't repeat it. **Then start implementing the task
   immediately, in this same turn.** The user's "yes" in step 4 approved both
   the verification list AND starting work — it is not a separate go-ahead
   you wait to be asked for again. Do not stop and hand control back after
   writing the contract; the contract write is a means to the task, not the
   task itself.

8. **Tell the agent, not the user, to verify.** State plainly: when you
   believe this task is done, run `/dod:verify` yourself before you stop — do
   not tell the user to run it and do not wait for them to ask. The Stop gate
   will block and name the reason if you skip this, but don't rely on the
   gate to catch it; treat "run /dod:verify" as your own next action at the
   moment you'd otherwise claim done, in the same turn, not a request to
   relay.

## If a contract is already open for this branch

Amend it: re-run steps 2–4 (capture, detect, **confirm the table again** — an
amend changes what "done" means, so it needs the same confirmation a fresh
open does) before `contract_write` for the same `task_key`. There is no
separate "fresh task" flag — amend always overwrites the existing contract
for this `task_key`, same confirmation gate either way.
