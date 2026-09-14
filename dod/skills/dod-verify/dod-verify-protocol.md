
# dod-verify — Task-DoD checklist executor

You are checking **this session's changeset** against the DoD contract
`dod-collect` already recorded at `task-dod/<task_key>.json`. Run the
applicable steps **in order, blocking on each** — never proceed past a
failing step.

**Global rule on failure:** fix it, then **re-verify the affected steps in
order** — re-run tests (Step 2) if code changed; otherwise re-verify just the
step(s) the fix touched.

**Deterministic work lives in scripts, not here.** Config detection +
fingerprinting (Config detection section), git facts + result assembly (Step
7) are delegated to helper scripts so they are testable and can't be
hallucinated. Your job is the judgment: run, read, decide, fix, escalate.

**Parallel work must use separate git worktrees.** Same-directory parallelism
is made *safe* (each session verifies its own changeset) but not fully
*correct* against a peer session sharing the same git identity: `dod`'s
resolver (`hc_resolve` in `scripts/harness-common.sh`) does not carry a
per-commit session-authorship ledger, so two same-identity sessions
committing unrelated work to shared `main` are scoped apart only by the
single resolved base point, not by excluding a peer's interior commits.
Prefer separate worktrees per session to avoid this entirely.

The Stop hook blocks until a valid verification result exists for this
**task** at
`$CLAUDE_PROJECT_DIR/.claude/.harness/task-dod/verified/<task_key>-<HEAD_SHA>.json`.
Use `$CLAUDE_PROJECT_DIR` for the project root (fall back to `$PWD`).
Step 1's resolver resolves `<task_key>` and the changeset base for you.

<a id="step-0"></a>
## Step 0 — Preflight: prove the gate is winnable

**ACTION:** Run `${CLAUDE_PLUGIN_ROOT}/scripts/dod-verify-preflight.sh` **at
TASK START**, before you edit anything or spawn subagents. Non-zero exit =
**HARD problem** — stop and fix or surface it before beginning work; do not
work against an unwinnable gate.

HARD problems include: `baseline_snapshot` enabled but no test command; a
deadlock-risk tree state; a **missing tree baseline (`.dirty`)** —
SessionStart never ran for this id, or its `git status` capture failed (the
capture is atomic: on failure it leaves no file rather than a misleading
empty one). With no baseline the classifier degrades to strict, so every
pre-existing entry blocks and the gate deadlocks. (The gate's own block
message hedges here rather than asserting you introduced those paths — with
no baseline, authorship is undeterminable.) Restart the session so
`baseline-snapshot.sh` records the baseline before you edit.
Only `jq` absent is a non-blocking warning. All problems print exact
remediation.

## Config detection (automatic — runs inside the triage invocation)

No manual action: config detect runs automatically as
`dod-verify-detect.sh | dod-verify-triage.sh` (see SKILL.md).
`dod-verify-detect.sh` prints the **effective** config (`overrides` merged
over `detected`): it probes lockfiles + `package.json`/`Cargo.toml`/`go.mod`/
`pyproject.toml`/`Makefile`, recomputes `source_fingerprint`, and rewrites
`detected` only when the source changed — preserving `overrides`,
`max_fix_attempts`, `max_review_rounds`, `baseline_snapshot`,
`deploy_check_cmd`. No LLM guessing of command names.

**Every changed file is in scope.** Triage asks no "is this a code file?"
question: the harness snapshots git state at SessionStart, and at Stop
everything that changed gets reviewed — prose, config, images, code alike.
The only steps triage can exclude are the ones a config signal proves
vacuous (Step 2-lint with no lint command, Step 3 with no start/start_check/
deploy_check command). Any uncertainty includes the step — fail toward
gating, never toward skipping.

<a id="step-1"></a>
## Step 1 — Changeset scope

