# Completion Harness — Design

## Goal

Make the Definition of Done a **structural forcing function**, not advisory text.
Today the agent's standing-instruction checklist is read once at session start and drifts out of focus;
the agent finishes the code change and anchors there, treating "implementation done"
as "task done."

North star: **the harness lets the agent finish a task independently, to high quality** —
it closes the gap between "code compiles" and "task actually verified and reviewed."

## Mechanism

Three parts. No single one is sufficient.

| Part | Role | Why |
|---|---|---|
| **Stop hook** (`done-gate.sh`) | The gate. Fires on every turn exit, blocks unless a valid done-state exists for this session. | Only mechanism that is structurally unavoidable — fires exactly when the agent declares done. |
| **`/done` skill** | The executor. Runs the checklist in order, blocking on each step, and writes the done-state. | Does the reasoning a hook can't. |
| **`done-config.json`** | Per-project cache of verification commands, auto-detected and drift-checked. | Makes the harness portable and zero-config. |

Flow:

```
[changes made, agent says "done"]
        ↓
[Stop hook fires — reads this session's done-state]
        ↓ HEAD ≠ verified_sha (or no state)
[BLOCK: "Run /done before declaring done"]
        ↓
[agent invokes /done]
        ↓
[detect/refresh config → tests → app start → code review → task_checks
 → address findings (≤ max_fix_attempts) → re-verify]
        ↓
[write done-state/<session_id>.json with verified SHA]
        ↓
[agent ends turn → Stop hook fires again → HEAD == verified_sha, tree clean]
        ↓
[ALLOWED — task complete]
```

---

## Parallelism & isolation

All harness state is keyed by `session_id` (every hook receives it on stdin;
the built-in ralph-loop Stop hook uses the same pattern).

| State | Path |
|---|---|
| Baseline SHA | `~/.claude/baselines/<session_id>.sha` |
| Baseline test snapshot | `~/.claude/baselines/<sha>.tests.json` (keyed by SHA, shared across sessions) |
| Done-state | `.claude/done-state/<session_id>.json` (project-local) |
| Config | `.claude/done-config.json` (project-local, shared) |

Cases:

- **Sequential tasks, one session** — ✅ SHA comparison re-arms per changeset. New commits → gate blocks → re-run `/done`.
- **Parallel sessions in separate worktrees** (the recommended workflow) — ✅ done-state is project-local per worktree; baseline is per-session. Fully isolated.
- **Parallel sessions in the same directory** — ⚠️ made *safe* not *correct*: each session's gate demands its own verification, so one session can't clear another. The two agents still race on the git tree itself — a git problem the harness does not pretend to solve. The `/done` skill and block message state: **parallel work must use separate worktrees.**

The Stop hook re-checks `tree_clean` and `HEAD == verified_sha` at gate time (not just trusting the stored flags), so stale state from a concurrent commit is caught.

---

## Stop hook: `~/.claude/scripts/done-gate.sh`

Fires on every main-agent turn exit. Logic in order:

1. Read stdin JSON. If `stop_hook_active == true` → **exit 0** (loop guard — a block can never trap the agent forever; blocks are a one-time nudge per stop-continuation chain).
2. Not a git repo (`git rev-parse HEAD` fails) → **exit 0** (no changeset baseline possible).
3. `HEAD == baseline/<session_id>.sha` **AND working tree clean** → **exit 0** (nothing happened this session). A dirty tree here means uncommitted "done" — it must NOT pass, so it falls through to the checks below (independent-review finding).
4. Read `.claude/done-state/<session_id>.json`. Missing → **BLOCK**.
5. `verified_sha != HEAD` → **BLOCK** ("changes committed since last /done — re-run it").
6. Working tree dirty → **BLOCK** ("uncommitted changes — commit or stash, then /done").
7. `escalation` present and valid → **exit 0** (escape hatch — see escalation rules).
8. **Checklist outcomes not all green** → **BLOCK**. With no escalation, all must hold:
   - `tests.exit_code == 0`
   - `lint.exit_code == 0` **if `.lint` is recorded** (projects with no lint command skip this)
   - an **independent review-log exists for the current HEAD** —
     `.claude/.harness/review-log/<HEAD>.json` — with `open_findings == 0`
   - every `task_checks[]` status `passed`

   Otherwise block, naming the failed outcome.
