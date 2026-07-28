---
name: done
description: "Completion harness executor. Runs the Definition-of-Done checklist in order — config detect, tests with before/after checkpoint, app startup, changeset-scoped code review, task-specific checks — then writes the per-session done-state that clears the Stop gate. Invoke when finishing a task or when the Stop hook blocks with 'Run /done'."
user-invocable: true
argument-hint: '(no args) — verifies the current changeset and writes done-state'
---

# /done — Completion Harness Executor

You are running the completion gate for **this session's changeset**. Run the
steps below **in order, blocking on each**.

**Global rule:** any step that fails means *fix it, then return to Step 2* and
re-verify with the fix in place — never proceed past a failing step.

**Deterministic work lives in scripts, not here.** The mechanical steps (config
detection + fingerprinting in Step 0; git facts + done-state assembly in Step 7)
are delegated to helper scripts so they are testable and can't be hallucinated.
Your job is the judgment: run, read, decide, fix, escalate.

**Parallel work must use separate git worktrees.** Same-directory parallelism is
made *safe* (each session needs its own verification) but not *correct* (agents
still race on the git tree — a git problem this harness does not solve).

The Stop hook keeps blocking until a valid done-state exists for this **task** at
`$CLAUDE_PROJECT_DIR/.claude/.harness/done-state/<task_key>.json`. Use
`$CLAUDE_PROJECT_DIR` for the project root (fall back to `$PWD`). The `<task_key>`
(and the changeset base) are resolved by `harness-resolve.sh`: on a feature branch
it's the branch — task identity, stable across sessions; on trunk it falls back to
the session. Step 1 and Step 7's scripts resolve it for you.

## Prerequisite — capture `task_checks` at task start