**ACTION:** Read `task-dod/<task_key>.json` directly — that IS the contract
whose `requirements[]` you are about to check; there is no separate
assembly step here (that already happened in `dod-collect`). Resolve the
session id **once** and reuse it downstream (so it can't drift from the
gate's), then resolve the changeset base via the shared resolver
(`hc_resolve` in `scripts/harness-common.sh`). Scope everything to `git diff
<base> HEAD` — `dod`'s resolver does not carry a per-commit
session-authorship ledger (see the note on parallel worktrees above), so
there is no finer-grained commit-set scoping available here; use separate
worktrees per session if two same-identity sessions might otherwise collide
on this range.

Resolve the session id in this **precedence** (first hit wins):

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

**WHY it matters:** if this id differs from the id the Stop gate reads (its
hook-stdin `session_id`), a written result would land under a key the gate
never reads → **silent forever block**. If the resolved id has no matching
`baselines/<id>.sha`, the writer (Step 7) rejects it loudly rather than
write a dead key — prefer the `current-session` marker then.

Resolve the base — do **not** hand-pick a baseline. `dod`'s own
`scripts/harness-common.sh` already carries the resolver logic as `hc_resolve`
(sourced by every script in this skill), so there is no separate
`harness-resolve.sh` to invoke here — the steps below source it themselves.

**Everything downstream is scoped to this changeset, never the whole repo.**
Task identity = the branch; resume a task by being on its branch (or
worktree). The base is pinned once at first sight.

Read the contract now:

```bash
DOD_FILE="$CLAUDE_PROJECT_DIR/.claude/.harness/task-dod/<task_key>.json"
jq '.requirements' "$DOD_FILE"
```

Every requirement in this array gets exactly one entry in the `results[]`
array you write in Step 7 (by `requirement_index`, 0-based). None may be
silently dropped.

<a id="step-2"></a>
## Step 2 — Tests (with before/after checkpoint)

**ACTION:** Run the effective test command. Diff it against the baseline
snapshot at `.claude/.harness/baselines/<sha>.tests.json` (captured at
SessionStart):

- **Newly red** (passed on baseline, fails now) → *you broke it* → **must
  fix, no escape.**
- **Already red** on baseline → pre-existing. **Boyscout default: fix it
  anyway.** Only after `max_fix_attempts` is exhausted does it become a
  Category C user decision.

Independent checks may run **concurrently** — lint ∥ tests. Sequential
ordering is required only for a real data dependency (fix → re-verify).

**Confirm the check actually covers the changeset before trusting green.**
Verify the selected command structurally *exercises the Step-1 changed
files*. If it cannot — a scoped runner that excludes the changed package, a
suite that never touches the new path, a filter that skips the changed dir —
a green result is **FALSE coverage**: do NOT report green; state the gap and
**escalate (Category C)**.

**No baseline to diff against:** if the snapshot is **`inert`**
(`{"status":"inert"}` in the `.tests.json`) or **absent**, you **must
STATE that newly-red vs pre-existing-red discrimination is unavailable**
rather than silently treat every red as pre-existing.

**Green must carry evidence — never fake it.** A green test result is
**un-forgeable**: it must be backed by `exit_code: 0` **and** the exact
command you ran **and** an `output_tail` (last ~20 lines) — record these in
the requirement's `evidence` text (Step 7). If tests genuinely cannot run
(environment/capability block — Docker down, no network, missing hardware),
do **NOT** fake success. Raise an escalation (Category A) instead.

<a id="step-2-lint"></a>
### Step 2 (lint) — lint when configured

**ACTION:** If a **lint command is configured** (effective `lint` from
config), run it. Non-zero → fix (or escalate), same discipline as tests. No
lint command → skip; do not fabricate evidence for it.

<a id="step-3"></a>
## Step 3 — App startup

**ACTION (never block indefinitely on a start command):**

- **`start_check_cmd` set (config, default `null`)** → run **it** (an
  explicit readiness probe, e.g. `curl -sf localhost:3000/health`) and check
  its exit code. Correct path for a long-running server.
- **Otherwise** → run the effective `start` **bounded by `start_timeout`
  (config, default `30`s), backgrounded, then terminated.** Success = came
  up / stayed up without crashing within the timeout. Never wait for it to
  return.

**Escalate-vs-reduced-coverage rule:** start cmd exits **non-zero →
escalate (Category A)** with the captured error. Start cmd **starts but
can't be meaningfully smoke-tested** (no HTTP endpoint, needs external
deps) → **state reduced coverage and proceed**.

For Docker / systemd / k8s targets that cannot be exercised locally, **state
the target explicitly and whether it was exercised** — e.g. "started the
binary; real target is a Docker container, container not smoke-tested".

If `deploy_check_cmd` is set, run it and check the exit code. If absent,
**state** the deploy target and whether it was exercised — never claim
false coverage.

