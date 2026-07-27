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

The Stop hook keeps blocking until a valid done-state exists at
`$CLAUDE_PROJECT_DIR/.claude/.harness/done-state/<session_id>.json`. Use
`$CLAUDE_PROJECT_DIR` for the project root (fall back to `$PWD`). Get
`<session_id>` from the baseline filename you were given at session start (or the
most recent `.claude/.harness/baselines/*.sha`) — Step 7's script resolves it.

## Prerequisite — capture `task_checks` at task start

Task-stated verifications ("visually verify the button", "confirm the endpoint
returns 200") drift out of focus by the end, exactly like CLAUDE.md does. So at
**task start** — not at `/done` time — extract the explicit verification
requirements from the task statement and record them into done-state
`task_checks`. Step 6 only *runs* them.

## Step 0 — Config: detect / refresh (script)

Run `$CLAUDE_PROJECT_DIR/.claude/scripts/done-detect.sh` and consume its stdout —
the **effective** config (`overrides` merged over `detected`). The script probes
lockfiles + `package.json`/`Cargo.toml`/`go.mod`/`pyproject.toml`/`Makefile`,
recomputes the `source_fingerprint`, and rewrites `detected` only when the source
changed — preserving `overrides`, `max_fix_attempts`, `baseline_snapshot`,
`deploy_check_cmd`. No LLM guessing of command names.

## Step 0.5 — Assemble the effective DoD

The checklist is **not hardcoded here.** Build the *effective DoD* for this task
by folding external instruction sources onto the base DoD.

1. **Read the base DoD** at `$CLAUDE_PROJECT_DIR/.claude/harness/base-dod.md`
   (note: `harness/`, not the gitignored `.harness/`). Its items are the
   low-precedence baseline.
2. **Scan the external instruction sources**, precedence **low → high** (a later
   source overrides an earlier one on conflict):
   1. `~/.claude/MY_RULES.md` → its "Definition of Done" section
   2. project `CLAUDE.md` / `.claude/CLAUDE.md`
   3. task-stated verifications (→ these also become `task_checks`, Step 6)
   4. **explicit user instructions this session**
3. **Merge** every completion-affecting instruction into **one deduped effective
   checklist.** External/user instructions augment the base DoD and, on conflict,
   **override** the harness defaults — the user's rules win.
4. **Never silently drop a folded item.** Each item is a blocking check: it maps
   to a built-in step below, or becomes a `task_check` (Step 6). If genuinely
   unenforceable, surface an escalation (A/B/C) with a reason — do not drop it.
5. **Record the effective DoD verbatim** into done-state `dod` (Step 7) — proof
   of the exact standard the changeset was held to.

This assembly runs **on every `/done` invocation** — never cached. A change to
`MY_RULES.md`, `CLAUDE.md`, or the task is picked up automatically next run.

## Step 1 — Changeset scope

Resolve the session id **once** and reuse it downstream (so it can't drift from
the gate's): `SESSION_ID=$(ls -t "$CLAUDE_PROJECT_DIR"/.claude/.harness/baselines/*.sha | head -1 | xargs -n1 basename | sed 's/\.sha$//')`.
Then `git diff "$(cat "$CLAUDE_PROJECT_DIR/.claude/.harness/baselines/$SESSION_ID.sha")" HEAD --stat`
(or the merge-base diff on a feature branch). This diff is the scope: **everything
downstream is scoped to this changeset, never the whole repo.**

## Step 2 — Tests (with before/after checkpoint)

Run the effective test command. Compare against the baseline snapshot at
`.claude/.harness/baselines/<sha>.tests.json` (captured at SessionStart):

- **Newly red** (passed on baseline, fails now) → *you broke it* → **must fix,
  no escape.**
- **Already red** on baseline → genuinely pre-existing. **Boyscout default: fix
  it anyway.** Only after `max_fix_attempts` is exhausted does it become a
  Category C user decision.

## Step 3 — App startup

Run `effective.start` (or the detected startup probe) and confirm the app comes
up. For Docker / systemd / k8s targets that cannot be exercised locally, you
**must state the target explicitly and whether it was exercised** — e.g.
"started the binary; real target is a Docker container, container not
smoke-tested".

If `deploy_check_cmd` is set, run it and check the exit code. If absent, **state**
the deploy target and whether it was exercised — never claim false coverage.

## Step 4 — Code review (changeset-scoped, fresh agent)

Invoke `/code-review` scoped to the **Step-1 diff** (spawns an independent
reviewer).

## Step 5 — Address findings (bounded loop)

For each finding: **fix it, or explicitly justify it as N/A.** After fixes,
re-verify (Global rule → Step 2). A **per-item** counter enforces
`max_fix_attempts` (default 3); on exhaustion the item escalates via Category C.

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

Run `$CLAUDE_PROJECT_DIR/.claude/scripts/done-write-state.sh "$SESSION_ID"` —
passing the **same `$SESSION_ID` resolved in Step 1** so the writer and the gate
never disagree — supplying the
**judgment fields** as a JSON payload on **stdin** (`dod`, `tests` summary,
`app_started`, `review`, `task_checks`, `escalation`). The script **injects the
git facts live** — `verified_sha` from `git rev-parse HEAD`, `tree_clean` from
`git status --porcelain` — and **refuses to write over a dirty tree** (commit
first). You never hand-write a SHA. Payload shape (facts are injected, not
supplied):

```json
{
  "dod": {
    "sources": ["base", "~/.claude/MY_RULES.md#definition-of-done", "task"],
    "items": ["tests green", "app starts", "changeset-scoped independent review", "findings addressed", "re-verified after fixes", "verification real not synthetic", "deploy target stated", "visually verify button"]
  },
  "tests": {"exit_code": 0, "newly_red": [], "pre_existing_red": []},
  "app_started": true,
  "review": {"findings": 3, "addressed": 3},
  "task_checks": [
    {"desc": "visually verify button", "status": "passed", "how": "browser screenshot vs Figma"}
  ],
  "escalation": null
}
```

`dod` records the effective DoD from Step 0.5 verbatim — `sources` lists the
inputs folded in, `items` is the deduped checklist. The script writes
`session_id`, `verified_sha`, `tree_clean` itself and prints the path written.

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
