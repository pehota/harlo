---
name: done
description: "Completion harness executor. Runs the Definition-of-Done checklist in order — config detect, tests with before/after checkpoint, app startup, task-specific checks, changeset-scoped code review — then writes the per-session done-state that clears the Stop gate. Invoke when finishing a task or when the Stop hook blocks with 'Run /done'."
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
`task_checks`. Step 4 only *runs* them.

## Step 0 (Preflight) — prove the gate is winnable

Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-preflight.sh` **before** the config
detect below — and ideally **at TASK START**, before you edit anything or spawn
subagents. It calls the shared gate logic (`hc_resolve` + `hc_tree_status`) to
report whether the gate is winnable. If it reports a **HARD problem** (non-zero
exit — e.g. `baseline_snapshot` enabled but no test command, or a deadlock-risk
tree state), **stop and fix or surface it** before proceeding; do not begin work
against an unwinnable gate. A **missing tree baseline (`.dirty`)** is a HARD
problem, not a warning: it means SessionStart didn't record the baseline, so the
gate degrades to strict and treats every pre-existing file as yours (guaranteed
deadlock) — restart the session so `baseline-snapshot.sh` records it before you
edit. Only `jq` absent remains a non-blocking warning; all problems print exact
remediation.

## Step 0 — Config: detect / refresh (script)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-detect.sh` and consume its stdout —
the **effective** config (`overrides` merged over `detected`). The script probes
lockfiles + `package.json`/`Cargo.toml`/`go.mod`/`pyproject.toml`/`Makefile`,
recomputes the `source_fingerprint`, and rewrites `detected` only when the source
changed — preserving `overrides`, `max_fix_attempts`, `max_review_rounds`,
`baseline_snapshot`, `deploy_check_cmd`. No LLM guessing of command names.

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
   `task_checks`, Step 4).
4. **Explicit user instructions this session.**

**Merge** every completion-affecting instruction into **one deduped effective
checklist.** **Never silently drop a folded item:** each is a blocking check that
maps to a step below or becomes a `task_check` (Step 4); if genuinely
unenforceable, surface an escalation (A/B/C) with a reason — do not drop it.
**Record the effective DoD verbatim** into done-state `dod` (Step 7) — proof of the
exact standard the changeset was held to.

This assembly runs **on every `/done` invocation** — never cached. A change to your
instructions or the task is picked up automatically next run.

## Step 1 — Changeset scope