9. **exit 0**.

**Why step 8 exists — the gate enforces the checklist, not just commit hygiene.** Without
it the gate would pass a done-state recording `tests.exit_code: 1`, leaving the checklist
*advisory* — the exact failure the harness exists to kill. Step 8 makes green outcomes
structural.

**The review is a real artifact, not a self-reported count.** Earlier the gate trusted
`review: {findings, addressed}` numbers the main agent wrote about its own in-context
review — untrustworthy on both axes (did a review happen? was it independent?). Instead, a
**fresh review subagent writes the review-log itself**, keyed to the reviewed SHA. The gate
checks that a log exists for the current HEAD with `open_findings == 0`. This gives genuine
independence (don't grade your own homework) and forces **re-review-after-fix for free**:
fixing a finding moves HEAD → the old log no longer matches HEAD → step 8 blocks until a
fresh log is written for the new HEAD. No `findings == addressed` bookkeeping to trust.
Won't-fix findings that don't move HEAD route to the **escalation** path (step 7), not a
waiver.

**Escalation is honored before the outcome check (step 7 before 8)** but after the SHA and
tree checks (5, 6) — so an escalation disarms only the exact committed changeset it was
recorded against. Later commits move HEAD → step 5 blocks → `/done` must run again. This
prevents a stale escalation from disarming the gate for the rest of the session
(independent-review finding).

`done-write-state.sh` mirrors step 8: it **refuses to write** a done-state unless (with no
escalation) `tests.exit_code == 0`, `lint.exit_code == 0` when lint is configured, and a
review-log for the current HEAD exists with `open_findings == 0` — giving the agent the
feedback at `/done` time rather than at stop time. The gate remains the structural backstop
(it fires even if the file was hand-written).

**Threat model — this defends against drift, not malice.** The harness's real adversary is
the *drifting* agent that anchors on "implementation done" and silently omits steps. Against
omission, requiring an artifact bound to the current HEAD is effective — not because it is
hard to forge, but because producing it *means doing the step*, and a non-adversarial agent
nudged to do the step does it. A **malicious** agent can always defeat a local shell gate
(fabricate the review-log, hardcode `open_findings: 0`, record a false `exit_code: 0`); no
local machinery changes that, so malice is **out of scope by construction**. The only
signals a gate can trust with zero faith are deterministic command outcomes
(`tests`/`lint` exit codes) — everything else is trust-but-falsifiable-in-transcript.

**Block contract: `{"decision":"block","reason":...}` on stdout + `exit 0`** — the canonical
Stop-hook method (matches the shipped ralph-loop plugin). NOT exit 2: on exit 2 the runtime
reads stderr and *ignores* the stdout JSON, discarding the reason. Confirmed against the
hooks contract and the ralph-loop exemplar.

Block output (stdout, exit 0):
```json
{"decision":"block","reason":"Completion harness: /done has not passed for the current changeset (HEAD: abc1234). Run /done to verify tests, app start, code review, and task-specific checks before declaring done."}
```

> **Open item — live interception unverified.** `test-gate.sh` exercises the script's
> decision logic (block vs allow) deterministically, but whether Claude Code actually halts
> the stop on a real block can only be confirmed in a live nested session. This is the one
> box not yet checked.

---

## `/done` skill: `~/.claude/skills/done/SKILL.md`

User-invocable. Steps run in order, blocking on each (stated once, globally — a failing
step means fix and re-run from Step 2).

**Deterministic work lives in scripts, not prose.** The skill body carries only the
judgment steps (run/read/decide/fix/escalate). Everything mechanical — config detection,
fingerprinting, session-id resolution, `git rev-parse`, tree-clean, done-state assembly —
is delegated to helper scripts so it is testable and can't be hallucinated. The two
highest-risk targets are scripted: Step 0 (`done-detect.sh`) and Step 7
(`done-write-state.sh`).

**Prerequisite — capture `task_checks` at task start.** Task-stated verifications drift
out of focus like standing instructions; the agent records them into done-state `task_checks` when the
task begins, not at `/done` time. (Executed in Step 6.)

### Step 0 — Config: detect / refresh (script: `done-detect.sh`)

Run `done-detect.sh`. It probes lockfiles + `package.json`/`Cargo.toml`/`go.mod`/
`pyproject.toml`/`Makefile`, recomputes `source_fingerprint`, and — if missing or changed —
rewrites `detected` while preserving `overrides` (`effective = override ?? detected`).
Handles a `build` → `build:server` rename automatically. Emits the effective config to
stdout. No LLM guessing of command names.

### Step 0.5 — Assemble the effective DoD (fold in external instructions)

The checklist is **not hardcoded**. Build the *effective DoD* for this task by folding
external instruction sources onto the base DoD (see "Harness Definition of Done" below):
read base DoD → scan each source → merge every completion-affecting instruction into one
deduped checklist. External/user instructions augment and, on conflict, **override** the
harness defaults (the user's rules win). Record the effective DoD verbatim into done-state
`dod` — every task then carries proof of the exact standard it was held to. Each item in the
effective DoD is a blocking check enforced by the steps below; an item with no matching
built-in step becomes a task_check (step 6).

### Step 1 — Changeset scope

`git diff <baseline_sha> HEAD --stat` (or merge-base diff on a feature branch).
Everything downstream is scoped to **this changeset**, never the whole repo.

### Step 2 — Tests (with before/after checkpoint)

Run the effective test command. Diff results against the baseline snapshot
(`~/.claude/baselines/<sha>.tests.json`, captured at SessionStart):

- **Newly red** (passed on baseline, fails now) → *you broke it* → must fix. No escape.
- **Already red** on baseline → genuinely pre-existing. **Boyscout default: fix it anyway.**
  Only after `max_fix_attempts` exhausted does it become a Category C user decision.

Any failure → fix, then **return to step 2** (re-verify). Do not proceed with red tests.
If a `lint` command is configured, run it too and record `lint.exit_code`; non-zero → fix
(or escalate), same as tests.

### Step 3 — App startup

Run `effective.start` (or detected startup probe). Docker/systemd/k8s targets that
can't be exercised locally → the agent must **state the target explicitly and whether
it was exercised** ("started the binary; real target is a Docker container, container
not smoke-tested"). Failure → fix → return to step 2.

### Step 4 — Code review (independent subagent writes the review-log)

Spawn a **fresh review subagent** scoped to the step-1 diff. Its deliverable **is the file**
`.claude/.harness/review-log/<HEAD>.json` — it writes the log itself:
`{ "reviewed_sha": "<HEAD>", "findings": [ {severity, file, line, desc} … ], "open_findings": <n> }`.
The main agent does **not** transcribe a count from its own context (that would be
self-review — the harness requires an independent reviewer; don't grade your own homework).
The gate later checks the log
for the current HEAD has `open_findings == 0`.

### Step 5 — Address findings (bounded loop)

For each finding: fix, or genuinely can't → escalate (Category C, after `max_fix_attempts`,
default 3). After fixing → commit (HEAD moves) and **re-run Step 4** so a fresh review-log is
written for the new HEAD. Re-review-after-fix is thus forced by the HEAD-keyed log, not by
trust. A won't-fix finding that doesn't move HEAD must be escalated, never silently waived.

### Step 6 — Task-specific checks

Execute every entry in done-state `task_checks` (captured at task start — see Prerequisite).
Automatable (e.g. an API call, a CLI run) → run it. Visual/UI → `/verify` or browser
tooling, verified against the **real target medium and an independent source of truth**
(design/spec), never against the agent's own render. Unreachable → Category C user-ask.
**Never silently skipped.**

### Step 7 — Write done-state (script: `done-write-state.sh`)

The LLM supplies only the judgment fields (`dod`, `task_checks`, `escalation`, `tests` and
`lint` summaries) as a JSON payload. The script **injects the git facts live** —
`verified_sha = git rev-parse HEAD`, `tree_clean` from `git status --porcelain` — and
**refuses to write** over a dirty tree, or when (absent an escalation) tests/lint aren't
green or no `open_findings == 0` review-log exists for HEAD. No hand-written SHA strings.
The `review` outcome is **not** a payload field — it is the separate review-log artifact
(Step 4), which the gate and the writer both read.

```json
{
  "session_id": "<from hook>",
  "verified_sha": "<git rev-parse HEAD>",
  "tree_clean": true,
  "dod": {
    "sources": ["base", "agent-instructions", "task", "session"],
    "items": ["tests green", "lint green", "app starts", "changeset-scoped independent review", "re-verified after fixes", "verification real not synthetic", "deploy target stated", "visually verify button"]
  },
  "tests": {"exit_code": 0, "newly_red": [], "pre_existing_red": []},
  "lint": {"exit_code": 0},
  "app_started": true,
  "task_checks": [{"desc": "visually verify button", "status": "passed", "how": "browser screenshot vs Figma"}],
  "escalation": null
}
```

Review evidence lives beside it: `.claude/.harness/review-log/<HEAD>.json` with
`open_findings == 0`, written by the Step-4 review subagent.

### Step 8 — Report

One paragraph: changeset stat, what passed (test counts, app startup, review outcome,
task-check outcomes), anything escalated and why. Escalations are surfaced on the same
turn — no silent passes.

---

## Task-specific verifications (`task_checks`)

Task-stated checks ("visually verify the UI") drift out of focus **exactly like
the agent's standing instructions do** — so they are captured at **task start**, not recalled at the end.

- At task start (or first `/done`), the agent extracts explicit verification
  requirements from the task and writes them into done-state `task_checks`.
- `/done` step 6 executes them alongside the built-ins, blocking equally.
- The harness thus reliably runs both the built-in checklist **and** whatever the
  task itself demanded.

---

## Harness Definition of Done (self-hosted & extensible)

The harness enforces an **explicit DoD artifact**, never a checklist hardcoded in the
skill. This has two faces.

### Runtime — the effective DoD (assembled per task)

**Base DoD** — `completion-harness/dod/base-dod.md`, installed to
`.claude/harness/base-dod.md` (portable, committed). The built-in checklist: tests green
(before/after checkpoint), app starts, changeset-scoped independent review, findings
addressed, re-verified after fixes, verification real (exercised) not synthetic (diff
read), deploy target stated, task_checks executed.

**External instruction sources** — folded in, precedence low → high:
1. **the agent's own active instructions** — whatever completion / Definition-of-Done /
   quality standard is in force for the agent this session, *however it was provided*
   (system prompt, project or user instructions, enterprise policy). The harness is
   **setup-agnostic**: it does not assume the DoD lives in any particular file or path;
   the agent extracts it from the instructions it actually runs under.
2. task-stated verifications (→ `task_checks`)
3. explicit user instructions this session

**Assembly** — `/done` Step 0.5 merges these onto the base DoD into one deduped effective
checklist. **Respected = never dropped or applied ad-hoc**: every folded item becomes a
blocking check, or — if unenforceable — surfaces as an escalation (A/B/C) with a reason.
External/user instructions **override** harness defaults on conflict. The effective DoD is
recorded verbatim in done-state `dod`, so each task carries proof of the exact standard
applied.

**Evolution** — re-assembled on every `/done` run, so a change to the agent's instructions
or the task is picked up automatically (same principle as config drift).

### Meta — the harness holds itself to a DoD

The harness *project* ships `completion-harness/DOD.md` and every change to the harness is
verified against it. By the same setup-agnostic rule, it folds in whatever completion
standard governs the maintainer's agent (in this repo: real verification, changeset-scoped
fresh-agent review, findings addressed, build/tests/lint green). The harness eats its own
dog food.

---

## Escalation — what "the agent cannot fix" means

The escape hatch is **not** a self-asserted field. It is one of three, and only the
last is the agent's judgment — and even that routes to the user.

**A — Environmental / capability block.** Check physically cannot run (Docker down,
needs sudo, no network, missing hardware). A *fact*: detected by running the command
and **capturing the real error**. Gate passes because there is captured evidence, not
a claim.
```json
"escalation":{"type":"environment","step":"app_startup","command":"docker compose up",
  "captured_error":"Cannot connect to the Docker daemon","exit_code":1}
```

**B — Pre-existing failure** → **no longer an automatic escape.** The before/after
checkpoint proves attribution; boyscout default is to fix it. Falls through to C only
if out of scope *and* `max_fix_attempts` exhausted.

**C — Genuinely stuck / out of scope** (only after `max_fix_attempts`). **Not the
agent's call** — `/done` stops and asks the user (AskUserQuestion): "Test X fails,
attempts A/B/C didn't fix it — accept and proceed, or keep working?" The field records
the *user's* decision plus the attempts made.
```json
"escalation":{"type":"user_accepted","finding":"...","attempts":["...","..."],
  "user_decision":"accept, tracked separately"}
```

**Honest limitation.** A bash gate can't *prove* a user answered — some field is always
written. Mitigation: A and B require captured command output (faking = fabricating an
error string, visible in transcript); C requires an actual AskUserQuestion turn in the
transcript (a `user_accepted` with no such exchange is a detectable lie in the record);
every escalation is echoed in the step-8 summary for the user to see.

---

## Config file: `.claude/done-config.json`

```json
{
  "source_fingerprint": "<hash of package.json scripts + lockfile>",
  "detected": {
    "package_manager": "pnpm",
    "test": "pnpm test",
    "build": "pnpm build",
    "start": "pnpm dev",
    "lint": "pnpm lint"
  },
  "overrides": {
    "start": "pnpm start:prod"
  },
  "max_fix_attempts": 3,
  "baseline_snapshot": true,
  "deploy_check_cmd": null
}
```

`effective = overrides ?? detected`. `overrides`, `max_fix_attempts`, `baseline_snapshot`,
`deploy_check_cmd` are human-owned and sticky; `detected` + `source_fingerprint` are
auto-managed.

---

## Deployment environment

Cannot be fully automated generically.
- `deploy_check_cmd` set → run it, check exit code.
- Absent → `/done` forces the agent to **state** the deploy target and whether it was
  exercised. Makes the gap visible instead of claiming false coverage.

---

## Files — portable bundle (trial: per-project, not global)

The bundle lives under `completion-harness/` and is copied into a target project's
`.claude/` by `install.sh`. All hook paths use `$CLAUDE_PROJECT_DIR` — no `~` or machine
paths. After the trial proves out, the same bundle can be promoted to `~/.claude/` for
global use.

| File | Purpose |
|---|---|
| `completion-harness/scripts/done-gate.sh` | Stop hook gate |
| `completion-harness/scripts/baseline-snapshot.sh` | SessionStart: baseline SHA + background test snapshot |
| `completion-harness/scripts/done-detect.sh` | `/done` Step 0: probe + fingerprint + write done-config.json |
| `completion-harness/scripts/done-write-state.sh` | `/done` Step 7: inject live git facts + write done-state (refuses dirty tree) |
| `completion-harness/skills/done/SKILL.md` | `/done` skill (judgment steps only) |
| `completion-harness/dod/base-dod.md` | Base DoD (assembled into the effective DoD) |
| `completion-harness/DOD.md` | The harness project's own DoD (meta) |
| `completion-harness/install.sh` | Idempotent installer → target `.claude/` + `settings.local.json` |
| `completion-harness/README.md` | Install / use / uninstall / portability |

**Installed into a target project** (by `install.sh`):
`.claude/scripts/`, `.claude/skills/done/`, `.claude/harness/base-dod.md`,
`.claude/done-config.json`; hooks appended to `.claude/settings.local.json` (machine-local,
opt-in per machine); `.claude/.harness/` (baselines + done-state) gitignored.

**settings.local.json** (merged via `jq`, existing hooks preserved):
```json
"Stop":[{"hooks":[{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/done-gate.sh\"","timeout":10}]}]
```
Add to the existing `SessionStart` array:
```json
{"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/baseline-snapshot.sh\""}
```

---

## Checklist coverage

| Original failure | Caught by |
|---|---|
| 1. Code-read not exercised | Step 3 startup; `/verify` in task_checks |
| 2. Verification needs sudo | Step 3 states it; escalation type A |
| 3. Docker/sysfs not tested | `deploy_check_cmd` + explicit statement (step 3) |
| 4. No code review | Step 4 (mandatory before done-state) |
| 5. Review scope = whole repo | Step 1 changeset scope |
| 6. Findings not acted on | Step 5 loop |
| 7. No re-verify after fix | Step 5 → step 2 loop |
| 8. Tests not run | Step 2 (mandatory, before/after checkpoint) |
| 9. New coverage not checked | Step 4 review |
| 10. App startup | Step 3 |
| (new) Task-stated checks forgotten | `task_checks` captured at start, step 6 |

---

## Non-goals

- No enforcement on conversational turns (SHA guard).
- No enforcement in non-git repos (no changeset baseline).
- Does not guarantee the deploy environment was exercised — guarantees the agent must
  *state* whether it was.
- Does not arbitrate two agents committing to one tree — use worktrees.
