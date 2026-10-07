---
name: dod-define
description: Open a Definition-of-Done contract for the current task before implementation begins. Invoke as /dod:define [task text]. MANDATORY self-invoke, before your first edit, the moment a task is clear — do not wait to be asked, do not treat this as optional.
---

# /dod:define

Opens a DoD contract for the current task. The whole definition follows one
chain: **agree the task → "how will we know it works?" (`works_when`) →
"how do we prove that?" (the requirements, each a proof of `works_when`)**.
`dod/base-dod.md` lists the proofs every contract carries.

Run this yourself, before your first edit, every time a task's shape is
clear — the same way you self-invoke `/dod:verify` when you believe the
task is done. `track.sh`'s nudge and the user running it themselves are the
safety net for when you fail, not the plan.

## Steps

1. **Preflight.** Confirm this is a git repository (`git rev-parse --git-dir`).
   If not, refuse and say why — do not open a contract outside a git repo.
   Confirm `jq` is on PATH; if missing, refuse and name the install command.

2. **Capture the task — and decide whether it is clear.** If the user gave
   task text as an argument, use it verbatim (`task_source: "argument"`).
   Otherwise derive one sentence from the current conversation
   (`task_source: "conversation"`). Then decide: could two careful engineers
   read it and build different things (what changes, where, what "better"
   means)? Test: can you name a concrete, checkable outcome without guessing?
   A relative target with no measure ("shorter", "faster", "less annoying",
   "cleaner") fails that test. If it fails, ask
   the user concrete clarifying questions and stop — no table, no contract —
   until the task is clear and agreed. If the conversation already settled
   it, proceed without re-asking.

   **The moment the task is agreed — and not before — spawn
   `dod-context-collector`**, before you write `works_when`. Use the `Task`
   tool with `subagent_type: dod-context-collector` (or the equivalent agent
   invocation for this environment), in the background, with:
   ```
   task       : <the agreed task text>
   brief_path : <REPO>/.dod/<TASK_KEY>/brief.md   (absolute; REPO and TASK_KEY as in step 8)
   ```
   It writes the context brief — the project standards and domain invariants
   relevant to this task — and returns one line of JSON:
   `{"applicable":true,"path":"..."}` or `{"applicable":false,"reason":"..."}`.
   That line is the brief's verdict; you relay it unchanged. **Never write,
   edit or summarise the brief yourself, and never declare it N/A yourself**
   — a fresh agent collects it so the implementer never picks which
   standards apply to its own work. Continue with steps 3-5 while it runs;
   await its verdict before step 6. If it returns no valid verdict, spawn it
   again — never substitute your own. An unclear task spawns nothing.

3. **Q1 — "How will we know it works?"** From the agreed task, write
   `works_when`: one sentence, "It works when <concrete observable outcome>"
   — what a user, caller, or reviewer would see or do, described without
   naming the functions, fields, or types that implement it. Write it so
   someone who has never read the code can tell whether the behaviour
   changed. Only drop to technical language when the task itself has no
   observable surface — a pure refactor, an internal perf fix, dependency
   plumbing — where "it works" genuinely means "the mechanism is correct,"
   not "a user would notice something." Everything below is a proof of this
   sentence.