Task-stated verifications ("visually verify the button", "confirm the endpoint
returns 200") drift out of focus by the end, just like your standing instructions
do. So at **task start** — not at `/done` time — extract the explicit verification
requirements from the task statement and record them into done-state
`task_checks`. Step 6 only *runs* them.

## Step 0 (Preflight) — prove the gate is winnable

Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-preflight.sh` **before** the config
detect below — and ideally **at TASK START**, before you edit anything or spawn
subagents. It calls the shared gate logic (`hc_resolve` + `hc_tree_status`) to
report whether the gate is winnable. If it reports a **HARD problem** (non-zero
exit — e.g. `baseline_snapshot` enabled but no test command, or a deadlock-risk
tree state), **stop and fix or surface it** before proceeding; do not begin work
against an unwinnable gate. Warnings (missing `.dirty`, `jq` absent) are
non-blocking and are printed with exact remediation.

## Step 0 — Config: detect / refresh (script)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-detect.sh` and consume its stdout —
the **effective** config (`overrides` merged over `detected`). The script probes
lockfiles + `package.json`/`Cargo.toml`/`go.mod`/`pyproject.toml`/`Makefile`,
recomputes the `source_fingerprint`, and rewrites `detected` only when the source
changed — preserving `overrides`, `max_fix_attempts`, `baseline_snapshot`,
`deploy_check_cmd`. No LLM guessing of command names.

## Step 0.5 — Assemble the effective DoD

The checklist is **not hardcoded here.** Build the *effective DoD* for this task
by folding external instruction sources onto the base DoD.

Fold these sources together, precedence **low → high** (a higher source overrides
a lower one on conflict — the user's rules win):

1. **Base DoD** — read `${CLAUDE_PLUGIN_ROOT}/dod/base-dod.md`. The low-precedence baseline.
2. **Your own active instructions** — the standing guidance already governing you
   this session, *however it was provided* (system prompt, project or user
   instructions, enterprise policy — the harness does not assume any particular
   file or location). Extract every completion / Definition-of-Done / quality
   standard in force for you and fold it in. This is what keeps the harness
   **setup-agnostic**: it adapts to whatever instructions you actually run under,
   not to a hardcoded path.
3. **Task-stated verifications** in the task itself (→ these also become
   `task_checks`, Step 6).
4. **Explicit user instructions this session.**

**Merge** every completion-affecting instruction into **one deduped effective
checklist.** **Never silently drop a folded item:** each is a blocking check that
maps to a step below or becomes a `task_check` (Step 6); if genuinely
unenforceable, surface an escalation (A/B/C) with a reason — do not drop it.
**Record the effective DoD verbatim** into done-state `dod` (Step 7) — proof of the
exact standard the changeset was held to.

This assembly runs **on every `/done` invocation** — never cached. A change to your
instructions or the task is picked up automatically next run.

## Step 1 — Changeset scope

Resolve the session id **once** and reuse it downstream (so it can't drift from
the gate's): `SESSION_ID=$(ls -t "$CLAUDE_PROJECT_DIR"/.claude/.harness/baselines/*.sha | head -1 | xargs -n1 basename | sed 's/\.sha$//')`.

Then resolve the changeset base via the shared resolver — do **not** hand-pick a
baseline. Run
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-resolve.sh" "$SESSION_ID"` and
read its printed `base=` and `task_key=` lines. Scope the changeset as
`git diff <base> HEAD` (add `--stat` for the summary). In task mode `<base>` is
the **pinned task base** → the diff spans the whole feature across every session
on this branch; on the trunk/session fallback `<base>` is this session's
baseline. This diff is the scope: **everything downstream is scoped to this
changeset, never the whole repo.**

Task identity = the branch; resume a task by being on its branch (or its
worktree). The base is pinned once at first sight.

## Step 2 — Tests (with before/after checkpoint)

Run the effective test command. Compare against the baseline snapshot at
`.claude/.harness/baselines/<sha>.tests.json` (captured at SessionStart):

- **Newly red** (passed on baseline, fails now) → *you broke it* → **must fix,
  no escape.**
- **Already red** on baseline → genuinely pre-existing. **Boyscout default: fix
  it anyway.** Only after `max_fix_attempts` is exhausted does it become a
  Category C user decision.

The before/after (newly-red vs pre-existing-red) discrimination **depends on the
baseline snapshot**. If that snapshot is **`inert`** (marker `{"status":"inert"}`
in the `.tests.json`) or **absent**, you have no baseline to diff against — you
**must STATE that newly-red vs pre-existing-red discrimination is unavailable**
for this changeset rather than silently proceeding as if every red were
pre-existing.

If a **lint command is configured** (effective `lint` from Step 0), run it too
and record its exit code — you will include `lint: {"exit_code": N}` in the
Step-7 payload. Non-zero → fix (or escalate), same discipline as tests. No lint
command configured → skip; do not fabricate a `lint` field.

## Step 3 — App startup

Run `effective.start` (or the detected startup probe) and confirm the app comes
up. For Docker / systemd / k8s targets that cannot be exercised locally, you
**must state the target explicitly and whether it was exercised** — e.g.
"started the binary; real target is a Docker container, container not
smoke-tested".

If `deploy_check_cmd` is set, run it and check the exit code. If absent, **state**
the deploy target and whether it was exercised — never claim false coverage.

## Step 4 — Code review (independent subagent writes the review-log)

Spawn a **fresh review subagent** (Task tool — e.g. a `code-reviewer` agent)
scoped to the **Step-1 changeset diff**. Its deliverable **is a file it writes
itself** — you do **not** transcribe a count from your own context (that is
self-review; the harness requires an independent reviewer — don't grade your own
homework).

Instruct the subagent to `mkdir -p "$CLAUDE_PROJECT_DIR/.claude/.harness/review-log"`
and **write** `$CLAUDE_PROJECT_DIR/.claude/.harness/review-log/<HEAD>.json`
(where `<HEAD>` is the current `git rev-parse HEAD`) with this schema:

```json
{
  "reviewed_sha": "<HEAD>",
  "findings": [{"severity": "…", "file": "…", "line": 0, "desc": "…"}],
  "open_findings": 0
}
```

`open_findings` is the count of findings the subagent judges still open. The
gate and `done-write-state.sh` both read this log for the **current HEAD** and
require `open_findings == 0`. Because the log is keyed to the reviewed SHA,
fixing a finding (which moves HEAD) automatically invalidates the old log —
re-review is forced for free (Step 5).

## Step 5 — Address findings (bounded loop)

For each open finding: **fix it**, or genuinely can't → escalate (Category C,
after `max_fix_attempts`, default 3 — a per-item counter). After fixing, **commit
(HEAD moves) and re-run Step 4** so a fresh review-log is written for the new
HEAD. Re-review-after-fix is thus forced by the HEAD-keyed log, not by
bookkeeping. A won't-fix finding that does not move HEAD must be escalated, never
silently waived. There is **no findings/addressed counting** — the log for the
final HEAD carrying `open_findings == 0` is the whole proof.

## Step 6 — Task-specific checks

Execute **every** entry in done-state `task_checks` (captured at task start — see
Prerequisite).

- Automatable (API call, CLI run) → run it.
- Visual / UI → use `/verify` or browser tooling, verified against the **real
  target medium and an independent source of truth** (design / spec), never
  against your own render.
- Unreachable → **Category C user-ask**.

**Never silently skip a task check.**

## Step 7 — Write done-state (script)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-write-state.sh "$SESSION_ID"` —
passing the **same `$SESSION_ID` resolved in Step 1** so the writer and the gate
never disagree — supplying the
**judgment fields** as a JSON payload on **stdin** (`dod`, `tests` summary,
optional `lint` summary, `app_started`, `task_checks`, `escalation`). **`review`
is NOT a payload field** — the review evidence is the separate HEAD-keyed
review-log the Step-4 subagent wrote. The script **injects the git facts live** —
`verified_sha` from `git rev-parse HEAD`, `tree_clean` from `git status
--porcelain` — **refuses to write over a dirty tree** (commit first), and (absent
an escalation) refuses unless tests are green, lint is green when configured, and
the review-log for HEAD has `open_findings == 0`. You never hand-write a SHA.

The "dirty tree" refusal is **baseline-relative**: only changes you *introduced*
this session block; files already present at the SessionStart baseline are
warned, not blocked (this is what stops a pre-existing untracked file from
dead-locking the gate). Config `untracked_policy` controls this:
`"baseline"` (default) applies the baseline-relative rule to both untracked and
tracked-modified entries; `"strict"` makes **every** untracked file block
regardless of the baseline (tracked-modified stays baseline-relative). Either
way, the changeset's own new/uncommitted work must be committed before done.
Payload shape (facts are injected, not supplied):

```json
{
  "dod": {
    "sources": ["base", "agent-instructions", "task", "session"],
    "items": ["tests green", "lint green", "app starts", "changeset-scoped independent review", "re-verified after fixes", "verification real not synthetic", "deploy target stated", "visually verify button"]
  },
  "tests": {"exit_code": 0, "newly_red": [], "pre_existing_red": []},
  "lint": {"exit_code": 0},
  "app_started": true,
  "task_checks": [
    {"desc": "visually verify button", "status": "passed", "how": "browser screenshot vs Figma"}
  ],
  "escalation": null
}
```

`lint` is included only when a lint command is configured (Step 2); omit it
otherwise. `dod` records the effective DoD from Step 0.5 verbatim — `sources`
lists the inputs folded in, `items` is the deduped checklist. The script writes
`session_id`, `verified_sha`, `tree_clean` itself and prints the path written.
The review-log at `.claude/.harness/review-log/<HEAD>.json` (Step 4) lives beside
the done-state; both the writer and the gate read it.

## Step 8 — Report

One paragraph: changeset stat, what passed (test counts, app startup, review
outcome, task-check outcomes), and **anything escalated and why**. Escalations
are surfaced on the same turn — **no silent passes.**

---

## Escalation rules

The escape hatch is **not** a self-asserted field. Three categories; only the
last is your judgment, and even that routes to the user.

**A — Environmental / capability block.** The check physically cannot run
(Docker down, needs sudo, no network, missing hardware). The gate passes only on
the **captured real error** from running the command — captured command output
is required as evidence.

```json
"escalation":{"type":"environment","step":"app_startup","command":"docker compose up",
  "captured_error":"Cannot connect to the Docker daemon","exit_code":1}
```

**B — Pre-existing failure.** Fix it (boyscout default); only escalate to C if
out of scope **and** `max_fix_attempts` is exhausted.

**C — Genuinely stuck / out of scope** (only after `max_fix_attempts`). **This
is NOT your call.** Stop and **ask the user** via AskUserQuestion: "Test X
fails, attempts A/B/C didn't fix it — accept and proceed, or keep working?"
Record the *user's* decision plus the attempts made.

```json
"escalation":{"type":"user_accepted","finding":"...","attempts":["...","..."],
  "user_decision":"accept, tracked separately"}
```

Every escalation must be echoed in the Step 8 summary. A and B require captured
command output; C requires an actual AskUserQuestion exchange in the transcript —
a `user_accepted` with no such exchange is a detectable lie.