This step is independent of the Step-5 review subagent — the two may run
**concurrently**.

<a id="step-4"></a>
## Step 4 — Task-specific checks

**ACTION:** Every requirement in `task-dod/<task_key>.json`'s
`requirements[]` that names a concrete task-specific verification gets
checked here (the base-DoD-derived requirements — tests, lint, app-start,
review — are handled by their own steps above/below; this step covers the
rest). **Never silently skip one.**

- Automatable (API call, CLI run) → run it.
- Visual / UI → use `/verify` or browser tooling, verified against the
  **real target medium and an independent source of truth** (design / spec),
  never your own render.
- Unreachable → **Category C user-ask**.

This confirms the task is **complete and working** *before* the final gate
(Step 5). If a Step-6 fix changes behavior, **re-verify any affected
requirements** so this pass is not silently invalidated.

<a id="step-5"></a>
## Step 5 — Code review (independent subagent writes the review-log)

**ACTION:** Resolve `<base>` (Step 1) and `<head>` (`git rev-parse HEAD`),
then spawn the **local `dod-reviewer` agent** (Task tool, `subagent_type:
"dod-reviewer"` — this plugin ships its own copy in `dod/agents/`, no
`completion-harness:` prefix fallback chain needed). May run
**concurrently** with Step 3.

**Do NOT author the review prompt.** The methodology — exhaustiveness, the
blast-radius question set, the log contract — lives in the agent itself,
precisely so your suspicions cannot narrow it. A reviewer primed with "check
X" finds X and stops.

**Reviewer not resolved → raise a Category A escalation. Do NOT substitute
another agent and do NOT write a review-log.** The reviewer ships in this
bundle, so its definition is on disk beside the skill you are running; what
is missing is the running **session's** registration of it — the session
started before the install, or the plugin cache predates the agent. The fix
is to **restart the session**, and to **reinstall** if a restart does not
resolve it. The gate stays blocked, which is correct.

Pass the agent only: `<base>`, `<head>`, `min_review_level` (config, default
`high`), and the mode — **round 1** (full changeset, `git diff <base>
<head>`) or **round 2** (delta-scoped confirming pass, plus the prior
round's findings; see Step 6). `dod`'s resolver does not carry a per-commit
session-authorship ledger (see Step 1), so there is no `<commits>` list to
pass here — round 1 always reviews the full `<base>..<head>` range.

**Coverage is STRUCTURALLY gated:** `files_reviewed ⊇ changed files`
(`git diff --name-only <base>..HEAD`); a changed file not attested must be treated as
uncovered and blocks the corresponding requirement.

The reviewer's deliverable is the file it writes itself —
`$CLAUDE_PROJECT_DIR/.claude/.harness/review-log/<HEAD>.json`:

```json
{
  "contract_version": 1,
  "reviewed_sha": "<HEAD>",
  "min_review_level": "high",
  "files_reviewed": ["src/a.ts", "src/b.ts"],
  "findings": [{"severity": "high", "file": "…", "line": 0, "desc": "…"}],
  "open_findings": 0,
  "advisory_findings": 0,
  "note": "…"
}
```

Validate it against `contracts/review-log.schema.json` yourself before
trusting it — a missing/malformed `contract_version`, `reviewed_sha`,
`min_review_level`, `files_reviewed`, or `findings` (each
`{severity, file, line, desc}`, `severity` one of
`critical | high | medium | low`, `line` an integer) means the review did
not happen; treat the corresponding requirement as failed, not passed.

`open_findings` / `advisory_findings` are **informational** counts the
subagent records; they are **not** what you trust. **Recompute the blocking
count STRUCTURALLY from `findings[].severity` + config `min_review_level`**
(a finding blocks iff `rank(severity) >= rank(min_review_level)`; ranks
`low=0 medium=1 high=2 critical=3`; an **unknown/missing severity ranks as
BLOCKING** — safe direction). So the reviewer cannot dodge by miscounting —
it must tag severities accurately.

Coverage is computed **per-file by BLOB across all logs in the task's
chain**: a changed file is covered iff **some** chain-log attested it **at
its current blob**. So a follow-up commit only needs re-attestation of the
files whose **blobs it changed**; untouched files carry their earlier
attestation forward for free.

**A HEAD move with an IDENTICAL tree needs no new review-log.** Rewording a
commit (`reset --soft` + recommit, `commit --amend -m`) or a `pull --rebase`
that replays the same patches leaves every blob and mode byte-identical, so
the existing log still describes exactly what is at HEAD — no fresh review
required. A **content-changing** move still requires a fresh log for the new
HEAD.

<a id="step-6"></a>
## Step 6 — Address findings (bounded loop)

**ACTION:** The fix → re-review loop is **bounded** by `max_review_rounds`
(config, default 2) — a **prompt-level** cap you obey, not a script counter.
Round 1 is Step 5's full-changeset review; round 2 is the confirming pass
below.

**Zero-BLOCKING-findings short-circuit (the common, cheap path).** If round
1 returned **zero blocking findings** (at/above `min_review_level`), nothing
gates: HEAD does not move, the review-log already written for the current
HEAD is sufficient, and you are **done reviewing with NO second review**.
This holds even if HEAD later moves **without changing the tree** (a
reworded commit, a replaying rebase) — same tree, same verification; do
**not** re-review for that. Advisory findings may remain; they don't gate. A
clean changeset costs exactly **one** review.

Otherwise (round 1 has blocking findings):

1. **Batch the fixes.** Collect **ALL** blocking findings (plus any trivial
   advisory ones you sweep in — same commit only) and fix them in **one**
   pass. For a finding you can't fix, keep trying up to `max_fix_attempts`
   (default 3, per-item); a won't-fix blocking finding that does not move
   HEAD must be **escalated** (Category C), never silently waived.
2. **Commit ONCE** so **HEAD moves once**, not once per finding. Moving HEAD
   requires a fresh review-log for the new HEAD; blob-keyed coverage means
   only files whose blobs the fix changed need re-attestation — untouched
   files carry forward.
3. **Confirming pass (round 2), scoped to the delta.** Re-run Step 5, but
   scope the fresh review to the **delta since the last-verified HEAD**
   (`git diff <prevHEAD> HEAD`), not the whole changeset — cheaper, and
   where regressions hide. Pass `<prevHEAD>` as the base, the new HEAD, and
   the **prior round's findings**; the confirming-pass question lives in
   the agent definition, so the agent runs it itself. It still writes a
   fresh review-log for the **new HEAD**, with `files_reviewed` listing
   exactly the delta's changed paths (blob-keyed coverage carries untouched
   files forward).