4. **Q2 — "How do we prove that?"** Find what the repo offers — build, app
   start, test runner, e2e stack, docs, review — and list the proofs. Every
   requirement gets a non-empty `proves`: one clause naming which part of
   `works_when` it proves. This is judgement about *this* task: what would a
   careful engineer check before calling it done, which edge cases would
   "it compiles and the tests pass" miss? The mechanical checks stay
   auto-detected and deterministic regardless.

   - **Prerequisite — it builds/starts, so it is testable at all.** If the
     repo has a build or start step, it runs green before anything else can
     prove anything; fold it into the checks.
   - **Logic — tests (`tests`).** Look for, in order: `package.json`
     `scripts.test` (`npm test` / the project's package manager equivalent),
     a `Makefile` `test` target (`make test`), `cargo test` (`Cargo.toml`
     present), `pytest` (`pyproject.toml` / `setup.py` present). Use the
     first match. If nothing is detected, ask the user — do not guess a
     command that might not exist.
   - **Outcome — observe `works_when` directly (`e2e`, `scenario`).** Both
     are always present, decided now, never left to the reviewer:
     `applicable:true` with a `cmd`, or `applicable:false` with a concrete
     `reason`. `e2e`: see the applicability rule in `dod/base-dod.md`
     (see/do, not control flow). If applicable, find the runner (`npm run
     e2e`, `playwright test` — detect or ask); if the repo has none, mark
     `applicable:true` with `reason` noting the manual pass and no automated
     e2e, and check the real surface by hand. Either way, plan it as a local
     run before the change ships — start the app locally and drive it with
     the tools available (runner, browser automation) — never a check after
     release.
     `scenario`, decided independently: its `cmd` names the functional test
     the implementer must write and run — one that exercises the changed
     behavior the way a human would check it and observes the `works_when`
     outcome, not a mocked-out unit test. Agent, prompt and skill text IS
     observable behavior: prove it with a headless before/after run of the
     instructions. Mark `scenario` `applicable:false` only when another row
     already fully proves `works_when`, and say which. A task can be `e2e`
     N/A and `scenario` applicable at once.
   - **Described — docs (`docs`).** Does the task change anything a doc,
     README, ADR, or design note describes (behavior, a command's shape, a
     config option, an architecture decision)? If yes, `applicable:true` with
     every such path in `doc_paths`; if no, `applicable:false` with a
     concrete reason. Whether they were correctly updated is the review's
     call (`dod-reviewer` reads `doc_paths`).
   - **Independent — review (`review`).** Always present: a `judgement`
     requirement for `dod-reviewer`, which also judges whether each `proves`
     genuinely proves `works_when`.

   Never leave `e2e`, `scenario` or `docs` out, and never fabricate a reason
   that doesn't hold up.

5. **Extract waivers from the user's own words.** A waiver excuses a
   specific requirement from blocking, on the user's authority alone — it is
   never something the agent decides for itself. Only recognise a waiver
   when the user's task text (or a reply during confirmation, step 6)
   explicitly names a requirement and excuses it — "skip lint for this, it's
   a prototype spike," "don't bother with e2e, pure refactor," "waive the
   review, I've already eyeballed it." Silence about a requirement is not a
   waiver; inferring one because a task "looks small" is exactly the
   silent-skip failure mode this harness exists to prevent. Each waiver
   becomes `{"id": "<requirement id>", "reason": "user: <their words,
   paraphrased>"}` — the `"user: "` prefix marks it as user-sourced, never
   agent-invented, and is load-bearing for the pass table (step 8 of
   `/dod:verify`) and any later audit of why a requirement didn't gate.

   A `review` waiver never skips the review: it sets the **review depth** to
   `scope` — `dod-reviewer` runs the scope check only. You may *propose* it
   (e.g. for a one-line change), but only the user's own words create it,
   recorded like any waiver: `{"id":"review","reason":"user: <their
   words>"}` (`contract_write` rejects a `review` waiver without the
   `user: ` prefix).

6. **Present the verification table and wait for confirmation — this
   blocks.** Before writing anything, show the user exactly what will
   decide "done", using this template:

   ```
   Context brief: <brief path>   |   Context brief: N/A: <collector's reason>
   It works when: <works_when>

   Here's how I will prove it:

   | Verification | Expected Result | Proves |
   |---|---|---|
   | <test cmd> (auto-detected) | exit 0 | <which part of works_when> |
   | e2e (<cmd> or N/A) | exit 0 or N/A | <proves / N/A: your reason> |
   | scenario test (<cmd> or N/A) | exit 0 or N/A | <proves / N/A: which row already proves works_when> |
   | docs (<doc_paths> or N/A) | updated, confirmed by review / N/A | <proves / N/A: your reason> |
   | independent code review | no blocking findings | <proves> |
   | lint | WAIVED | user: prototype spike |

   Does this look right? (yes / adjust / cancel)
   ```

   The "Context brief" line relays the collector's verdict (step 2)
   verbatim — its path, or `N/A:` with its reason.
   One row per requirement, `e2e`/`scenario`/`docs`/review always present
   (N/A rows carry their reason, never dropped). "Proves" is the row's
   `proves` and is never blank; a waived row (step 5) carries the user's
   reason verbatim. A thin or boilerplate "Proves" is the signal to push back
   and adjust, not just accept. Do **not** proceed to step 7 (baseline) or
   step 8 (contract write) until the user replies. `yes` (or equivalent)
   continues; a correction updates `works_when`, the requirements **and
   waivers** and re-shows the table; `cancel` aborts — no baseline is
   recorded and no contract is written.

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

7. **Record the baseline**, immediately after confirmation, immediately
   before writing the contract:
   ```
   HEAD_SHA=$(git rev-parse HEAD)
   ```
   Minimise the window between snapshotting HEAD and allowing edits.

8. **Write the contract** via `dod/lib/contract.sh`'s `contract_write` — do
   not construct or edit `contract.json` any other way (N6: `contract.sh` is
   the sole owner):

   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/contract.sh"
   . "${CLAUDE_PLUGIN_ROOT}/lib/gitref.sh"

   REPO=$(dod_repo_root "$PWD")
   TASK_KEY=$(dod_task_key "$REPO")
   contract_write "$REPO/.dod/$TASK_KEY/contract.json" \
     --task-key "$TASK_KEY" \
     --task "<task text>" \
     --task-source "argument|conversation" \
     --session-id "<session id if known, else empty>" \
     --works-when "It works when <observable outcome>" \
     --baseline-sha "$HEAD_SHA" \
     --brief '<the collector's verdict JSON from step 2, unchanged>' \
     --requirements '[
       {"id":"tests","type":"check","cmd":"<detected cmd>","expect_exit":0,"source":"auto-detected","proves":"<which part of works_when>"},
       {"id":"e2e","type":"check","cmd":"<e2e cmd>","expect_exit":0,"source":"task","applicable":true,"reason":"<why it applies>","proves":"<...>"},
       {"id":"scenario","type":"check","cmd":"<scenario test cmd>","expect_exit":0,"source":"task","applicable":true,"reason":"<what behavior it exercises>","proves":"<the works_when outcome it observes>"},
       {"id":"review","type":"judgement","agent":"dod-reviewer","source":"protocol","proves":"<...>"},
       {"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":true,"doc_paths":["<doc path 1>","<doc path 2>"],"reason":"<why these docs need updating>","proves":"<...>"}
     ]' \
     --waivers '[{"id":"lint","reason":"user: prototype spike"}]'
   ```
   `REPO` is the git top-level, never `$PWD` itself — the Bash tool's cwd
   may be a subdir, and the hooks key `.dod/` on the top-level too; every
   `.dod/` path is anchored at `$REPO`.
   If e2e is inapplicable (step 4), its entry takes this shape instead —
   `cmd` and `expect_exit` **both `null`**, `applicable:false`, and a
   non-empty `reason`; never mix an `applicable:true`/`false` field with the
   other branch's `cmd`/`expect_exit` shape, `contract_write` rejects it:
   ```
   {"id":"e2e","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"<why it doesn't apply>","proves":"n/a: <reason>"}
   ```
   `scenario` follows the identical shape rules as `e2e` — `applicable:true`
   needs `cmd`/`expect_exit`, `applicable:false` needs `cmd:null`/
   `expect_exit:null` plus a non-empty `reason`. `contract__validate_scenario`
   enforces this the same way `contract__validate_e2e` does for `e2e` —
   `contract_write` rejects a contract missing `scenario` or with the wrong
   shape, same as it already does for `e2e`.

   `docs` has its own shape (step 4): `applicable:true` needs a
   non-empty `doc_paths` array — `cmd`/`expect_exit` stay `null` even when
   applicable, since nothing runs it. `applicable:false` needs
   `cmd:null`/`expect_exit:null` plus a non-empty `reason`, same as
   e2e/scenario's inapplicable branch:
   ```
   {"id":"docs","type":"check","cmd":null,"expect_exit":null,"source":"task","applicable":false,"reason":"<why no doc needs updating>","proves":"n/a: <reason>"}
   ```
   `contract__validate_docs` enforces this — `contract_write` rejects a
   contract missing `docs`, with an empty `doc_paths` while
   `applicable:true`, or a missing/empty `reason` while `applicable:false`.

   `--works-when` and a non-empty `proves` on every requirement (an N/A one
   included) are required — `contract_write` rejects the contract otherwise.
   So is `--brief`: `{"applicable":true,"path":"<REPO>/.dod/<key>/brief.md"}`
   (the file must exist and be non-empty) or `{"applicable":false,"reason":"..."}`.

   Omit `--waivers` (or pass `'[]'`) when step 5 found none — do not
   fabricate an empty-reason waiver just to fill the flag.

9. **Confirm the contract is open** with a short one-line note (SHA + "ready
   to start") — the verification table already shown in step 6 is the
   substance; don't repeat it. **Then start implementing the task
   immediately, in this same turn.** Before your first edit, read the
   context brief (if applicable), and pass its path to **every** implementer
   subagent you delegate to, with the instruction to read it before editing
   and to follow the standards, invariants and idioms it cites. The user's "yes" in step 6 approved both
   the verification list AND starting work — it is not a separate go-ahead
   you wait to be asked for again. Do not stop and hand control back after
   writing the contract; the contract write is a means to the task, not the
   task itself.

10. **Tell the agent, not the user, to verify.** State plainly: when you
   believe this task is done, run `/dod:verify` yourself before you stop — do
   not tell the user to run it and do not wait for them to ask. The Stop gate
   will block and name the reason if you skip this, but don't rely on the
   gate to catch it; treat "run /dod:verify" as your own next action at the
   moment you'd otherwise claim done, in the same turn, not a request to
   relay.

## If a contract is already open for this branch

Amend it: re-run steps 2–6 (step 2 without the collector spawn — see below;
capture, `works_when`, proofs, waivers,
**confirm the table again** — an
amend changes what "done" means, so it needs the same confirmation a fresh
open does) before `contract_write` for the same `task_key`. There is no
separate "fresh task" flag — amend always overwrites the existing contract
for this `task_key`, same confirmation gate either way.

- **Reuse the existing brief.** Do not re-spawn the collector: pass the open
  contract's brief (`$CONTRACT_BRIEF` from `contract_read`) unchanged as
  `--brief`. Only a legacy contract without a brief (it reads as
  `applicable:false`, "contract predates the context brief") spawns the
  collector as in step 2.
- **Scope-creep "accept & amend"** (the user accepted a `/dod:verify`
  scope-creep finding into the task): widen the task to cover the accepted
  change, and keep the baseline — skip step 7 and pass
  `--baseline-sha "$CONTRACT_BASELINE_SHA"`, so the review still covers
  every change since the task began. The next `/dod:verify` reviews it in
  `full` mode (its step 5), since the creep stop skipped lenses 2-6.
