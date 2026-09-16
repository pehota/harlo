---
name: dod-define
description: Open a Definition-of-Done contract for the current task before implementation begins. Invoke as /dod:define [task text]. Use at the start of implementation work, before the first edit.
---

# /dod:define

Opens a DoD contract for the current task. **Skeleton (Phase 1):** the
contract's single requirement is the detected test command — the battery
detector, waiver extraction, e2e applicability and the reviewer's judgement
requirement all land in Phase 2 (`docs/design-v2.plan.md`).

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

4. **Present the verification table and wait for confirmation** (D4,
   amended: this now blocks — see the note below). Before writing anything,
   show the user exactly what will decide "done", using this template:

   ```
   Here's how I will verify the task is done:

   | Verification | Expected Result | Why This Verification |
   |---|---|---|
   | <cmd>         | exit 0           | <one clause: detected/task-stated/protocol> |

   Does this look right? (yes / adjust / cancel)
   ```

   One row per requirement. "Why This Verification" is never blank — say
   where the requirement came from (`auto-detected` from step 3,
   `task`-stated, or `protocol`-required). Do **not** proceed to step 5
   (baseline recording) or step 6 (contract write) until the user replies.
   `yes` (or equivalent) continues; a correction updates the requirements and
   re-shows the table; `cancel` aborts — no baseline is recorded and no
   contract is written.

   **Why this blocks, reversing D4's "no blocking questions":** a printed
   "Contract Opened" table that nobody has to look at is a formality, not a
   check — found in practice to be exactly as ignorable as no confirmation at
   all. The verification list IS the definition of done for this task; the
   user must actually see and accept it before it starts governing the gate.
   Recorded as D29 in `docs/design-v2.md`.

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
     --requirements '[{"id":"tests","type":"check","cmd":"<detected cmd>","expect_exit":0,"source":"auto-detected"}]'
   ```

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
open does) before `contract_write` for the same `task_key`. `--new` (explicit
user request) instead opens a fresh task, replacing the file outright, same
confirmation gate.