4. **Cap reached → STOP and escalate, do not loop again.** If round 2
   STILL returns **blocking** findings, do **NOT** start a round 3.
   **Escalate via AskUserQuestion** (Category C): present the remaining
   findings and ask *"fix further, or accept and proceed?"* Record the
   decision in the corresponding requirement's escalation-derived
   `evidence` (Step 7).

Below-threshold (advisory) findings do **not** gate — record and report
them in Step 8. You MAY fix trivial ones, but **only inside the same batch
commit** — never in a way that triggers an extra required review round.

**Surface loop-causing fixes:** if a round-1 fix caused a finding to appear
in the round-2 pass, call that out explicitly in the Step 8 report.

<a id="step-7"></a>
## Step 7 — Write the verification result (script)

**ACTION:** Run `${CLAUDE_PLUGIN_ROOT}/scripts/dod-verify-write-result.sh
"$SESSION_ID"` — passing the **same `$SESSION_ID` resolved in Step 1** so
the writer and gate never disagree — supplying the **judgment payload** on
**stdin**:

```json
{
  "results": [
    {"requirement_index": 0, "status": "pass", "evidence": "ran `npm test`, exit 0, 42/42 passing (tail: ...)"},
    {"requirement_index": 1, "status": "pass", "evidence": "review-log <sha>.json: 0 blocking findings at min_review_level=high, files_reviewed matches changed set"},
    {"requirement_index": 2, "status": "skipped", "evidence": "escalation type=environment step=app_startup command='docker compose up' captured_error='Cannot connect to the Docker daemon' exit_code=1"}
  ]
}
```

**One `results[]` entry per `requirement_index`** in the current
`task-dod/<task_key>.json`'s `requirements[]` array — same length, indices
`0..N-1`, no gaps, no duplicates. The script **refuses to write** if the
payload's indices don't match the current contract's `requirements[]`
length — this stops a stale check from silently under- or over-covering a
contract that changed mid-task (`dod-collect` re-invoked with new
requirements).

