
# /done — Completion Harness Executor

You are running the completion gate for **this session's changeset**. Run the
applicable steps **in order, blocking on each** — never proceed past a failing
step.

**Global rule on failure:** fix it, then **re-verify the affected steps in order** —
re-run tests (Step 2) if code changed; otherwise re-verify just the step(s) the fix
touched.

**Deterministic work lives in scripts, not here.** Config detection + fingerprinting
(Config detection section), git facts + done-state assembly (Step 7) are delegated to
helper scripts so they are testable and can't be hallucinated. Your job is the
judgment: run, read, decide, fix, escalate.

**Parallel work must use separate git worktrees.** Same-directory parallelism is made
*safe* (each session verifies its own changeset) but not *correct* (agents still race
on the git tree).

The Stop hook blocks until a valid done-state exists for this **task** at
`$CLAUDE_PROJECT_DIR/.claude/.harness/done-state/<task_key>.json`. Use
`$CLAUDE_PROJECT_DIR` for the project root (fall back to `$PWD`). `harness-resolve.sh`
resolves `<task_key>` and the changeset base: on a feature branch it's the branch
(stable across sessions); on trunk it falls back to the session. Step 1 and Step 7's
scripts resolve it for you.

## Prerequisite — capture `task_checks` at task start

At **task start** (not at `/done` time), extract the explicit verification
requirements from the task statement ("visually verify the button", "confirm the
endpoint returns 200") and record them into done-state `task_checks`. They drift out
of focus by the end otherwise. Step 4 only *runs* them.

<a id="step-0"></a>
## Step 0 — Preflight: prove the gate is winnable

**ACTION:** Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-preflight.sh` **at TASK START**,
before you edit anything or spawn subagents. Non-zero exit = **HARD problem** — stop
and fix or surface it before beginning work; do not work against an unwinnable gate.

HARD problems include: `baseline_snapshot` enabled but no test command; a deadlock-risk
tree state; a **missing tree baseline (`.dirty`)** — SessionStart never ran for this id, or its
`git status` capture failed (the capture is atomic: on failure it leaves no file rather
than a misleading empty one). With no baseline the classifier degrades to strict, so every
pre-existing entry blocks and the gate deadlocks. (The gate's own block message hedges
here rather than asserting you introduced those paths — with no baseline, authorship is
undeterminable.) Restart the session so `baseline-snapshot.sh` records the baseline before
you edit.
Only `jq` absent is a non-blocking warning. All problems print exact remediation.

## Config detection (automatic — runs inside the triage invocation)

No manual action: config detect runs automatically as `done-detect.sh | done-triage.sh`
(see SKILL.md). `done-detect.sh` prints the **effective** config (`overrides` merged
over `detected`): it probes lockfiles + `package.json`/`Cargo.toml`/`go.mod`/
`pyproject.toml`/`Makefile`, recomputes `source_fingerprint`, and rewrites `detected`
only when the source changed — preserving `overrides`, `max_fix_attempts`,
`max_review_rounds`, `baseline_snapshot`, `deploy_check_cmd`. No LLM guessing of command
names.

<a id="step-0-5"></a>
## Step 0.5 — Assemble the effective DoD

**ACTION:** Fold external instruction sources onto the base DoD into **one deduped
effective checklist**, precedence **low → high** (higher wins on conflict):

1. **Base DoD** — read `${CLAUDE_PLUGIN_ROOT}/dod/base-dod.md`.
2. **Your own active instructions** — the standing completion / DoD / quality standards
   governing you this session, *however provided* (system prompt, project/user
   instructions, enterprise policy — no assumed file or location). This keeps the
   harness **setup-agnostic**: it adapts to whatever instructions you actually run under.
3. **Task-stated verifications** (→ also become `task_checks`, Step 4).
4. **Explicit user instructions this session.**

**Never silently drop a folded item:** each is a blocking check that maps to a step
below or becomes a `task_check`; if genuinely unenforceable, surface an escalation
(A/B/C) with a reason — do not drop it. **Record the effective DoD verbatim** into
done-state `dod` (Step 7).

This assembly runs **on every `/done` invocation** — never cached — so a change to your
instructions or the task is picked up automatically.

<a id="step-1"></a>
## Step 1 — Changeset scope

**ACTION:** Resolve the session id **once** and reuse it downstream (so it can't drift
from the gate's), then resolve the changeset base via the shared resolver and scope
everything to `git diff <base> HEAD`.

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

**WHY it matters:** in SESSION mode the done-state key is `session-<id>`. If this id
differs from the id the Stop gate reads (its hook-stdin `session_id`), `/done` writes a
valid done-state under a key the gate never reads → **silent forever block**. If the
resolved id has no matching `baselines/<id>.sha`, the writer (Step 7) rejects it loudly
rather than write a dead key — prefer the `current-session` marker then.

Resolve the base — do **not** hand-pick a baseline:

```bash
RESOLVED=$(bash "${CLAUDE_PLUGIN_ROOT}/scripts/harness-resolve.sh" "$SESSION_ID")
BASE=$(printf '%s' "$RESOLVED" | jq -r '.base')
TASK_KEY=$(printf '%s' "$RESOLVED" | jq -r '.task_key')
```

The resolver prints a **single schema-validated JSON object**
(`{"contract_version":1,"mode":…,"task_key":…,"base":…,"trunk":…,"branch":…,"warn":…}`);
parse it with `jq`, not by grepping key=value lines. It **self-validates** against
`contracts/resolver-output.schema.json` before printing — non-zero exit = it printed
nothing valid → hard failure, surface it. In task mode `<base>` is the **pinned task
base** (diff spans the whole feature across every session on this branch); on the
trunk/session fallback it's this session's baseline. **Everything downstream is scoped
to this changeset, never the whole repo.** Task identity = the branch; resume a task by
being on its branch (or worktree). The base is pinned once at first sight.

<a id="step-2"></a>
## Step 2 — Tests (with before/after checkpoint)

**ACTION:** Run the effective test command. Diff it against the baseline snapshot at
`.claude/.harness/baselines/<sha>.tests.json` (captured at SessionStart):

- **Newly red** (passed on baseline, fails now) → *you broke it* → **must fix, no
  escape.**
- **Already red** on baseline → pre-existing. **Boyscout default: fix it anyway.** Only
  after `max_fix_attempts` is exhausted does it become a Category C user decision.

Independent checks may run **concurrently** — lint ∥ tests. Sequential ordering is
required only for a real data dependency (fix → re-verify).

**Confirm the check actually covers the changeset before trusting green.** Verify the
selected command structurally *exercises the Step-1 changed files*. If it cannot — a
scoped runner that excludes the changed package, a suite that never touches the new
path, a filter that skips the changed dir — a green result is **FALSE coverage**: do
NOT report green; state the gap and **escalate (Category C)**.

**No baseline to diff against:** if the snapshot is **`inert`** (`{"status":"inert"}`
in the `.tests.json`) or **absent**, you **must STATE that newly-red vs
pre-existing-red discrimination is unavailable** rather than silently treat every red as
pre-existing.

**Green must carry evidence — never fake it.** A green `tests` payload is
**un-forgeable**: it must record `exit_code: 0` **and** the exact `command` you ran
**and** an `output_tail` (last ~20 lines). The writer and the gate **refuse a green
`tests` object lacking a non-empty `command` or `output_tail`** — a bare
`{"exit_code": 0}` no longer passes.

**If tests genuinely cannot run** (environment/capability block — Docker down, no
network, missing hardware), do **NOT** fake `exit_code: 0`. Encode
`tests: {"status": "not_run", "reason": "<why they could not run>"}` **and raise an
escalation** (Category A). The writer/gate accept a `not_run` tests object **only** when
an escalation is present; without one it blocks — so an unrun suite can never
masquerade as verified green.

<a id="step-2-lint"></a>
### Step 2 (lint) — lint when configured

**ACTION:** If a **lint command is configured** (effective `lint` from config), run it
and record `lint: {"exit_code": N}` in the Step-7 payload. Non-zero → fix (or escalate),
same discipline as tests. No lint command → skip; do not fabricate a `lint` field.

<a id="step-3"></a>
## Step 3 — App startup

**ACTION (never block indefinitely on a start command):**

- **`start_check_cmd` set (config, default `null`)** → run **it** (an explicit readiness
  probe, e.g. `curl -sf localhost:3000/health`) and check its exit code. Correct path
  for a long-running server.
- **Otherwise** → run the effective `start` **bounded by `start_timeout` (config,
  default `30`s), backgrounded, then terminated.** Success = came up / stayed up without
  crashing within the timeout. Never wait for it to return.

**Escalate-vs-reduced-coverage rule:** start cmd exits **non-zero → escalate (Category
A)** with the captured error. Start cmd **starts but can't be meaningfully
smoke-tested** (no HTTP endpoint, needs external deps) → **state reduced coverage and
proceed**.

For Docker / systemd / k8s targets that cannot be exercised locally, **state the target
explicitly and whether it was exercised** — e.g. "started the binary; real target is a
Docker container, container not smoke-tested".

If `deploy_check_cmd` is set, run it and check the exit code. If absent, **state** the
deploy target and whether it was exercised — never claim false coverage.

This step is independent of the Step-5 review subagent — the two may run **concurrently**.

<a id="step-4"></a>
## Step 4 — Task-specific checks

**ACTION:** Execute **every** entry in done-state `task_checks` (captured at task start).
**Never silently skip one.**

- Automatable (API call, CLI run) → run it.
- Visual / UI → use `/verify` or browser tooling, verified against the **real target
  medium and an independent source of truth** (design / spec), never your own render.
- Unreachable → **Category C user-ask**.

This confirms the task is **complete and working** (tests, app, task_checks all pass)
*before* the final gate (Step 5). If a Step-6 fix changes behavior, **re-verify any
affected `task_checks`** so this pass is not silently invalidated.

<a id="step-5"></a>
## Step 5 — Code review (independent subagent writes the review-log)

**ACTION:** Spawn a **fresh, independent, Write-capable** review subagent (Task tool)
scoped to the **Step-1 changeset diff** (e.g. `general-purpose` — *not* a review-only
agent type lacking a Write tool, since the deliverable is a file it writes itself). May
run **concurrently** with Step 3. Hand it the resolved `<base>` SHA and changed-file
list, and instruct it to:

1. Run `git diff --name-only <base> HEAD` **itself** for the authoritative changed-file
   list, then review **EVERY** file via `git diff <base> HEAD` (never a paraphrased
   summary — a summary leaks issues one round at a time).
2. Record the repo-relative paths it examined into the review-log's `files_reviewed`
   array (exactly as `git diff --name-only` emits them). **Coverage is STRUCTURALLY
   gated:** the gate and `done-write-state.sh` require `files_reviewed ⊇ changed files`
   (recomputed from `git diff --name-only <base>..HEAD`); a changed file not attested
   **blocks** with "review did not cover changed files: …". Attestation must be complete
   and truthful.
3. **NOT re-report issues that tests/lint/type-check already catch** (formatting, style,
   unused vars, type errors — caught deterministically in Step 2). Spend judgment on
   logic errors, the blast-radius questions below, missing test coverage, broken
   invariants, and security.
4. Be **EXHAUSTIVE in round 1**: enumerate **EVERY** issue, prioritized by severity — do
   not stop at the first few. If the changeset is too large to fully cover in one pass,
   say so explicitly in the log's `"note"` field — never silently truncate.
5. **Tag every finding with `severity`** (`critical | high | medium | low`). Tell it the
   configured `min_review_level` (from config, default `high`): findings **below** it are
   **advisory** — it must still list them (reported in Step 8) but they do not gate.

**Mandatory blast-radius question set.** Instruct the subagent to *actually answer* each
(not merely scan the diff) — a finding for every "yes":

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
5. **(Confirming pass only — Step 6)** two-pronged: **(a)** does a fix in this
   diff introduce a NEW issue elsewhere; **(b)** does it INVALIDATE a prior
   finding or assumption about a **carried-forward** file (one that is unchanged
   and previously reviewed, so we are NOT re-reviewing it this pass)?

Instruct the subagent to `mkdir -p "$CLAUDE_PROJECT_DIR/.claude/.harness/review-log"`
and **write** `$CLAUDE_PROJECT_DIR/.claude/.harness/review-log/<HEAD>.json`
(where `<HEAD>` is the current `git rev-parse HEAD`) with **EXACTLY** this shape —
it must include `"contract_version": 1`:

```json
{
  "contract_version": 1,
  "reviewed_sha": "<HEAD>",
  "min_review_level": "high",
  "files_reviewed": ["src/a.ts", "src/b.ts"],
  "findings": [{"severity": "high", "file": "…", "line": 0, "desc": "…"}],
  "open_findings": 0,
  "advisory_findings": 0
}
```

The gate validates this file against `contracts/review-log.schema.json` and **BLOCKS** if
`contract_version` (integer `1`), `reviewed_sha`, `min_review_level`, `files_reviewed`,
or `findings` (each `{severity, file, line, desc}`, `severity` one of
`critical | high | medium | low`, `line` an integer) is missing or malformed. Tell the
subagent this plainly.

`open_findings` / `advisory_findings` are **informational** counts the subagent records;
they are **not** what the gate trusts. **The gate and `done-write-state.sh` recompute the
blocking count STRUCTURALLY from `findings[].severity` + config `min_review_level`** (a
finding blocks iff `rank(severity) >= rank(min_review_level)`; ranks
`low=0 medium=1 high=2 critical=3`; an **unknown/missing severity ranks as BLOCKING** —
safe direction). So the reviewer cannot dodge the gate by miscounting — it must tag
severities accurately.

Coverage is computed **per-file by BLOB across all logs in the task's chain**: a changed
file is covered iff **some** chain-log attested it **at its current blob**. So a
follow-up commit only needs re-attestation of the files whose **blobs it changed**;
untouched files carry their earlier attestation forward for free. Chain-logs are keyed by
raw object id — a log whose basename is not 40/64 lowercase hex is ignored outright.

**A HEAD move with an IDENTICAL tree needs no new review-log.** Rewording a commit
(`reset --soft` + recommit, `commit --amend -m`) or a `pull --rebase` that replays the
same patches leaves every blob and mode byte-identical, so the existing log and
done-state still describe exactly what is at HEAD: the gate compares `head_tree` and
carries them. A **content-changing** move still requires a fresh log for the new HEAD —
and that means *any* difference in a tree entry: one byte in one tracked file, a file
mode flip (`100644` → `100755`), a changed symlink target, or a submodule pointer bump.

**A rewritten anchor stays usable past the next real commit.** When the amend that
carried the verification rewrote the reviewed commit's sha, that log is no longer an
ancestor of HEAD and would drop out of the chain. The done-state records it as
`review_anchor_sha`, and the gate and the writer keep admitting it — resolving its
attested blobs at **its own sha**, so a file the later commit actually changed is
genuinely uncovered and still blocks. Practical effect: after such an amend, the next
commit only needs a review of the files it really touched.

<a id="step-6"></a>
## Step 6 — Address findings (bounded loop)

**ACTION:** The fix → re-review loop is **bounded** by `max_review_rounds` (config,
default 2) — a **prompt-level** cap you obey, not a script counter. Round 1 is Step 5's
full-changeset review; round 2 is the confirming pass below.

**Zero-BLOCKING-findings short-circuit (the common, cheap path).** If round 1 returned
**zero blocking findings** (at/above `min_review_level`), nothing gates: HEAD does not
move, the review-log already written for the current HEAD satisfies the gate, and you are
**done reviewing with NO second review**. This holds even if HEAD later moves **without
changing the tree** (a reworded commit, a replaying rebase) — same tree, same
verification; do **not** re-review for that. Advisory findings may remain; they don't gate.
A clean changeset costs exactly **one** review.

Otherwise (round 1 has blocking findings):

1. **Batch the fixes.** Collect **ALL** blocking findings (plus any trivial advisory ones
   you sweep in — same commit only) and fix them in **one** pass. For a finding you can't
   fix, keep trying up to `max_fix_attempts` (default 3, per-item); a won't-fix blocking
   finding that does not move HEAD must be **escalated** (Category C), never silently
   waived.
2. **Commit ONCE** so **HEAD moves once**, not once per finding. Moving HEAD requires a
   fresh review-log for the new HEAD; blob-keyed coverage means only files whose blobs the
   fix changed need re-attestation — untouched files carry forward.
3. **Confirming pass (round 2), scoped to the delta.** Re-run Step 5, but scope the fresh
   review to the **delta since the last-verified HEAD** (`git diff <prevHEAD> HEAD`), not
   the whole changeset — cheaper, and where regressions hide. The subagent must answer the
   two-pronged confirming-pass question: **(a)** does this delta introduce a NEW issue
   elsewhere, AND **(b)** does it INVALIDATE any carried-forward (unchanged,
   previously-reviewed) file we are NOT re-reviewing? It still writes a fresh review-log
   for the **new HEAD**, with `files_reviewed` listing exactly the delta's changed paths
   (blob-keyed coverage carries untouched files forward). The gate requires the new-HEAD
   log.
4. **Cap reached → STOP and escalate, do not loop again.** If round 2 STILL returns
   **blocking** findings, do **NOT** start a round 3. **Escalate via AskUserQuestion**
   (Category C): present the remaining findings and ask *"fix further, or accept and
   proceed?"* Record the decision in `escalation`.

Below-threshold (advisory) findings do **not** gate — record and report them in Step 8.
You MAY fix trivial ones, but **only inside the same batch commit** — never in a way that
triggers an extra required review round.

The log for the final HEAD carrying **zero blocking findings** (or a Category-C
`escalation` capturing the user's accept decision) is the whole proof — the gate
recomputes the blocking count structurally; no script counts findings/addressed.

**Surface loop-causing fixes:** if a round-1 fix caused a finding to appear in the
round-2 pass, call that out explicitly in the Step 8 report.

<a id="step-7"></a>
## Step 7 — Write done-state (script)

**ACTION:** Run `${CLAUDE_PLUGIN_ROOT}/scripts/done-write-state.sh "$SESSION_ID"` —
passing the **same `$SESSION_ID` resolved in Step 1** so the writer and gate never
disagree — supplying the **judgment fields** as a JSON payload on **stdin** (`dod`,
`tests`, optional `lint`, `app_started`, `task_checks`, `escalation`). **`review` is NOT
a payload field** — the review evidence is the separate HEAD-keyed review-log the Step-5
subagent wrote.

The script **injects the git facts live** — `verified_sha` from `git rev-parse HEAD`,
`head_tree` from `git rev-parse HEAD^{tree}`, `review_anchor_sha` (the review-log it
actually validated), `base_sha` (the changeset anchor it resolved — the gate reads it
back to recover a lost one), and `tree_clean` from
`git status --porcelain` — **refuses to write over a dirty tree**
(commit first), and (absent an escalation) refuses unless tests are green, lint is green
when configured, and the review-log for HEAD has **zero blocking findings** (recomputed
structurally, same as the gate). You never hand-write a SHA.

`head_tree`, `review_anchor_sha` and `base_sha` are **writer-injected facts, never
agent-supplied**: put them in the payload and the writer overwrites — or deletes — them.
When there is no review-log for HEAD but the prior done-state for this task recorded the
**same `head_tree`**, the writer reuses that state's `review_anchor_sha` instead of
refusing — that is the tree-carry case. When a HEAD-exact log *does* exist, a recorded
anchor is still kept in the coverage chain as an orphan, resolved at its own sha (both
cases in Step 5). `base_sha` records the changeset anchor the writer itself
resolved; when the writer has no anchor of its own it carries forward the one the state
it is replacing recorded, so the gate can still scope coverage after a baseline file
goes missing.

The "dirty tree" refusal is **baseline-relative**: only changes you *introduced* this
session block; files present at the SessionStart baseline are warned, not blocked (stops
a pre-existing untracked file from deadlocking the gate). Config `untracked_policy`:
`"baseline"` (default) applies the baseline-relative rule to untracked and
tracked-modified entries; `"strict"` makes **every** untracked file block regardless of
baseline (tracked-modified stays baseline-relative). Either way, the changeset's own
new/uncommitted work must be committed before done.

Payload shape (facts are injected, not supplied):

```json
{
  "dod": {
    "sources": ["base", "agent-instructions", "task", "session"],
    "items": ["tests green", "lint green", "app starts", "changeset-scoped independent review", "re-verified after fixes", "verification real not synthetic", "deploy target stated", "visually verify button"]
  },
  "tests": {"exit_code": 0, "command": "<the exact test command you ran>", "output_tail": "<last ~20 lines of its output>", "newly_red": [], "pre_existing_red": []},
  "lint": {"exit_code": 0},
  "app_started": true,
  "task_checks": [
    {"desc": "visually verify button", "status": "passed", "how": "browser screenshot vs Figma"}
  ],
  "review_rounds": 1,
  "escalation": null
}
```

`lint` is included only when a lint command is configured; omit it otherwise.
`review_rounds` (integer, **optional**) records how many review rounds you used (Step 6);
**informational only** — neither writer nor gate enforces it. `dod` records the effective
DoD from Step 0.5 verbatim: `sources` lists the folded inputs, `items` is the deduped
checklist. The script writes `session_id`, `verified_sha`, `head_tree`, `review_anchor_sha`,
`base_sha` and `tree_clean` itself and prints the path written. The review-log at `.claude/.harness/review-log/<HEAD>.json` (Step 5)
lives beside the done-state; both writer and gate read it.

<a id="step-8"></a>
## Step 8 — Report

One paragraph: changeset stat, what passed (test counts, app startup, review outcome,
task-check outcomes), and **anything escalated and why**. Escalations are surfaced on the
same turn — **no silent passes.**

Include an **EFFORT line**: review rounds used (of `max_review_rounds`), fix attempts
made, and wall-clock elapsed if readily available. **Token/dollar cost is not measurable
from the shell** — do not estimate it; rounds/attempts/elapsed are the honest accounting.

---

<a id="escalation"></a>
## Escalation rules

The escape hatch is **not** a self-asserted field. Three categories; only the last is
your judgment, and even that routes to the user.

**A — Environmental / capability block.** The check physically cannot run (Docker down,
needs sudo, no network, missing hardware). The gate passes only on the **captured real
error** from running the command.

```json
"escalation":{"type":"environment","step":"app_startup","command":"docker compose up",
  "captured_error":"Cannot connect to the Docker daemon","exit_code":1}
```

**B — Pre-existing failure.** Fix it (boyscout default); only escalate to C if out of
scope **and** `max_fix_attempts` is exhausted.

**C — Genuinely stuck / out of scope** (only after `max_fix_attempts`). **This is NOT
your call.** Stop and **ask the user** via AskUserQuestion: "Test X fails, attempts
A/B/C didn't fix it — accept and proceed, or keep working?" Record the *user's* decision
plus the attempts made.

> **Before you call AskUserQuestion for a Category-C or `user_halt` escalation,
> write a pending-escalation marker** so the question turn is not trapped by the
> Stop gate (which would otherwise block that turn — no green done-state exists
> yet — and the user never sees the question):
>
> ```bash
> mkdir -p "$CLAUDE_PROJECT_DIR/.claude/.harness/pending-escalation"
> printf '{"reason":"<why you are asking>"}\n' \
>   > "$CLAUDE_PROJECT_DIR/.claude/.harness/pending-escalation/<task_key>.json"
> ```
>
> (`<task_key>` is the one resolved in Step 1.) The gate consumes this marker
> **once** — the AskUserQuestion turn's Stop is allowed exactly once so the
> question reaches the user; the very next Stop re-gates normally. This is a
> one-shot pass, not a disarm.

```json
"escalation":{"type":"user_accepted","finding":"...","attempts":["...","..."],
  "user_decision":"accept, tracked separately"}
```

**`user_halt` — the user spontaneously stops the task mid-work.** Distinct from A/B/C
(check-blocked): here the user tells you to stop before the gate is green. Record what IS
done and what is NOT — no silent claim of completion.

```json
"escalation":{"type":"user_halt","step":"<where work stopped>",
  "user_decision":"<verbatim what the user said>",
  "completed":"<what IS done/verified>","remaining":"<what is NOT>"}
```

It routes through the **same gate path** as every escalation (non-null → honored for the
current HEAD), routes to the **USER** (never a silent self-waiver), is echoed in Step 8,
and **disarms only the current changeset**: a later commit moves HEAD → the gate blocks
again → `/done` must re-run.

Every escalation must be echoed in the Step 8 summary. **A and B require captured command
output; C and `user_halt` require an actual user exchange/statement in the transcript —
an escalation with no such evidence is a detectable lie.**
