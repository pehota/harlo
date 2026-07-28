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
 → address findings (batched; ≤ max_review_rounds) → re-verify]
        ↓
[write done-state/<task_key>.json with verified SHA]
        ↓
[agent ends turn → Stop hook fires again → HEAD == verified_sha, tree clean]
        ↓
[ALLOWED — task complete]
```

---

## Identity: task (branch), with session fallback

The harness keys verification state by the **task**, using the **git branch** as the task
identity — because completion is a property of the task, not the session, and a task can
span many sessions. `session_id` is only a **fallback** (trunk / detached / no confident
trunk). One resolver, `harness-common.sh` (`hc_resolve`), is the single source of identity
truth, sourced identically by `baseline-snapshot.sh`, `done-gate.sh`, and
`done-write-state.sh` so they can never diverge. The `/done` skill reads it via
`harness-resolve.sh`.

`harness-common.sh` also houses `hc_tree_status` — the **single shared
baseline-relative working-tree classifier** used by the gate (Step 6), the `/done`
writer, and the preflight; **none of them reimplements it.** It classifies each
`git status --porcelain` line relative to a pinned tree baseline (path in
`HC_TREE_BASE_FILE`, set by `hc_resolve`): a line **introduced since the baseline**
is a BLOCKER (`HC_TREE_BLOCKERS`), a line **already present at baseline** is a
WARNING (`HC_TREE_WARNINGS`). A **missing** baseline file is treated as the empty
set → every current change is "introduced" → blocks (safe direction — never a
silent pass). `hc_tree_remediation` renders the exact "commit or stash these
changes you introduced: … (pre-existing, only warned: …)" message from those
globals. The `untracked_policy` knob (`done-config.json`, default `"baseline"` |
`"strict"`) governs untracked lines — see the config section.

**Resolution (offline, conservative):**
- `branch = git symbolic-ref --short -q HEAD` (empty if detached).
- `trunk` = config `.trunk` → else local `main` → else `master` (via `show-ref`; never
  `origin/HEAD`, since repos may have no remote) → else *unconfident*.
- **TASK mode** iff on a branch, trunk is confident, and `branch != trunk`
  → `task_key = br-<sanitized-branch>`. Else **SESSION mode** → `task_key = session-<id>`.

**Base (changeset anchor), pinned once:**
- TASK mode → `base = merge-base(trunk, HEAD)`, written to `task-base/<task_key>.sha` on
  first sight and reused thereafter (immune to trunk moving / mis-detection later;
  inspectable). Empty merge-base (unrelated histories) → degrade to SESSION + warn, no pin.
- SESSION mode → `base = baselines/<session_id>.sha` (HEAD at SessionStart).
- Pinning is **lazy + idempotent at every entry point** (auto-branch can flip trunk→task
  mid-session, so SessionStart isn't the only place it must pin).

**Tree baseline (the classifier's "pre-existing" set), pinned in parallel:**
alongside the SHA base, `hc_resolve` resolves `HC_TREE_BASE_FILE` — the `git status
--porcelain` snapshot the `hc_tree_status` classifier diffs against.
- TASK mode → `tree-base/<task_key>.dirty`, pinned **once** at the task's fork point
  (by `baseline-snapshot.sh`, or by `auto-branch.sh` when the branch is created
  mid-session) and **never re-seeded** — parallel to `task-base/<task_key>.sha`. This
  is what stops a later session re-seeding "pre-existing" from live porcelain and
  thereby whitelisting the agent's own uncommitted work.
- SESSION mode → `baselines/<session_id>.dirty`, rewritten every SessionStart (in
  session mode the changeset *is* the session).

| State | Path | Keyed by |
|---|---|---|
| Task base (pinned) | `.claude/.harness/task-base/<task_key>.sha` | task (branch) |
| Task tree-base (pinned) | `.claude/.harness/tree-base/<task_key>.dirty` | task (branch) — pinned ONCE at the fork; classifier's "pre-existing" set |
| Session baseline | `.claude/.harness/baselines/<session_id>.sha` | session (fallback + test-snapshot anchor) |
| Session tree-base | `.claude/.harness/baselines/<session_id>.dirty` | session — rewritten each SessionStart; classifier's "pre-existing" set |
| Test snapshot | `.claude/.harness/baselines/<sha>.tests.json` | SHA (shared) |
| Done-state | `.claude/.harness/done-state/<task_key>.json` | **task** — survives session end |
| Review-log | `.claude/.harness/review-log/<HEAD>.json` | reviewed commit |
| Config | `.claude/done-config.json` | project |

**Cases:**
- **Multi-session task** — ✅ same branch → same `task_key` → a resumed session inherits the
  done-state and the pinned base; `/done` reviews the whole feature (`base..HEAD`), not just
  the latest session's slice.
- **Parallel in separate worktrees** (recommended) — ✅ different branches → different
  `task_key` → isolated.
- **Same-dir same-branch parallel** — ⚠️ shares the task key; *unsupported* → use worktrees.
- **On trunk** — SESSION fallback (see auto-branch below); one-time warning, never blocks.

The gate re-checks `tree_clean` and `HEAD == verified_sha` live, so stale state from a
concurrent commit is caught.

### Auto-branch (on trunk, first edit)

Config `auto_branch` (default **true**): a `PreToolUse(Write|Edit)` hook (`auto-branch.sh`)
detects "on trunk, about to edit" and `git checkout -b <branch_prefix><timestamp>` (carries
WIP), moving the work into TASK mode so it gets cross-session continuity. Fast no-op when
already off trunk (it fires on every edit), and on detached/mid-rebase/merge or checkout
failure it **stays on trunk and never blocks the edit**. `auto_branch:false` → stays on trunk
with the SessionStart warning. To *resume* an existing task, checkout its branch first.

After creating the branch it **pins the task tree-base from THIS session's clean pre-edit
SessionStart snapshot** (`baselines/<session_id>.dirty`) — this hook fires *before* the
triggering edit, so that snapshot is still clean. When no such snapshot exists it pins an
**empty** baseline (safe direction: everything blocks), **never live porcelain** (which could
already contain this session's WIP and whitelist it).

### SessionStart (`baseline-snapshot.sh`)

Beyond recording the baseline SHA and the background test snapshot, SessionStart now:
- **Records the tree baseline** (`HC_TREE_BASE_FILE`) — rewritten every session in session
  mode; pinned **once and never overwritten** in task mode. The file is always created (even
  when empty) so "missing" (→ strict) is distinguishable from "clean at baseline".
- **Self-seeds config to avoid silent inertness:** when `baseline_snapshot` is enabled but no
  test command is detected, it runs `done-detect.sh` first (fixing the chicken-and-egg where
  a fresh project's empty `detected:{}` meant it never snapshotted).
- **Fails loud, never silently inert:** if there is still no test command, it writes an
  explicit `{"status":"inert",…}` marker to the `.tests.json` **and** surfaces a
  `systemMessage` that the newly-red vs pre-existing-red discrimination is unavailable.
- **Writes the test snapshot atomically** (temp file + `mv`) so a concurrent `/done` never
  reads a half-written file.

### State lifecycle & cleanup

`.claude/.harness/` state is **load-bearing during a session** — the gate re-reads
`done-state/<task_key>.json` and `review-log/<HEAD>.json` on every turn-end — so it is
never cleaned mid-session. Cleanup is **age-based, at SessionStart**: `baseline-snapshot.sh`
reaps any file under `.claude/.harness/` older than **14 days** (`find -mtime +14 -delete`,
guarded, never fails the hook) — **excluding `task-base/*` and `tree-base/*`**, whose pins
must live as long as the branch (reaping `tree-base/*` would let the next SessionStart
re-seed the "pre-existing" set from live porcelain and whitelist the agent's own
uncommitted work). Session-mode `baselines/<sid>.dirty` may still be reaped. This is
self-healing, needs no `SessionEnd` hook (which
wouldn't fire on a crash), and is parallel-safe — freshly written files from active sessions
are far younger than the threshold. Durable progress lives in **git**, not in `.harness/`.

---

## Stop hook: `~/.claude/scripts/done-gate.sh`

Fires on every main-agent turn exit. Logic in order:

1. Read stdin JSON. If `stop_hook_active == true` → **exit 0** (loop guard — a block can never trap the agent forever; blocks are a one-time nudge per stop-continuation chain).
2. Not a git repo (`git rev-parse HEAD` fails) → **exit 0** (no changeset baseline possible).
3. `HEAD == baseline/<session_id>.sha` **AND working tree clean** → **exit 0** (nothing happened this session). A dirty tree here means uncommitted "done" — it must NOT pass, so it falls through to the checks below (independent-review finding).
4. Read `.claude/.harness/done-state/<task_key>.json`. Missing → **BLOCK**.
5. `verified_sha != HEAD` → **BLOCK** ("changes committed since last /done — re-run it").
6. **Working tree has INTRODUCED changes → BLOCK.** Not "any non-empty `git status
   --porcelain`" — the gate calls the shared `hc_tree_status` classifier and blocks
   **iff `HC_TREE_BLOCKERS` is non-empty**, i.e. work introduced since the pinned tree
   baseline. Pre-existing entries (present at baseline) are **warned, not blocked** —
   this is what breaks the pre-existing-untracked deadlock **without weakening the gate:
   the changeset's OWN uncommitted work still blocks** (an agent's introduced file is,
   by construction, not in the baseline). The block message names the blockers and, if
   any, the warned pre-existing entries (`hc_tree_remediation`). `untracked_policy`
   (default `"baseline"`) tunes untracked handling; `"strict"` blocks every untracked
   line regardless of baseline. If the classifier can't be sourced, the gate falls back
   to the **strict** live check (block on any non-empty porcelain) — never toward allow.
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
feedback at `/done` time rather than at stop time. Its dirty-tree refusal uses the **same
`hc_tree_status` classifier** as the gate: it refuses **iff introduced blockers exist**
(the changeset's own uncommitted work), writes when only pre-existing warnings remain, and
sets `tree_clean` to reflect "no blockers" (not "no dirt at all"). The gate remains the
structural backstop (it fires even if the file was hand-written).

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

### Step 0 (Preflight) — prove the gate is winnable (script: `done-preflight.sh`)

Run at **task start**, before editing or spawning subagents. It calls the shared gate
logic (`hc_resolve` + `hc_tree_status`) — it does **not** reimplement the gate — and
reports whether the gate is winnable, with exact remediation. It **exits non-zero on a
HARD problem** — notably `baseline_snapshot:true` but **no test command** (the
before/after red-test discrimination would be inert) and **pre-existing blockers** in the
tree — in which case the skill must stop and fix/surface before working. Warnings (missing
`.dirty` baseline, `jq` absent) are non-blocking. It **never seeds a permissive baseline**
when one is missing (it can run after edits, which would whitelist the agent's own work) —
it reports the gap and tells the user to restart the session so SessionStart pins it.

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

The before/after discrimination **depends on the baseline snapshot**. If the snapshot is
**`inert`** (an explicit `{"status":"inert"}` marker in the `.tests.json`) or **absent**,
there is no baseline to diff against — the agent **must STATE that newly-red vs
pre-existing-red discrimination is unavailable** for this changeset rather than silently
treating every red as pre-existing.

Any failure → fix, then **return to step 2** (re-verify). Do not proceed with red tests.
If a `lint` command is configured, run it too and record `lint.exit_code`; non-zero → fix
(or escalate), same as tests.

### Step 3 — App startup

Run `effective.start` (or detected startup probe). Docker/systemd/k8s targets that
can't be exercised locally → the agent must **state the target explicitly and whether
it was exercised** ("started the binary; real target is a Docker container, container
not smoke-tested"). Failure → fix → return to step 2.

### Step 4 — Code review (independent subagent writes the review-log)

Spawn a **fresh, independent, Write-capable** review subagent scoped to the step-1 diff.
Its deliverable **is the file** `.claude/.harness/review-log/<HEAD>.json` — it writes the
log itself: `{ "reviewed_sha": "<HEAD>", "findings": [ {severity, file, line, desc} … ],
"open_findings": <n> }`. Because the deliverable is a *written* file, the agent type must
have a Write tool (e.g. `general-purpose`); a review-only type that lacks Write (e.g.
`feature-dev:code-reviewer`) cannot produce the log and must not be used. The main agent does
**not** transcribe a count from its own context (that would be self-review — the harness
requires an independent reviewer; don't grade your own homework). The subagent must *answer* a
mandatory blast-radius question set — foremost **"does a widening of what is read/accepted
also widen what is written, allowed, or executed?"**, plus invariant/contract changes,
new-branch/error-path parity, and silent scope broadening — not merely scan the diff. The gate
later checks the log for the current HEAD has `open_findings == 0`.

### Step 5 — Address findings (bounded loop, capped)

**Zero findings → single review:** if round 1 returns `open_findings == 0`, HEAD does not
move, the existing review-log satisfies the gate, and there is **no second review** — a clean
changeset costs exactly one review.

Otherwise: **batch** ALL findings into **one** fix pass and **commit once** (HEAD moves once,
not once per finding), then run **one** confirming pass (round 2) — a fresh Step-4 review
**scoped to the fix diff** (cheaper, and where regressions hide), which writes a new
review-log for the new HEAD. The loop is capped by `max_review_rounds` (default 2): if round 2
still has open findings, **do not loop again — STOP and escalate via AskUserQuestion**
(Category C) with the remaining findings ("fix further, or accept and proceed?"), recording the
user's decision in `escalation`. Per-item, an unfixable finding still gets `max_fix_attempts`
tries. A won't-fix finding that doesn't move HEAD must be escalated, never silently waived. If a
round-1 fix caused a round-2 finding, that is surfaced in the Step-8 report.

### Step 6 — Task-specific checks

Execute every entry in done-state `task_checks` (captured at task start — see Prerequisite).
Automatable (e.g. an API call, a CLI run) → run it. Visual/UI → `/verify` or browser
tooling, verified against the **real target medium and an independent source of truth**
(design/spec), never against the agent's own render. Unreachable → Category C user-ask.
**Never silently skipped.**

### Step 7 — Write done-state (script: `done-write-state.sh`)

The LLM supplies only the judgment fields (`dod`, `task_checks`, `escalation`, `tests` and
`lint` summaries) as a JSON payload. The script **injects the git facts live** —
`verified_sha = git rev-parse HEAD`, `tree_clean` from the `hc_tree_status` classifier —
and **refuses to write** when the tree has **introduced blockers** (baseline-relative, same
classifier as the gate — pre-existing entries only warn), or when (absent an escalation)
tests/lint aren't green or no `open_findings == 0` review-log exists for HEAD. No
hand-written SHA strings.
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
  "max_review_rounds": 2,
  "baseline_snapshot": true,
  "deploy_check_cmd": null,
  "untracked_policy": "baseline"
}
```

`effective = overrides ?? detected`. `overrides`, `max_fix_attempts`,
`max_review_rounds`, `baseline_snapshot`, `deploy_check_cmd`, `untracked_policy`
are human-owned and sticky; `detected` + `source_fingerprint` are auto-managed.

`max_review_rounds` (default `2`) caps the Step-5 fix → re-review loop: round 1 is
the initial full-changeset review, round 2 is the confirming pass scoped to the
fix diff. It is a **prompt-level** cap the `/done` agent obeys — exactly like
`max_fix_attempts` — with no gate/writer counter behind it; a clean changeset
(round-1 `open_findings == 0`) costs exactly one review. Seeded by `done-detect.sh`
and `install.sh` and preserved thereafter.

`untracked_policy` (default `"baseline"`, values `baseline` | `strict`) governs the
`hc_tree_status` classifier: `"baseline"` applies the baseline-relative rule to **both**
untracked and tracked-modified lines (a line blocks iff it is not in the pinned tree
baseline); `"strict"` makes **every** untracked (`??`) line a blocker regardless of the
baseline, while tracked-modified lines stay baseline-relative. `untracked_policy: "baseline"`
is seeded by `done-detect.sh` and `install.sh` and preserved thereafter.

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
| `completion-harness/scripts/harness-common.sh` | Shared library: `hc_resolve` (identity/base) + `hc_tree_status`/`hc_tree_remediation` (baseline-relative tree classifier) |
| `completion-harness/scripts/baseline-snapshot.sh` | SessionStart: baseline SHA + tree baseline + background test snapshot (self-seeds config, inert-marker + systemMessage when no test cmd) |
| `completion-harness/scripts/auto-branch.sh` | PreToolUse(Write\|Edit): auto-branch off trunk + pin task tree-base from clean pre-edit snapshot |
| `completion-harness/scripts/done-preflight.sh` | `/done` Step 0 preflight: prove the gate is winnable (calls `hc_resolve`+`hc_tree_status`), non-zero on HARD problems; never seeds a baseline |
| `completion-harness/scripts/done-detect.sh` | `/done` Step 0: probe + fingerprint + write done-config.json (seeds `untracked_policy`) |
| `completion-harness/scripts/done-write-state.sh` | `/done` Step 7: inject live git facts + write done-state (refuses on introduced blockers) |
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

## Distribution: marketplace plugin (target model)

The portable bundle + `install.sh` (above) is the **fallback**. The intended distribution
is a **Claude Code plugin** from a marketplace — which dissolves most of the "install"
problem, because enabling the plugin *is* the installation.

### What the plugin provides globally (no per-project copy or wiring)
A plugin ships its own `hooks/hooks.json`, `skills/`, and scripts, with hook commands
resolved via `${CLAUDE_PLUGIN_ROOT}`. When the plugin is **enabled**:
- **Hooks fire from the plugin** — Stop→`done-gate.sh`, SessionStart→`baseline-snapshot.sh`,
  PreToolUse(Write|Edit)→`auto-branch.sh`. No `settings.local.json` `jq`-merge per project.
- **`/done` skill + all scripts** live in the plugin. `harness-common.sh` is sourced from
  `${CLAUDE_PLUGIN_ROOT}`; `base-dod.md` is read from there.

This removes the copy-and-wire step of `install.sh` entirely — and with it the three
footguns of self-installing at SessionStart (bootstrap circularity, nothing-to-copy-from,
overwriting committed scripts / dirtying the tree). Those were artifacts of the copy model.

### What remains per-project (lazy runtime init — NOT an "install")
Only project-local state + config, which the scripts already create lazily:
- `.claude/.harness/` (baselines, done-state, review-log, task-base) — `mkdir -p` on first
  hook fire.
- `done-config.json` — self-seeded/refreshed by `done-detect.sh` at `/done` (legitimately
  per-project: detected commands differ).
- One `.gitignore` line for `.claude/.harness/`.

**Run this idempotently at every SessionStart, not one-shot "first use."** A first-use flag
doesn't survive a fresh clone, a new worktree, or a second machine; an every-session
idempotent check (a no-op after the first) self-heals all three. The plugin's own
SessionStart hook is the place for it.

### The one genuinely manual, one-time step
**Enabling the plugin** (per user/machine, from the marketplace). A plugin cannot
auto-enable itself. Persist enablement via `enabledPlugins` in **`.claude/settings.json`**
(project scope, committed) so everyone who clones — and headless/CI runs — pick it up.

### Headless / CI caveat (verified against the docs, v2.1.207+)
Plugins load in headless (`claude -p`, Agent SDK) the same way as interactive — from
`enabledPlugins` in settings — **except** under `--bare`, which skips plugin/hook/skill
discovery entirely. Confirmed: `SessionStart`/`SessionEnd` hooks fire and skills/slash
commands resolve in `-p` mode. **Undocumented / must be tested empirically:** whether
`PreToolUse` hooks fire and whether a `decision:block` from the Stop gate actually halts a
non-interactive run. So for CI, verify the gate + auto-branch behavior empirically before
relying on them, and never run the harness under `--bare`.

### Decisions to settle when building the plugin
- `base-dod.md`: ship global in the plugin (simplest; Step 0.5 already folds in the agent's
  own instructions) with an optional project-local override.
- `done-config.json`: stays per-project; committed (team shares detected commands) vs
  gitignored.
- Keep `install.sh` as the non-plugin fallback.
- Enablement scope: an enabled plugin's hooks fire in *every* project (the intent — enforce
  DoD everywhere); confirm that vs. per-project opt-in.

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