**`evidence` is bespoke per item, not a shared terse reference.** Write
enough that a reader can see exactly what ran and what it showed for THAT
specific requirement — the exact command, the exit code, the file/line for a
review finding, the escalation detail for a skip. Never a generic "verified"
or "see above".

**Escalations (A/B/C/user_halt) map to `status: "skipped"`.** There is no
separate escalation field in this result shape — the schema's `status` enum
is `pass | fail | skipped` and that is deliberately unchanged. Put the FULL
escalation detail (type, captured command + error, or the user's verbatim
decision) into that item's `evidence` text. `dod-gate.sh`'s existing
fail-count logic only blocks on `status: "fail"`, so a skip with full
escalation detail in evidence is non-blocking — correctly.

The script **injects the git facts live** — `verified_sha` from `git
rev-parse HEAD`, `checked_at` — and **refuses to write over a dirty tree**
(commit first). You never hand-write a SHA.

<a id="step-8"></a>
## Step 8 — Report

One paragraph: changeset stat, what passed (test counts, app startup, review
outcome, task-check outcomes), and **anything escalated and why**.
Escalations are surfaced on the same turn — **no silent passes.**

Include an **EFFORT line**: review rounds used (of `max_review_rounds`), fix
attempts made, and wall-clock elapsed if readily available. **Token/dollar
cost is not measurable from the shell** — do not estimate it;
rounds/attempts/elapsed are the honest accounting.

If the gate passed and the project dir is a worktree on a non-trunk branch,
close the report by telling the user they can run `finish-worktree.sh` to
rebase onto trunk, fast-forward and tear the worktree down. **Say it, never
do it** — integration is the user's call, not a side effect of
verification.

---

<a id="escalation"></a>
## Escalation rules

The escape hatch is **not** a self-asserted field. Three categories; only
the last is your judgment, and even that routes to the user. All four map
to a `status: "skipped"` result entry (Step 7) — never `"pass"`.

**A — Environmental / capability block.** The check physically cannot run
(Docker down, needs sudo, no network, missing hardware). Only justified by
the **captured real error** from running the command — record it verbatim in
`evidence`:

```
evidence: "escalation type=environment step=app_startup command='docker compose up' captured_error='Cannot connect to the Docker daemon' exit_code=1"
```

**B — Pre-existing failure.** Fix it (boyscout default); only escalate to C
if out of scope **and** `max_fix_attempts` is exhausted.

**C — Genuinely stuck / out of scope** (only after `max_fix_attempts`).
**This is NOT your call.** Stop and **ask the user** via AskUserQuestion:
"Test X fails, attempts A/B/C didn't fix it — accept and proceed, or keep
working?" Record the *user's* decision plus the attempts made in `evidence`.

> **Calling AskUserQuestion for a Category-C or `user_halt` escalation is
> safe without any extra marker.** `dod-gate.sh`'s Stop block is
> **category-scoped**: it records the block category it emits
> (`dod-no-verify` when no passing verification result exists yet) and, on
> the very next Stop turn where `stop_hook_active` is true AND the category
> is unchanged, releases silently instead of blocking again. So the turn
> where you call AskUserQuestion — which is still "no passing verification
> result exists" from the gate's point of view — is let through automatically;
> the question reaches the user. The gate only re-blocks for real once you
> actually stop again with the *same* unresolved category repeated a second
> time under `stop_hook_active`, which is the intended runaway guard, not a
> trap on a single legitimate question.

```
evidence: "escalation type=user_accepted finding='...' attempts=['...','...'] user_decision='accept, tracked separately'"
```

**`user_halt` — the user spontaneously stops the task mid-work.** Distinct
from A/B/C (check-blocked): here the user tells you to stop before the gate
is green. Record what IS done and what is NOT — no silent claim of
completion.

```
evidence: "escalation type=user_halt step='<where work stopped>' user_decision='<verbatim what the user said>' completed='<what IS done/verified>' remaining='<what is NOT>'"
```

It is echoed in Step 8, and **disarms only the current changeset**: a later
commit moves HEAD → the gate blocks again → `dod-verify` must re-run.

Every escalation must be echoed in the Step 8 summary. **A and B require
captured command output; C and `user_halt` require an actual user
exchange/statement in the transcript — an escalation with no such evidence
is a detectable lie.**
