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
   the current conversation (`task_source: "conversation"`) and print it back
   for the user to object to before continuing.

3. **Detect the test command.** Look for, in order: `package.json` `scripts.test`
   (`npm test` / the project's package manager equivalent), a `Makefile` `test`
   target (`make test`), `cargo test` (`Cargo.toml` present), `pytest`
   (`pyproject.toml` / `setup.py` present). Use the first match. If nothing is
   detected, ask the user for the test command — do not guess a command that
   might not exist.

4. **Record the baseline last**, immediately before writing the contract:
   ```
   HEAD_SHA=$(git rev-parse HEAD)
   ```
   Minimise the window between snapshotting HEAD and allowing edits.

5. **Write the contract** via `dod/lib/contract.sh`'s `contract_write` — do
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

6. **Print the contract** as a short table: task, baseline SHA, requirements.
   No blocking questions beyond step 2's objection window (D4: derive
   silently, print, don't interrogate).

## If a contract is already open for this branch

Amend it: re-run `contract_write` for the same `task_key`, updating `task` or
`requirements` as needed. `--new` (explicit user request) instead opens a
fresh task, replacing the file outright.