Resolve the session id **once** and reuse it downstream (so it can't drift from
the gate's). In SESSION mode the done-state key is `session-<id>`, so if this id
differs from the id the Stop gate reads (its hook-stdin `session_id`), `/done`
writes a valid done-state under a key the gate never reads → **silent forever
block**. Resolve it in this **precedence** (first hit wins):

```bash
# (a) the current-session marker written by SessionStart (baseline-snapshot.sh)
#     from its OWN hook stdin — the authoritative id the gate also derives from,
#     for the supported single-session/worktree model (parallel same-dir is
#     already unsupported);
# (b) the ls -t baselines/*.sha heuristic — LAST resort only.
# NOTE: the $CLAUDE_CODE_SESSION_ID env var is deliberately NOT used — it is
# undocumented and leaks a CHILD-session id into subagent shells, which would
# mis-key the state. The per-project marker is the trustworthy source.
MARKER="$CLAUDE_PROJECT_DIR/.claude/.harness/current-session"
SESSION_ID=""
if [ -f "$MARKER" ]; then SESSION_ID=$(cat "$MARKER"); fi
if [ -z "$SESSION_ID" ]; then SESSION_ID=$(ls -t "$CLAUDE_PROJECT_DIR"/.claude/.harness/baselines/*.sha 2>/dev/null | head -1 | xargs -n1 basename 2>/dev/null | sed 's/\.sha$//'); fi
```

If the resolved id has no matching `baselines/<id>.sha`, the writer (Step 7) will
**reject it loudly** in session mode rather than write a dead key — prefer the
`current-session` marker if that happens.

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

**Confirm the check actually covers the changeset (before trusting green).** After
selecting the effective test/lint command, verify it structurally *exercises the
Step-1 changed files*. If the configured/authoritative check cannot cover the
changeset — a scoped runner that excludes the changed package, a suite that never
touches the new code path, a filter that skips the changed dir — then a green
result is **FALSE coverage**: do NOT report green. State the coverage gap and
**escalate (Category C)** rather than claim the changeset is verified.

Independent checks may run **concurrently** — lint ∥ tests. Sequential ordering is
required only where there is a real data dependency (a fix → re-verify).

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

**Never block indefinitely on a start command.** A `start`/`dev` script for a
server or whole-stack app can boot the entire stack and never return. Do NOT run it
unbounded. Two safe paths:

- **`start_check_cmd` is set (config, default `null`)** → run **it** (an explicit
  readiness probe, parallel to `deploy_check_cmd`) and check its exit code. This is
  the correct path for a long-running server: the operator points it at a
  lightweight probe (e.g. `curl -sf localhost:3000/health`).
- **Otherwise** → run the effective `start` **bounded by `start_timeout`
  (config, default `30` seconds), backgrounded, then terminated.** Success =
  it came up / stayed up without crashing within the timeout. Never wait for it to
  return on its own. If `start` is a server that cannot be meaningfully smoke-tested
  this way (no HTTP endpoint, needs external deps), **STATE that** and treat it as
  **reduced coverage**; if it truly cannot run at all, escalate (Category A) with
  the captured error.

**Whole-stack case (explicit):** either the operator sets `start_check_cmd` to a
lightweight probe, or accepts the timeout-boot-then-kill smoke test. There is no
third "wait forever" option.

For Docker / systemd / k8s targets that cannot be exercised locally, you **must
state the target explicitly and whether it was exercised** — e.g. "started the
binary; real target is a Docker container, container not smoke-tested".

If `deploy_check_cmd` is set, run it and check the exit code. If absent, **state**
the deploy target and whether it was exercised — never claim false coverage.

This step (app/start probe) is independent of the Step-5 review subagent — the two
may run **concurrently**.

## Step 4 — Task-specific checks

Execute **every** entry in done-state `task_checks` (captured at task start — see
Prerequisite).

- Automatable (API call, CLI run) → run it.
- Visual / UI → use `/verify` or browser tooling, verified against the **real
  target medium and an independent source of truth** (design / spec), never
  against your own render.
- Unreachable → **Category C user-ask**.

**Never silently skip a task check.**

This step confirms the task is **complete and working** (tests, app, task_checks
all pass) *before* the final gate — code-solidity review (Step 5). If a
code-review fix (Step 6) changes behavior, **re-verify any affected `task_checks`**
so this earlier pass is not silently invalidated.

## Step 5 — Code review (independent subagent writes the review-log)

Spawn a **fresh, independent, Write-capable** review subagent (Task tool) scoped
to the **Step-1 changeset diff**. This review is independent of the Step-3 app/start
probe and the Step-4 task_checks — you may launch it to run **concurrently** with
Step 3. Its deliverable **is a file it writes itself** —
you do **not** transcribe a count from your own context (that is self-review; the
harness requires an independent reviewer — don't grade your own homework).

**Pick a Write-capable agent type** — e.g. `general-purpose` (or the default
`claude` agent). **Do NOT use a review-only agent type that lacks a Write tool**
(e.g. `feature-dev:code-reviewer`): the deliverable of this step is a *written*
log file, and an agent that cannot Write cannot produce it (this has wasted whole
sessions). "Fresh and independent" means a new subagent with clean context — not
you reviewing your own diff — and that requirement stands regardless of which
Write-capable type you choose.

**Hand the reviewer the REAL diff, not a summary.** Give it the resolved Step-1
`<base>` SHA and the changed-file list, and instruct it to run `git diff --name-only
<base> HEAD` **itself** to get the authoritative changed-file list, then review
**EVERY** file in it via `git diff <base> HEAD`. Do not paraphrase the diff for
it — a summary leaks issues one round at a time (trickle).

**Coverage is STRUCTURALLY gated — attest it truthfully.** Instruct the reviewer to
record the repo-relative paths it examined (as emitted by `git diff --name-only`)
into the review-log's `files_reviewed` array. The gate and `done-write-state.sh`
recompute the changed-file set from `git diff --name-only <base>..HEAD` and require
`files_reviewed ⊇ changed files` — a changed file NOT attested **blocks** with
"review did not cover changed files: …". So the attestation must be **complete and
truthful**: it must list every changed file the reviewer actually examined, and a
false claim (attesting a file it did not read) is visible in the transcript. This is
what makes "the review covered the whole changeset" a structural gate check, not
prose hope — closing the too-narrow-scope leak that causes fix→re-review churn.

**Deterministic-first — spend judgment where tools can't reach.** The tests, lint,
and type-check already ran in Step 2 and catch formatting, style, unused vars, and
type errors **deterministically**. Instruct the reviewer to **NOT re-report issues
those tools catch or would catch** — re-reporting them just generates advisory noise
and burns tokens. Spend its judgment on what deterministic tools **cannot** catch:
logic errors, the blast-radius questions below (especially whether widening a read
also widens a write), missing/insufficient test coverage, broken invariants, and
security. This is what keeps the review **economical**.

**Be EXHAUSTIVE in round 1.** Instruct the reviewer to enumerate **EVERY** issue it
finds, prioritized by severity — do **not** stop at the first few, do **not** cover
only part of the diff. If the changeset is too large to fully cover in one pass, the
reviewer must **say so explicitly** in the log (`"note"` field) and report — never
silently truncate. This up-front exhaustiveness is what stops the fix→re-review
churn caused by trickled findings.

**Tag every finding with `severity`** (one of `critical | high | medium | low`).
Tell the reviewer the configured `min_review_level` (from Step-0 config, default
`high`) and that findings **below** it are **advisory** — it must still list them
(they are recorded/reported in Step 8), but they do not gate.

**Mandatory blast-radius question set.** Instruct the subagent to *actually
answer* each of these in its findings (not merely scan the diff) — a finding for
every "yes":

1. **Does this change widen what is read or accepted? If so, does it ALSO —
   intentionally or not — widen what is written, allowed, or executed?** (This is
   the highest-value question. A read-side widening that leaks into a write-,
   permission-, or execution-side widening is the classic silent-scope bug.)
2. Does it change an invariant, precondition, or contract that other code relies
   on?
3. Are new inputs / branches / error paths validated and handled the **same** as
   the existing ones — or can a failure fall through to a success path?
4. Does the change silently broaden a type, scope, capability, or lifetime beyond
   what the task required?
5. **(Confirming pass only — Step 6)** does a fix in this diff introduce a NEW
   issue elsewhere?

Instruct the subagent to `mkdir -p "$CLAUDE_PROJECT_DIR/.claude/.harness/review-log"`
and **write** `$CLAUDE_PROJECT_DIR/.claude/.harness/review-log/<HEAD>.json`
(where `<HEAD>` is the current `git rev-parse HEAD`) with this schema:

```json
{
  "reviewed_sha": "<HEAD>",
  "min_review_level": "high",
  "files_reviewed": ["src/a.ts", "src/b.ts"],
  "findings": [{"severity": "high", "file": "…", "line": 0, "desc": "…"}],
  "open_findings": 0,
  "advisory_findings": 0
}
```

`files_reviewed` is the repo-relative paths (exactly as `git diff --name-only`
emits them) the reviewer attests it examined. The gate/writer require it to cover
every changed file in `<base>..HEAD` (structural coverage — see above).
Each finding's `severity` is one of `critical | high | medium | low`.
`open_findings` / `advisory_findings` are **informational** counts the subagent
records (blocking vs advisory, by its own read of the threshold). They are **not**
what the gate trusts: **the gate and `done-write-state.sh` recompute the blocking
count STRUCTURALLY from `findings[].severity` and the config `min_review_level`**
(a finding blocks iff `rank(severity) >= rank(min_review_level)`; ranks
`low=0 medium=1 high=2 critical=3`; an unknown/missing severity ranks as
BLOCKING — safe direction). So the reviewer **cannot dodge the gate by miscounting
`open_findings`** — it must tag severities accurately. Because the log is keyed to
the reviewed SHA, fixing a finding (which moves HEAD) automatically invalidates the
old log — re-review is forced for free (Step 6).

## Step 6 — Address findings (bounded loop)

The fix → re-review loop is **bounded** by `max_review_rounds` (from Step-0
config, default 2). This is a **prompt-level** cap you obey — exactly like
`max_fix_attempts` — not a counter tracked by any script. **Round 1** is the
initial full-changeset review of Step 5; **round 2** is the confirming pass below.

**Only findings at/above `min_review_level` must be fixed.** Below-threshold
(advisory) findings do **not** gate — record and report them in Step 8. You MAY
fix trivial advisory findings, but **only inside the SAME batch commit** (one HEAD
move) — **never** fix an advisory finding in a way that triggers an extra required
review round.

**Zero-BLOCKING-findings short-circuit (the common, cheap path).** If the round-1
review returned **zero blocking findings** (findings at/above `min_review_level`),
there is **nothing that gates**: HEAD does not move, the review-log the subagent
already wrote for the current HEAD satisfies the gate, and you are **done reviewing
with NO second review** — advisory findings may remain; they don't gate. This is
why a clean changeset costs exactly **one** review — no size heuristic is needed.

Otherwise (round 1 has blocking findings):

1. **Batch the fixes.** Collect **ALL** blocking findings (and any trivial advisory
   ones you choose to sweep in — same commit only) and fix them in **one** pass. For
   a finding you genuinely can't fix, keep trying up to `max_fix_attempts` (default
   3, per-item); a won't-fix blocking finding that does not move HEAD must be
   **escalated** (Category C), never silently waived.
2. **Commit ONCE.** Commit the whole batch as a single commit so **HEAD moves
   once**, not once per finding. The old review-log (keyed to the previous HEAD)
   is now stale — re-review is forced for free.
3. **Confirming pass (round 2), scoped to the fix diff.** Re-run Step 5, but
   scope the fresh review to the **diff the fix commit introduced** (`git diff
   <HEAD before the fix commit> HEAD`), not the whole changeset again — it is
   cheaper and it is where regressions hide. Include the confirming-pass question
   ("does a fix in this diff introduce a NEW issue elsewhere?"). The subagent
   still writes a fresh review-log for the **new HEAD** (the gate requires it).
4. **Cap reached → STOP and escalate, do not loop again.** If round 2 STILL
   returns **blocking** findings, do **NOT** start a round 3. **Escalate via
   AskUserQuestion** (Category C): present the remaining findings and ask *"fix
   further, or accept and proceed?"* Record the user's decision in `escalation`.

The log for the final HEAD carrying **zero blocking findings** (or a Category-C
`escalation` capturing the user's accept decision) is the whole proof — the gate
recomputes the blocking count structurally from `findings[].severity` +
`min_review_level`; there is **no findings/addressed counting** in any script.

**Surface loop-causing fixes:** if a fix made in round 1 caused a finding to
appear in the round-2 confirming pass, call that out explicitly in the Step 8
report.

## Step 7 — Write done-state (script)

Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-write-state.sh "$SESSION_ID"` —
passing the **same `$SESSION_ID` resolved in Step 1** so the writer and the gate
never disagree — supplying the
**judgment fields** as a JSON payload on **stdin** (`dod`, `tests` summary,
optional `lint` summary, `app_started`, `task_checks`, `escalation`). **`review`
is NOT a payload field** — the review evidence is the separate HEAD-keyed
review-log the Step-5 subagent wrote. The script **injects the git facts live** —
`verified_sha` from `git rev-parse HEAD`, `tree_clean` from `git status
--porcelain` — **refuses to write over a dirty tree** (commit first), and (absent
an escalation) refuses unless tests are green, lint is green when configured, and
the review-log for HEAD has **zero blocking findings** (recomputed structurally
from `findings[].severity` + `min_review_level`, same as the gate). You never
hand-write a SHA.

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
  "review_rounds": 1,
  "escalation": null
}
```

`lint` is included only when a lint command is configured (Step 2); omit it
otherwise. `review_rounds` (integer, **optional**) is your judgment record of how
many review rounds you used (Step 6). It is **informational only** — neither the
writer nor the gate enforces it (no new structural state); it exists so the effort
is captured in done-state alongside the Step-8 report. `dod` records the effective DoD from Step 0.5 verbatim — `sources`
lists the inputs folded in, `items` is the deduped checklist. The script writes
`session_id`, `verified_sha`, `tree_clean` itself and prints the path written.
The review-log at `.claude/.harness/review-log/<HEAD>.json` (Step 5) lives beside
the done-state; both the writer and the gate read it.

## Step 8 — Report

One paragraph: changeset stat, what passed (test counts, app startup, review
outcome, task-check outcomes), and **anything escalated and why**. Escalations
are surfaced on the same turn — **no silent passes.**

Include an **EFFORT line**: review rounds used (of `max_review_rounds`), fix
attempts made, and wall-clock elapsed if readily available. **Token/dollar cost is
not measurable from the shell** — do not estimate it; these rounds/attempts/elapsed
proxies are the honest accounting.

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

**`user_halt` — the user spontaneously stops the task mid-work.** Distinct from
A/B/C (which are check-blocked): here the user tells you to stop before the gate is
green. Record what IS done and what is NOT — no silent claim of completion.

```json
"escalation":{"type":"user_halt","step":"<where work stopped>",
  "user_decision":"<verbatim what the user said>",
  "completed":"<what IS done/verified>","remaining":"<what is NOT>"}
```

It requires an **actual user statement in the transcript** (like Category C — a
`user_halt` with no such statement is a detectable lie). It routes through the
**same gate path** as every escalation (non-null → honored for the current HEAD),
routes to the **USER** (never a silent self-waiver), is echoed in Step 8, and
**disarms only the current changeset**: a later commit moves HEAD → the gate blocks
again → `/done` must re-run.

Every escalation must be echoed in the Step 8 summary. A and B require captured
command output; C and `user_halt` require an actual user exchange/statement in the
transcript — an escalation with no such exchange is a detectable lie.
