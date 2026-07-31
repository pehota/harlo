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

**Hard contracts underneath.** Every JSON artifact the harness passes between a
producer and a consumer (done-state, review-log, done-config, resolver-output,
done-plan, base-dod) has a declared JSON-Schema under `contracts/` and carries a
`contract_version` (const `1`). This exists so the gate never trusts a field of a
malformed or forged-but-invalid artifact: producers **stamp** the version and
validate before writing; consumers **assert** it via `hc_validate` before reading
a single field. It is the *shape*-level expression of the harness's core posture
("never make the gate easier to pass") — any validation failure fails **toward
BLOCK/refuse**. See *Hard contracts* below.

Flow:

```
[changes made, agent says "done"]
        ↓
[Stop hook fires — reads this session's done-state]
        ↓ HEAD's tree ≠ verified tree (or no state)
[BLOCK: "Run /done before declaring done"]
        ↓
[agent invokes /done]
        ↓
[detect/refresh config → tests → app start → task_checks → code review
 → address findings (batched; ≤ max_review_rounds) → re-verify]
        ↓
[write done-state/<task_key>.json with verified SHA]
        ↓
[agent ends turn → Stop hook fires again → HEAD == verified_sha (or same tree), tree clean]
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

**Session-id resolution (SESSION-mode identity source).** In SESSION mode the
done-state key is `session-<id>`, so the `/done` skill, the writer, and the gate
must all agree on which `<id>` that is — the gate takes it from its Stop-hook
stdin `session_id`. If the skill picks a *different* id, `/done` writes a valid
done-state under a key the gate never reads → a **silent forever-block**. To make
the id authoritative rather than guessed, `baseline-snapshot.sh` (SessionStart)
writes the real `session_id` from its own hook stdin to a single well-known marker
`.claude/.harness/current-session` (overwritten each SessionStart), in addition to
`baselines/<id>.sha`. The skill (and the writer/preflight fallbacks) resolve the id
in precedence: **(a)** the `current-session` marker (authoritative for the
supported single-session/worktree model — parallel same-dir is already
unsupported), else **(b)** the legacy `ls -t baselines/*.sha` heuristic as last
resort. The `$CLAUDE_CODE_SESSION_ID` env var is deliberately **not** used — it is
undocumented and leaks a *child*-session id into subagent shells (and into test
subprocesses), which would mis-key the state; the per-project marker is the
trustworthy source. As a structural backstop, the writer **rejects** a session-mode id with no
matching `baselines/<id>.sha` (see the writer's dead-id rejection below), so a
mismatch fails loudly at `/done` time instead of blocking forever.

`harness-common.sh` also houses `hc_tree_status` — the **single shared
baseline-relative working-tree classifier** used by the gate (Step 3b), the `/done`
writer, and the preflight; **none of them reimplements it.** It classifies each
`git status --porcelain` line relative to a pinned tree baseline (path in
`HC_TREE_BASE_FILE`, set by `hc_resolve`): a line **introduced since the baseline**
is a BLOCKER (`HC_TREE_BLOCKERS`), a line **already present at baseline** is
pre-existing (`HC_TREE_WARNINGS`) and is **ignored — never surfaced** (it is
irrelevant to the changeset and would only invite boyscout scope-creep). A
**missing** baseline file is treated as the empty set → every current change is
"introduced" → blocks (safe direction — never a silent pass). `hc_tree_remediation`
renders the message from the blockers only. The `untracked_policy` knob
(`done-config.json`, default `"baseline"` | `"strict"`) governs untracked lines —
see the config section.

**Missing baseline: block, but don't claim authorship.** `hc_tree_status` also
exports `HC_TREE_BASELINE_MISSING` (1 when there is no baseline file, else 0; always
set, even on a clean tree). The **verdict is unchanged** — still the empty set, still
strict, still blocks. What changes is the *claim*: with no baseline the harness cannot
attribute anything, so `hc_tree_remediation` switches from "commit or stash these
changes you introduced: …" to "no session baseline is recorded, so authorship cannot be
determined — these changes MAY predate this session: …; restart the session (SessionStart
rewrites the baseline), then commit or stash whatever is yours". All four callers — the
two gate block sites, the preflight problem line and the writer's refusal — inherit it.
A **0-byte** `.dirty` is deliberately *not* "missing": it is the legitimate snapshot of a
clean tree at SessionStart, and the capture is atomic so it can only mean that (see
SessionStart, below).

**Accepted gap — what a porcelain-only view cannot see** (documented, not fixed;
stated in full in `hc_tree_status`'s header). The classifier's whole input is plain
`git status --porcelain` — no `--ignored`, no `git ls-files -v` cross-check — so several
things decouple on-disk content from the tree while still presenting as CLEAN here, and
every one is reachable by an agent with a shell: **gitignored files**;
`git update-index --assume-unchanged` / `--skip-worktree`, which hide edits to a
*tracked* file; and `.git/info/exclude`, a repo-local ignore list with .gitignore's force
but invisible in a reviewable diff. So "clean tree" here means "git reports nothing", not
"the working directory matches HEAD". Review coverage is blob-based against committed
content, so anything hidden this way was never attested by the review either. Detecting it
is out of scope by choice — the limit is stated rather than assumed away.

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
  **Task mode never advances the base** — the pinned fork point IS the anchor, so
  `HC_BASE_ORIG` always mirrors `HC_BASE`.
- SESSION mode → `base = baselines/<session_id>.sha` (HEAD at SessionStart), then
  **advanced past leading CONFIDENTLY-FOREIGN commits** (authorship-scoped changeset, #6):
  `hc_resolve` walks `HC_BASE_ORIG..HEAD` oldest→newest and, while the leading commit's
  committer email is **non-empty and provably differs** from the session's
  `git config user.email` (also non-empty), advances `HC_BASE` to it; it **STOPS** at the
  first commit that is not confidently foreign (same email, either email empty, or any git
  error) and keeps that commit and everything after it in the changeset. This is the
  fail-safe direction — any uncertainty keeps the commit in the gate; we never advance past
  a commit that might be the session's, which would let the gate PASS with real work
  unverified. The predicate is **email-only** by design: the old mutable
  `committer_date >= mtime(baseline.sha)` signal was dropped (a touch/copy/clock-skew could
  advance the mtime past a genuinely-authored commit → misclassify it foreign → false
  PASS), and ancestry already bounds the range to commits after the baseline. `HC_BASE_ORIG`
  retains the **unadvanced** baseline so `hc_changeset_summary` (the block-message enricher)
  can honestly report "N authored this session".
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
| Current-session marker | `.claude/.harness/current-session` | authoritative session id (written each SessionStart from hook stdin; the id source for the skill/writer) |
| Session tree-base | `.claude/.harness/baselines/<session_id>.dirty` | session — rewritten each SessionStart; classifier's "pre-existing" set |
| Test snapshot | `.claude/.harness/baselines/<sha>.tests.json` | SHA (shared) |
| Done-state | `.claude/.harness/done-state/<task_key>.json` | **task** — survives session end (optional `.plan` audit field) |
| Review-log | `.claude/.harness/review-log/<HEAD>.json` | reviewed commit |
| Done-plan (audit) | `.claude/.harness/done-plan/<task_key>.json` | **task** — the computed /done plan (audit only; gate has no precondition) |
| Pending-escalation | `.claude/.harness/pending-escalation/<task_key>.json` | **task** — one-shot marker consumed by gate Step 2b |
| Escalation-accept | `.claude/.harness/escalation-accept/<HEAD>.json` | reviewed commit — cross-session accepted-escalation sidecar |
| Config | `.claude/done-config.json` | project |

**Cases:**
- **Multi-session task** — ✅ same branch → same `task_key` → a resumed session inherits the
  done-state and the pinned base; `/done` reviews the whole feature (`base..HEAD`), not just
  the latest session's slice.
- **Parallel in separate worktrees** (recommended) — ✅ different branches → different
  `task_key` → isolated.
- **Same-dir same-branch parallel** — ⚠️ shares the task key; *unsupported* → use worktrees.
- **On trunk** — SESSION fallback (see auto-branch below); one-time warning, never blocks.

The gate re-checks the tree and `HEAD == verified_sha` live (falling back to tree
equality — see Stop-hook Step 5), so stale state from a concurrent commit is caught.

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
- **Writes the authoritative `current-session` marker** — the real `session_id` from its own
  hook stdin, overwritten each SessionStart (see *Session-id resolution* above). This is the
  id the `/done` skill and writer prefer over the `ls -t` heuristic, so they cannot key a
  done-state to an id the gate never reads. The marker is written on **every** source,
  including `compact`.
- **Is source-aware (baseline guard).** SessionStart fires with a top-level `source`
  (`startup | resume | clear | compact | fork`). It fires on `/compact` **and** on
  auto-compaction — **mid-task, with a dirty tree holding the agent's own uncommitted work**.
  On `source == "compact"` SessionStart **preserves an existing** session baseline —
  `baselines/<sid>.sha` **and** the resolved session tree-base `baselines/<sid>.dirty` — and
  writes them **only if absent** (first sight). This stops a mid-task compact from
  re-snapshotting the baseline off the dirty tree, which would capture the agent's own work
  as "pre-existing" (whitelisting it via Invariant-2) and lose the task's real baseline. On
  any other source (`startup|resume|clear|fork`) or an **empty/unknown** source (older CLI)
  it captures/refreshes as before. Task-mode `tree-base/<key>.dirty` is already pin-once
  (never re-seeded), so the guard chiefly protects the SESSION-mode `baselines/<sid>.{sha,dirty}`.
- **Records the tree baseline** (`HC_TREE_BASE_FILE`) **unconditionally, every SessionStart,
  before any edit, even when the tree is clean** — rewritten every session in session mode;
  pinned **once and never overwritten** in task mode. A clean tree legitimately yields a
  **0-byte** file, and that is written, so "missing" (→ strict, authorship unknowable) stays
  distinguishable from "clean at baseline". If the resolver could not run
  (`HC_TREE_BASE_FILE` empty), it falls back to the session-scoped `baselines/<id>.dirty` so
  a `.dirty` path is always chosen — a missing tree baseline makes
  `hc_tree_status` block on every pre-existing file, which deadlocks the gate.
  The capture is **atomic**: `git status --porcelain` writes to a sibling temp file (same
  directory, so the `mv` is a rename, never an interruptible cross-device copy) and is moved
  into place **only on a clean git exit**. `> "$file"` truncates before git runs, so the old
  form could leave a 0-byte file that is byte-identical to "clean at baseline" — the
  classifier would then read an empty-but-healthy baseline and the gate would assert the live
  changes were ones the session introduced. On a failed capture the writer leaves **no file**,
  and **also removes a stale `.dirty` from an earlier session** (reusing it would whitelist
  that session's porcelain as this one's pre-existing set). A transient git failure therefore
  degrades the session to `BASELINE_MISSING` — strict, hedged wording — never to a false
  attribution.
- **Self-seeds config to avoid silent inertness:** when `baseline_snapshot` is enabled but no
  test command is detected, it runs `done-detect.sh` first (fixing the chicken-and-egg where
  a fresh project's empty `detected:{}` meant it never snapshotted).
- **Fails loud, never silently inert:** if there is still no test command, it writes an
  explicit `{"status":"inert",…}` marker to the `.tests.json` **and** surfaces a
  `systemMessage` that the newly-red vs pre-existing-red discrimination is unavailable.
- **Writes the test snapshot atomically** (temp file + `mv`) so a concurrent `/done` never
  reads a half-written file.

### State lifecycle & cleanup

`.claude/.harness/` state is **load-bearing during an in-progress task** — the gate re-reads
`done-state/<task_key>.json` and `review-log/<HEAD>.json` on every turn-end — so it is
never cleaned mid-task. **HARD SAFETY INVARIANT: cleanup must never delete state for a task
that is still in progress, and must never delete the current HEAD's review-log or a live
task's done-state/pins. When in doubt, KEEP. If trunk cannot be confidently determined, the
terminal reap is SKIPPED entirely (never guess "merged").** All cleanup runs at SessionStart,
fully guarded, and never fails the hook.

**1. Age reap (14 days).** `baseline-snapshot.sh` reaps any file under `.claude/.harness/`
older than **14 days** (`find -mtime +14 -delete`) — **excluding `task-base/*` and
`tree-base/*`**, whose pins must live as long as the branch (reaping `tree-base/*` would let
the next SessionStart re-seed the "pre-existing" set from live porcelain and whitelist the
agent's own uncommitted work). Session-mode `baselines/<sid>.dirty` may still be reaped. This
is the ONLY reap that touches SESSION-mode state (`session-<id>` done-states, `baselines/*`) —
there is no branch to test integration against.

**2. Terminal reap (integrated task — "done is done").** After the age reap, for **`br-*` task
keys only**, a task's state is dead once its branch is **merged into trunk**
(`git merge-base --is-ancestor <branch> <trunk>`) or the **branch is gone**. The keep-set of
**LIVE** task keys is computed by the testable helper **`hc_live_task_keys`** in
`harness-common.sh`: for every local branch that exists, is **not** trunk, and is **not**
merged into trunk → `br-$(hc__sanitize <branch>)`. The **current branch is always live**
(the active task, even a freshly-forked branch that is technically an ancestor of trunk).
Any `task-base/<key>.sha`, `tree-base/<key>.dirty`, or `done-state/<key>.json` whose `br-*`
key is **not** in the keep-set (merged or gone) is reaped. Collisions from lossy
sanitization are safe: a key any live branch maps to is in the keep-set → kept. Trunk is
resolved via `hc__detect_trunk`; if it is **empty/unconfident the terminal reap is SKIPPED**.
Session-mode keys are never terminal-reaped.

**3. Review-log hygiene (superseded fix-churn).** `review-log/<HEAD>.json` accumulates one per
fix commit; a log is load-bearing only if `<HEAD>` is a commit the gate might still check — a
local **branch tip** or the **current HEAD** (keep-set from the testable helper
**`hc_live_review_shas`**). Any `review-log/<sha>.json` whose `<sha>` is neither is deleted.
**The current HEAD's log is never deleted** (it is in the keep-set); when the keep-set cannot
be computed (empty — no HEAD and no branches) all logs are kept.

Cleanup is self-healing, needs no `SessionEnd` hook (which wouldn't fire on a crash), and is
parallel-safe — freshly written files from active sessions are far younger than the age
threshold. Durable progress lives in **git**, not in `.harness/`.

---

## Hard contracts (versioned + fail-closed)

Every JSON artifact the harness produces or consumes has a **declared
JSON-Schema** under `contracts/` and carries `contract_version` (const `1`):
`done-state.schema.json`, `review-log.schema.json`, `done-config.schema.json`,
`resolver-output.schema.json`, `base-dod.schema.json`, `done-plan.schema.json`.
Machine producers **stamp** the version; consumers **assert** it by validating
before trusting a field. `install.sh` copies `contracts/` → `.claude/contracts/`;
the library resolves it into `HC_CONTRACTS_DIR`. `done-state` gained an optional
`.plan` field (the folded triage plan); `done-triage.sh` self-validates the plan
it writes against `done-plan.schema.json`.

**Why versioned + fail-closed.** The gate already refuses to trust what the agent
*says* about outcomes (Step 8); the contracts extend that distrust to the
*shape* of the artifacts themselves. A malformed done-state or a forged-but-invalid
review-log must not slip through to the trust-bearing checks — so validation is a
hard gate whose every failure mode (invalid instance, a missing schema file =
broken install, or an unavailable validator = library didn't source) resolves
**toward BLOCK/refuse**, never toward a silent allow. `contract_version` lets a
consumer detect an artifact from an older shape rather than silently
mis-interpret it, and lets `done-detect.sh` **auto-upgrade** a pre-v1 config in
place.

**Why a jq-only validator, not ajv.** `hc_validate <schema> <json>` (in
`harness-common.sh`) implements a deliberately small JSON-Schema **subset** in
pure `jq`. The harness's only hard dependency is already `jq` (the gate degrades
to allow when jq is absent); adding `node`+`ajv` would introduce a second runtime
the shipped bundle can't assume on every dev machine or CI box. The **enforced**
keyword set is `type` (incl. array-of-types unions and `integer`), `required`,
`properties`, `items`, `enum`, `const`, `minLength`, `oneOf`, `not`, and
`additionalProperties` (**boolean form only**). It is **fail-closed on unsupported
keywords (#2)**: any keyword outside that set and a small benign-annotation
allowlist (`$schema`, `$id`, `title`, `description`, `$comment`, `examples`,
`default`, `deprecated`, `readOnly`, `writeOnly`, `definitions`, `$defs`) — e.g.
`pattern`, `minimum`, `anyOf`, `allOf`, `$ref` — is **rejected** at the node where
it appears, and `additionalProperties` written as a **subschema** (rather than a
boolean) is likewise rejected. This closes the false-pass pocket where a schema
author writes a constraint the validator silently does not enforce. The validator
prints `OK`/returns 0 when valid and `ERR: <path>: <what>` (the first violation in
document order)/returns 1 on any invalidity or error — fail-closed by construction
(a jq crash → empty stdout + nonzero rc → treated as `ERR`). `oneOf` powers the
`tests` object's three-way shape (green-with-evidence | non-zero exit | `not_run`).

**Write-time config validation + auto-upgrade.** `done-detect.sh` never publishes
an unvalidated config: it assembles the config in a tempfile, runs `hc_validate`
against `done-config.schema.json`, and only `mv`s it into place if valid — so a
detection bug can never overwrite a good config with a broken one. On an existing
config it rewrites for **two** independent reasons: a changed source fingerprint
(refresh the `detected` block) **or** a missing/mismatched `contract_version`
(auto-upgrade to v1). Both go through the **same** seed-if-absent/preserve-if-present
`jq` merge, so an upgrade seeds any newly-added keys while **preserving every
human-owned field** (`overrides`, `max_fix_attempts`, `trunk`, `min_review_level`,
…) — including a literal `false`. Upgrade-only runs stay minimal and idempotent.

**Resolver → JSON.** `harness-resolve.sh` used to print `key=value` lines. It now
emits a single JSON object conforming to `resolver-output.schema.json`
(`contract_version`, `mode`, `task_key`, `base`, `trunk`, `branch`, `warn`) and
**self-validates** it before printing — on failure it prints nothing and exits
nonzero rather than emit a malformed object. `hc_resolve`'s internals are
unchanged (it still sets the `HC_*` globals); only the wrapper's serialisation
changed. The `/done` skill parses it with `jq` (Step 1), which is both more robust
than grepping lines and self-documenting via the schema.

**The ABI is itself a contract.** `contracts/shell-abi.json` declares each public
`hc_*` function's globals, stdout shape, return codes, and sentinels. It is
**test-enforced**: `completion-harness/tests/test-abi.sh` fails if the real functions drift
from the JSON (a new public function without an ABI entry fails), and
`completion-harness/tests/test-contracts.sh` covers `hc_validate` and the schemas. Both run
under the repo's `run-tests.sh`.

---

## Stop hook: `scripts/done-gate.sh`

Fires on every main-agent turn exit. Logic in order (exact labels from the
script):

1. Read stdin JSON. If `stop_hook_active == true` → **exit 0** (loop guard — a block can never trap the agent forever; blocks are a one-time nudge per stop-continuation chain).
2. Not a git repo (`git rev-parse HEAD` fails) → **exit 0** (no changeset baseline possible).
2a. **Changeset-anchor recovery (empty `HC_BASE`).** `HC_BASE` is empty whenever the resolver found no anchor — session mode with no `baselines/<sid>.sha` (state dir deleted mid-session, 14-day age-reap, or a SessionStart that never ran for the id the gate resolves), a zero-length baseline file, or an empty task pin. Two recoveries, both from **writer-stamped facts**, never agent payload:
   - **`base_sha` in the done-state** for our own key (`hc__recover_base_from_state`). `done-write-state.sh` stamps it from its own resolved `HC_BASE` and **deletes** the key when that base is empty, so it cannot be forged; the helper re-validates it as a raw object id naming a live commit (a symbolic name would resolve against the current tree and self-validate). The writer also carries an existing `base_sha` forward when its own base is empty, so the recovery survives the next `/done` instead of working exactly once.
   - **The `current-session` marker's key** when our own key has *no* state at all — the session-id-disagreement case (`/done` writes under the marker id, the gate resolves a different one from its hook stdin, and reads a key nothing wrote). A candidate set of exactly **two harness-derived paths**, never a directory listing. Adopted **only if that state also supplies a usable `base_sha`**, so the marker path is never weaker than the anchored one (an anchorless adoption would `SKIP` coverage). Session mode only; marker contents are treated as untrusted for filename purposes.

   **Structural safety boundary:** the recovered value lives in `HC_BASE_RECOVERED` and is **never assigned to `HC_BASE`**. `HC_BASE` drives the only two steps that *grant* a pass (Step 3's quiet-exit, Step 3c's empty-changeset allow), so a recovered base equal to HEAD would make a whole unverified session look like "nothing to verify". Keeping them separate makes that trap impossible by construction rather than by predicate. The recovered anchor feeds only the checks that make the gate **stricter**: review coverage and the changeset summary.

   **When neither recovery yields an anchor the gate still BLOCKS** — without one, git cannot distinguish "nothing to verify" from a whole session of unverified commits. Only the *claim* and the *remedy* change (same discipline as `a3b600e`): at **Step 4 only** — no anchor *and* no done-state, where the anchor is the whole story — the reason names the missing `baselines/<sid>.sha`, the ways it goes missing, and the one repair that restores it — restart the session so SessionStart records a baseline. It no longer renders `changeset ..<head> — 0 files` nor instructs a `/done` that cannot fix the anchor. Re-snapshotting the baseline from the gate is **not** the repair: at gate time HEAD already carries the session's commits, so a fresh baseline would whitelist exactly the work under gate. Steps 4b/5/8 keep the **generic** reason: an anchorless done-state is the normal shape of a *legacy* state (pre-`2b740c9`), and blaming a schema-invalid or stale-HEAD state on a missing baseline would be the same misdiagnosis in a new place.
2b. **Pending-escalation one-shot pass (#6).** If `pending-escalation/<task_key>.json` exists, **`rm` it and exit 0 exactly once**. `/done` writes this marker *before* an AskUserQuestion escalation; without the one-shot the question turn's Stop would block (no green done-state yet) and trap the very question meant for the user. One file → one allow; the next Stop finds no file and re-gates. Placed after the git checks and **before** the tree/done-state checks.
3. `HEAD == HC_BASE` **AND working tree clean** → **exit 0** (nothing happened this session). A dirty tree here does NOT exit — it falls through to the checks below (an uncommitted "done" must still be gated).
3a. **Out-of-scope non-code changeset → exit 0 silently (#5).** Runs `hc_tree_status`, then `hc_changeset_is_code(HC_BASE, HEAD)`. If the **whole** changeset is non-code the gate exits 0 with **empty stdout** (no block JSON), mirroring `hc_state` `S_OOS`. The changed-file set = `git diff --name-only HC_BASE..HEAD` ∪ the introduced tree paths (`HC_TREE_BLOCKERS`); a file is non-code iff it matches ≥1 `noncode_globs` pattern (config; conservative prose/docs/images default). **Fail toward gating:** any unknown-extension/code file, or ANY error, classifies the changeset as CODE → normal gate; an absent/empty `noncode_globs` recognises **no** file as non-code. Placed after Step 3 and **before** Step 3b, so introduced **code** dirt still blocks while introduced non-code dirt stands down.
3b. **Working tree has INTRODUCED changes → BLOCK** ("finish the slice"). Moved **ahead of the done-state checks** (P4) so an introduced-dirty tree blocks with the S1 reason, aligned with `hc_state`. Not "any non-empty `git status --porcelain`" — the gate calls the shared `hc_tree_status` classifier and blocks **iff `HC_TREE_BLOCKERS` is non-empty**, i.e. work introduced since the pinned tree baseline. Pre-existing entries are **ignored, not blocked** — this breaks the pre-existing-untracked deadlock **without weakening the gate: the changeset's OWN uncommitted work still blocks**. The block message names only the introduced blockers (`hc_tree_remediation`). `untracked_policy` (default `"baseline"`) tunes untracked handling; `"strict"` blocks every untracked line regardless of baseline. If the classifier can't be sourced, the gate falls back to the **strict** live check — never toward allow.
3c. **Empty committed changeset → exit 0 (#6).** No introduced tree blockers **and** `git diff --quiet HC_BASE HEAD` (the committed range is genuinely empty — e.g. after the authorship base-advance left HEAD atop an identical tree) → nothing to verify → allow. `git diff --quiet` exits 0 only on a truly empty diff; any git failure falls through to the gate.
3d. **SHA-keyed escalation-accept sidecar → exit 0 (cross-session, #6).** If `escalation-accept/<HEAD>.json` exists (written by `done-write-state.sh` on a non-null escalation, keyed to the exact committed HEAD), exit 0. Honored HERE — after the tree/empty checks but **before** the done-state checks — so an accepted escalation survives across sessions on an unchanged trunk HEAD, where a fresh `session-<id>` key has no done-state and Step 4 would otherwise block first. Keyed to the exact sha: any new/amended commit → different sha → no sidecar → re-block. Before the remaining steps the gate builds the block reason by prepending a one-shot `hc_changeset_summary(HC_BASE_ORIG, HEAD)` — file/commit counts and how many commits were authored **this session** (from the unadvanced base, so it reads "0 authored this session" honestly when every commit is foreign).
4. Read `.claude/.harness/done-state/<task_key>.json`. Missing → **BLOCK**.
4b. **Validate the done-state against its contract** (`hc_validate` vs
   `done-state.schema.json`) *before* any of its fields (`verified_sha`, the Step-8
   outcomes) are trusted. Invalid, a missing schema file, or an unavailable
   validator → **BLOCK** — fail closed on shape.
5. `verified_sha != HEAD` → **BLOCK** ("changes committed since last /done — re-run it") **unless the TREE is identical**. A HEAD move is not always a content change: `reset --soft` + recommit to reword, or a `pull --rebase` that replays the same patches, leaves every blob and every mode byte-identical, and the verified content is still exactly what is at HEAD. So on a sha mismatch the gate compares **trees** and carries the verification when they are equal (`CARRY=1`); everything downstream (Step 8's outcomes, severity, coverage) still runs in full. Sources, in order: the done-state's writer-injected `head_tree`, else — for LEGACY states written before that field existed — the tree recomputed live from `verified_sha`; and when `verified_sha` still resolves, its own tree is cross-checked too. **Fail direction unchanged:** an empty HEAD tree, an unobtainable recorded tree, or any mismatch → BLOCK. Deliberately **not** ancestry: ancestry is strictly weaker (`reset --hard` past an empty commit yields an identical tree *and* a descendant `verified_sha`, so it would admit content changes on top of everything tree equality already covers). What still blocks is anything that changes a **tree entry** — one byte in one tracked file, a file mode flip, a changed symlink target, a submodule (gitlink) pointer bump.
7. `escalation` present and non-null in the done-state → **exit 0** (escape hatch — see escalation rules). Honored **after** the SHA check (5) and the tree check (3b), so it disarms only the exact committed changeset it was recorded against.
8. **Checklist outcomes not all green** → **BLOCK**. With no escalation, all must hold:
   - `tests.status != "not_run"` — a `not_run` here (no escalation short-circuited at Step 7) is an unverified green claim → BLOCK; `not_run` is accepted only with an escalation.
   - `tests.exit_code == 0` **AND** non-empty `tests.command` **AND** non-empty `tests.output_tail` — green tests must carry **evidence** (P1-c, #6); a bare `{"exit_code":0}` is blocked ("green tests must carry evidence").
   - `lint.exit_code == 0` **if `.lint` is recorded** (projects with no lint command skip this)
   - an **independent review-log exists** for this verification. The candidate set is
     **exactly two harness-derived paths, never a directory listing**:
     `.claude/.harness/review-log/<HEAD>.json` (preferred), plus the **anchor**
     `review-log/<review_anchor_sha>.json` — the log the done-state records its
     verification as resting on (legacy states with no such field fall back to
     `verified_sha`). The anchor must be a raw object id; a symbolic value would resolve
     against the live tree and self-validate. It is admitted **whenever its log exists**,
     not only on a carry: the `/done` that *follows* a carry writes a done-state at the new
     sha, which takes the sha-equal path, and gating admission on the carry flag would
     re-block one turn later. The resolved log **passes its contract**
     (`hc_validate` vs `review-log.schema.json`; invalid / missing schema /
     unavailable validator → BLOCK, *before* its fields are read) and has **zero
     BLOCKING findings**.
     The blocking count is **computed structurally by the gate** (`hc_review_blocking`
     in `harness-common.sh`) from `findings[].severity` and the configured
     `min_review_level` (default `high`): a finding blocks iff
     `rank(severity) >= rank(min_review_level)` (ranks `low=0 medium=1 high=2
     critical=3`). Findings below the threshold are **advisory** and never gate.
     An unknown/missing severity ranks as blocking (safe direction); a missing
     log or a jq failure blocks. When the `findings` key is **present** it must be
     an array — a present-but-non-array `findings` is treated as malformed and
     blocks, and the self-reported `open_findings` is never consulted (anti-forgery);
     an empty `findings: []` legitimately counts zero and allows. The
     `open_findings` integer is a backward-compat fallback used **only when the
     `findings` key is entirely absent** (old-style logs).
   - **the review-log's `files_reviewed` covers every changed file** — structural
     coverage, computed **per-(file, blob) across the task's review-log chain**
     (#1/P5). The gate computes the changed set from `git diff --name-only
     <HC_BASE>..HEAD` and, via the shared `hc_review_coverage_gap` (same function
     the writer uses), marks a changed file COVERED iff **some** chain-log attested
     it **at its current blob** (its content at HEAD). Unlike the two-path candidate
     set above, the **chain** *is* derived by iterating the log's directory: it is
     every `review-log/<sha>.json` whose `<sha>` is an ancestor of HEAD but not of
     HC_BASE (task-side, up to and including HEAD); the attested blob is recomputed
     live from each log's `reviewed_sha`. Chain membership therefore requires a basename
     that is a **raw object id** — 40 (sha1) or 64 (sha256) lowercase hex characters.
     Anything else (`HEAD.json`, `main.json`, `HEAD@{0}.json`) is skipped **before** the
     two `merge-base` calls, so junk basenames also cost zero forks. Without that guard a
     symbolic basename entered the chain — `merge-base --is-ancestor HEAD <head>` is
     trivially true and the freshness check then resolved `rev-parse HEAD:<path>`, the
     *current* blob — so such a log self-validated and its attestation never expired. The
     realistic exploit: a legitimate `<HEAD>.json` attesting `files_reviewed: []` plus a
     stray `HEAD.json` attesting the changed paths yields an empty gap and an unreviewed
     changeset sails through. So a **follow-up commit only
     needs re-attestation of the files whose blobs it changed** — untouched files
     carry their earlier attestation forward for free, which ends the "re-review
     the whole changeset on every HEAD move" churn. A deleted file (no blob at
     HEAD) is covered by simple path-attestation in some chain-log. A changed file
     not attested at its current blob → non-empty gap → **BLOCK** ("review did not
     cover changed files: …"). A missing/non-array `files_reviewed`, a jq error, or
     a rebase/gc making an old `reviewed_sha` unreachable all leave the file in the
     gap → block (fail toward block: prefer an unnecessary re-review to trusting an
     attestation whose commit no longer exists). When **no changeset base** is
     resolvable (neither `HC_BASE` nor the recovered `HC_BASE_RECOVERED` of Step 2a) or
     the diff cannot be computed, the function returns `SKIP` and the gate does **not**
     block on coverage — a no-regression degrade.

     **Two admission overrides for the anchor**, both bypassing the ancestry test that a
     rewritten anchor's sha can no longer satisfy. They differ *only* in the rev the
     anchor's attested blobs resolve against, and that difference is the whole safety
     argument — the gate and the writer pick between them on the **same discriminator**
     (does a HEAD-exact log exist?), so they always resolve an identical candidate set:
     - **no HEAD-exact log** → the anchor *is* this verification's log, and Step 5 has
       just proved the recorded tree equals HEAD's. Admitted as `extra_admit` (5th arg):
       blobs resolve at `<head>`, which is byte-identical given equal trees and survives
       a gc that pruned the anchor.
     - **a HEAD-exact log exists** → a later *real* commit has moved the tree on, so the
       anchor is an **orphan**: it still attests files that commit did not touch, but is
       no longer content-equal to HEAD. Head-resolution would make every path it ever
       listed self-validate. Admitted as `chain_admit` (6th arg) instead: blobs resolve
       at the **anchor's own sha**, so coverage is a genuine blob comparison and a file
       the later commit actually changed is not covered. An anchor lost to gc resolves to
       no blob, contributes nothing, and its files fall into the gap — fail toward block,
       never a head-resolution fallback. Severity still comes from the HEAD-exact log.

     Both modes are checked **after** the hex-basename guard, so a symbolic anchor cannot
     enter the chain through either door. This is what keeps an orphaned anchor useful
     past the next real commit: without it, a tree-identical carry bought exactly one
     commit before the rewritten sha dropped out of the chain and unchanged files were
     re-demanded.
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
checks that an admissible log exists for the current HEAD and that its **blocking count,
recomputed structurally from `findings[].severity` vs `min_review_level`, is zero**. This
gives genuine independence (don't grade your own homework) and forces
**re-review-after-fix for free**: fixing a finding changes content, so HEAD moves to a
*different tree* → the old log no longer describes HEAD → step 8 blocks until a fresh log
is written for the new HEAD. (A HEAD move that does *not* change the tree is not a fix, and
carries — Step 5.) No `findings == addressed` bookkeeping to trust.
Won't-fix findings that don't move HEAD route to the **escalation** path (step 7), not a
waiver.

**Escalation is honored before the outcome check (step 7 before 8)** but after the SHA and
tree checks (5, 6) — so an escalation disarms only the exact committed changeset it was
recorded against. Later commits move HEAD → step 5 blocks → `/done` must run again. This
prevents a stale escalation from disarming the gate for the rest of the session
(independent-review finding).

`done-write-state.sh` mirrors step 8: it **refuses to write** a done-state unless (with no
escalation) `tests.exit_code == 0`, `lint.exit_code == 0` when lint is configured, a
review-log for the current HEAD exists — one that **passes `review-log.schema.json`** (a
forged/malformed log is refused here, before `hc_review_blocking`/`hc_review_coverage_gap`
run) — with **zero blocking findings** (recomputed by the same `hc_review_blocking` from
`findings[].severity` + `min_review_level`), and the log's `files_reviewed` **covers every
changed file** in `<HC_BASE>..HEAD` (recomputed by the same `hc_review_coverage_gap` the gate
uses, with the anchor passed through in the same `extra_admit`/`chain_admit` mode the gate
would pick; `SKIP` when no base is resolvable → no coverage refusal). It resolves the review
anchor by the **same rules as the gate**, legacy recompute included, so it never refuses a
write the gate is about to accept. It **stamps
`contract_version: 1`** into the assembled state and, **unconditionally**, validates it
against `done-state.schema.json` before it reaches disk — escalation bypasses the green-OUTCOME
refusals only, never the structural-validity gate; an invalid state is never written. So the
writer and the gate can never diverge and the agent gets the feedback at `/done` time rather
than at stop time. Its dirty-tree refusal uses the **same
`hc_tree_status` classifier** as the gate: it refuses **iff introduced blockers exist**
(the changeset's own uncommitted work), writes when only pre-existing warnings remain, and
sets `tree_clean` to reflect "no blockers" (not "no dirt at all"). The gate remains the
structural backstop (it fires even if the file was hand-written).

**Dead-id rejection (SESSION mode).** Before writing, the writer rejects — exit
nonzero, no done-state — a session-mode `session_id` that has **no matching
`baselines/<id>.sha`**. Such an id keys the done-state to `session-<id>`, but the
gate derives its own `session-<gate-id>` key from its Stop-hook stdin; if they
differ, the gate never reads what the writer wrote → a **silent forever-block**.
Failing loud here (the error lists the valid ids and the `current-session` marker,
and tells the agent to pass the id the gate uses) converts that silent deadlock
into an actionable `/done`-time failure. In TASK mode the branch keys the
done-state, so this check applies only to the session-mode path.

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

## `/done` skill: `skills/done/SKILL.md` + `dod-protocol.md`

User-invocable. Steps run in order, blocking on each (stated once, globally — a failing
step means fix and re-run from Step 2).

**Split for progressive disclosure (#7).** The skill is two files: a **thin
`SKILL.md`** entry point and the full **`dod-protocol.md`** reference. `SKILL.md`
runs the deterministic triage (`done-detect.sh | done-triage.sh`), which computes
**exactly which DoD steps apply** to this changeset and prints them as
`[id] <intent> → dod-protocol.md#<anchor>` lines; the agent then reads each
applicable step's section from `dod-protocol.md` **on demand** rather than
pre-reading the whole protocol.

**The triage + audit plan (`done-triage.sh` → `done-plan/<task_key>.json`).**
`done-triage.sh` reads the effective config (from `done-detect.sh` on stdin, else
recomputed), decides applicability with a **fail-safe direction — a step is
excluded only when a deterministic config signal proves it vacuously N/A; any
uncertainty INCLUDES it** — and writes the **full** ordered plan (applicable
*and* excluded, each with a reason) to `done-plan/<task_key>.json`, self-validated
against `done-plan.schema.json` before anything is emitted. Currently only two
steps are conditionally excluded: `2-lint` (no lint command configured) and `3`
(no `start` / `start_check_cmd` / `deploy_check_cmd` configured); every other step
is always applicable. The plan is **audit-only** — Step 7 folds it into done-state
as a `.plan` field, but the **gate gains NO precondition on it**. On any hard error
(jq missing, unreadable config, self-validation failure) triage exits non-zero with
empty stdout and the SKILL **fallback runs ALL steps** — a wrongly-excluded step is
the one unacceptable outcome. **Honest framing:** the primary value is
*deterministic applicability + an auditable plan* (and progressive-disclosure
reading); token savings are secondary.

**Deterministic work lives in scripts, not prose.** The protocol body carries only the
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
before/after red-test discrimination would be inert), **pre-existing blockers** in the
tree, and a **missing tree baseline (`.dirty`)** — in which case the skill must stop and
fix/surface before working. The missing-`.dirty` case is a HARD problem, **not a warning**:
without a baseline, `hc_tree_status` treats every pre-existing file as introduced → the gate
blocks on files the agent never touched → a **guaranteed deadlock**. Its remediation:
restart the session so SessionStart records the tree baseline (only `jq` absent remains a
non-blocking warning). It **never seeds a permissive baseline** when one is missing (it can
run after edits, which would whitelist the agent's own work) — it reports the gap and tells
the user to restart the session so SessionStart pins it.

**Prerequisite — capture `task_checks` at task start.** Task-stated verifications drift
out of focus like standing instructions; the agent records them into done-state `task_checks` when the
task begins, not at `/done` time. (Executed in Step 4.)

### Step 0 — Config: detect / refresh (script: `done-detect.sh`)

Run `done-detect.sh`. It probes lockfiles + `package.json`/`Cargo.toml`/`go.mod`/
`pyproject.toml`/`Makefile`, recomputes `source_fingerprint`, and — if missing or changed —
rewrites `detected` while preserving `overrides` (`effective = override ?? detected`).
Emits the effective config to stdout. No LLM guessing of command names.

### Step 0.5 — Assemble the effective DoD (fold in external instructions)

The checklist is **not hardcoded**. Build the *effective DoD* for this task by folding
external instruction sources onto the base DoD (see "Harness Definition of Done" below):
read base DoD → scan each source → merge every completion-affecting instruction into one
deduped checklist. External/user instructions augment and, on conflict, **override** the
harness defaults (the user's rules win). Record the effective DoD verbatim into done-state
`dod` — every task then carries proof of the exact standard it was held to. Each item in the
effective DoD is a blocking check enforced by the steps below; an item with no matching
built-in step becomes a task_check (step 4).

### Step 1 — Changeset scope

Resolve the session id first (env var → `current-session` marker → `ls -t`
heuristic; see *Session-id resolution*), reuse it downstream so it can't drift
from the gate's, then `git diff <baseline_sha> HEAD --stat` (or merge-base diff on
a feature branch). Everything downstream is scoped to **this changeset**, never
the whole repo. The base/`task_key` come from `harness-resolve.sh`, which now
prints a **single self-validated JSON object** (`resolver-output` contract);
parse it with `jq` (`.base`, `.task_key`), not by grepping `key=value` lines.

### Step 2 — Tests (with before/after checkpoint)

Run the effective test command. Diff results against the baseline snapshot
(`.claude/.harness/baselines/<sha>.tests.json`, captured at SessionStart):

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
(or escalate), same as tests. Independent checks (lint ∥ tests) may run concurrently.

**Coverage confirmation:** confirm the effective check structurally exercises the Step-1
changed files. A check that cannot cover the changeset (scoped runner excluding the changed
package, suite not touching the new path) yields **false coverage** — state the gap and
escalate (Category C), never report green.

### Step 3 — App startup

**Never block indefinitely** — a `start`/`dev` script for a server or whole-stack app can
boot the whole stack and never return. Two safe paths: if `start_check_cmd` (config, default
`null`) is set, run **it** (an explicit readiness probe, parallel to `deploy_check_cmd`) and
check its exit code; otherwise run the effective `start` **bounded by `start_timeout`
(config, default `30`s), backgrounded, then terminated** — success = came up / stayed up
without crashing within the timeout. The whole-stack operator either sets `start_check_cmd`
to a lightweight probe or accepts the timeout-boot-then-kill smoke test; there is no
wait-forever option. A server that can't be meaningfully smoke-tested → **state reduced
coverage** (Category A if it truly can't run). Docker/systemd/k8s targets that can't be
exercised locally → the agent must **state the target explicitly and whether it was
exercised** ("started the binary; real target is a Docker container, container not
smoke-tested"). The app/start probe is independent of the Step-5 review — they may run
concurrently. Failure → fix → return to step 2.

### Step 4 — Task-specific checks

Execute every entry in done-state `task_checks` (captured at task start — see Prerequisite).
Automatable (e.g. an API call, a CLI run) → run it. Visual/UI → `/verify` or browser
tooling, verified against the **real target medium and an independent source of truth**
(design/spec), never against the agent's own render. Unreachable → Category C user-ask.
**Never silently skipped.** This step confirms the task is **complete and working** (tests,
app, task_checks) *before* the final code-solidity review (Step 5); if a Step-6 code-review
fix changes behavior, any affected `task_checks` are re-verified so this earlier pass isn't
silently invalidated.

### Step 5 — Code review (independent subagent writes the review-log)

Spawn a **fresh, independent, Write-capable** review subagent. **Hand it the REAL diff, not
a summary:** give it the resolved Step-1 `<base>` SHA + the changed-file list and instruct it
to run `git diff --name-only <base> HEAD` **itself** to get the authoritative changed-file
list and review **every** file in the **full changeset**. Its deliverable **is
the file** `.claude/.harness/review-log/<HEAD>.json` — it writes the log itself:
`{ "contract_version": 1, "reviewed_sha": "<HEAD>", "min_review_level": "high",
"files_reviewed": [paths …], "findings": [ {severity, file, line, desc} … ],
"open_findings": <n>, "advisory_findings": <n> }`. The log must carry
`contract_version: 1` and conform to `review-log.schema.json`: the gate (Step 8)
and the writer both `hc_validate` it and BLOCK/refuse on a malformed or
version-less log *before* any severity/coverage reasoning runs, so the subagent
must produce a well-shaped log. `files_reviewed` is the repo-relative paths (as `git diff --name-only` emits them)
the reviewer attests it examined; the gate/writer require it to cover every changed file in
`<base>..HEAD` **structurally** (a changed file not attested blocks), so the attestation
must be complete and truthful. **Deterministic-first (prompt-level economy):** the reviewer
is told **not** to re-report what the Step-2 tests/lint/type-check already catch (formatting,
style, unused vars, type errors) — that is advisory noise — and to spend its judgment on
what those tools cannot catch (logic errors, blast-radius, missing test coverage, broken
invariants, security). Because the deliverable is a
*written* file, the agent type must have a Write tool (e.g. `general-purpose`); a review-only
type that lacks Write (e.g. `feature-dev:code-reviewer`) cannot produce the log and must not
be used. The main agent does **not** transcribe a count from its own context (that would be
self-review — the harness requires an independent reviewer; don't grade your own homework).

The reviewer must be **EXHAUSTIVE**: enumerate **every** issue prioritized by severity, not
stop early, and if the diff is too large to fully cover, **say so explicitly** in the log —
this up-front thoroughness is what prevents findings trickling out one round at a time. It
must *answer* a mandatory blast-radius question set — foremost **"does a widening of what is
read/accepted also widen what is written, allowed, or executed?"**, plus invariant/contract
changes, new-branch/error-path parity, and silent scope broadening — not merely scan the diff.

Each finding is tagged `severity` (`critical|high|medium|low`). `open_findings`/
`advisory_findings` are **informational** — the gate and writer **recompute the blocking
count structurally** from `findings[].severity` + the config `min_review_level` (default
`high`), so the reviewer **cannot dodge the gate by miscounting**; it must tag severities
accurately. Findings below `min_review_level` are advisory (still listed). The gate later
checks that the admissible log for the current HEAD — the HEAD-exact one, else the
done-state's recorded `review_anchor_sha` — has **zero blocking findings** (Stop-hook
Step 8).

### Step 6 — Address findings (bounded loop, capped)

**Only findings at/above `min_review_level` gate.** Below-threshold (advisory) findings are
recorded/reported (Step 8) but never force a round; a trivial advisory fix may be swept into
the **same batch commit** (one HEAD move) but must never trigger an extra required round.

**Zero BLOCKING findings → single review:** if round 1 returns zero blocking findings, HEAD
does not move, the existing review-log satisfies the gate, and there is **no second review**
(advisory findings may remain) — a clean changeset costs exactly one review. This holds even
if HEAD later moves **without changing the tree** (a reworded commit, a replaying rebase):
same tree, same verification, no re-review.

Otherwise: **batch** ALL blocking findings into **one** fix pass and **commit once** (HEAD
moves once, not once per finding), then run **one** confirming pass (round 2) — a fresh Step-5
review **scoped to the fix diff** (cheaper, and where regressions hide), which writes a new
review-log for the new HEAD. The loop is capped by `max_review_rounds` (default 2): if round 2
still has blocking findings, **do not loop again — STOP and escalate via AskUserQuestion**
(Category C) with the remaining findings ("fix further, or accept and proceed?"), recording the
user's decision in `escalation`. Per-item, an unfixable finding still gets `max_fix_attempts`
tries. A won't-fix finding that doesn't move HEAD must be escalated, never silently waived. If a
round-1 fix caused a round-2 finding, that is surfaced in the Step-8 report.

### Step 7 — Write done-state (script: `done-write-state.sh`)

The LLM supplies only the judgment fields (`dod`, `task_checks`, `escalation`, `tests` and
`lint` summaries) as a JSON payload. The script **injects the git facts live** —
`verified_sha = git rev-parse HEAD`, `head_tree = git rev-parse HEAD^{tree}`,
`review_anchor_sha` (the review-log it actually validated), `base_sha` (the changeset
anchor it resolved) and `tree_clean` from the `hc_tree_status` classifier —
and **refuses to write** when the tree has **introduced blockers** (baseline-relative, same
classifier as the gate — pre-existing entries are ignored), or when (absent an escalation)
tests/lint aren't green or the review-log for HEAD has **blocking findings** (recomputed
structurally from `findings[].severity` + `min_review_level`, same as the gate). No
hand-written SHA strings. It **stamps `contract_version: 1`** and validates the assembled
done-state against `done-state.schema.json` **before writing** (unconditional — escalation
never bypasses structural validity); an invalid state is refused, never reaches disk.
The `review` outcome is **not** a payload field — it is the separate review-log artifact
(Step 5), which the gate and the writer both read.

`head_tree`, `review_anchor_sha` and `base_sha` are **facts, never agent-supplied**: the
writer overwrites them from live git, and `del()`s the key when the value is empty, so a
payload-supplied value can never survive into the state and forge what the tree-carry
(Step 5) or the anchor recovery (Step 2a) trusts. None of the three is `required` in
`done-state.schema.json`, so every pre-existing done-state still validates; a legacy state
without `head_tree` carries via the live `rev-parse <verified_sha>^{tree}` recompute in both
gate and writer. One exception to "always live": when the writer's own `HC_BASE` is empty it
**re-reads `base_sha` from the state it is about to replace** (re-validating it as a raw
object id naming a live commit) rather than deleting it — otherwise the gate's recovery
would work exactly once and the next `/done` would strip the anchor. A real `HC_BASE`
always wins.

The writer also (a) **folds the triage plan as evidence** — if a valid
`done-plan/<task_key>.json` exists it is merged into the done-state as a `.plan`
field (additive, non-blocking: an absent/malformed plan simply yields no field);
and (b) when the payload carries a **non-null escalation**, writes the SHA-keyed
sidecar `escalation-accept/<verified_sha>.json` so a later session at the same HEAD
honours the acceptance (Step 3d) even without the task's done-state. The `tests`
green-refusal now also rejects `status:"not_run"` without an escalation and a green
`tests` object lacking a non-empty `command` or `output_tail`.

```json
{
  "contract_version": 1,
  "session_id": "<from hook>",
  "verified_sha": "<git rev-parse HEAD>",
  "head_tree": "<git rev-parse HEAD^{tree}>",
  "review_anchor_sha": "<sha of the review-log the writer validated>",
  "base_sha": "<the resolved changeset anchor>",
  "tree_clean": true,
  "dod": {
    "sources": ["base", "agent-instructions", "task", "session"],
    "items": ["tests green", "lint green", "app starts", "changeset-scoped independent review", "re-verified after fixes", "verification real not synthetic", "deploy target stated", "visually verify button"]
  },
  "tests": {"exit_code": 0, "command": "<the exact test command you ran>", "output_tail": "<last ~20 lines>", "newly_red": [], "pre_existing_red": []},
  "lint": {"exit_code": 0},
  "app_started": true,
  "task_checks": [{"desc": "visually verify button", "status": "passed", "how": "browser screenshot vs Figma"}],
  "review_rounds": 1,
  "escalation": null
}
```

Green `tests` is **un-forgeable**: it must record `exit_code: 0` **and** a
non-empty `command` **and** a non-empty `output_tail` (the writer and gate refuse a
bare `{"exit_code": 0}`). When tests genuinely cannot run, encode
`tests: {"status": "not_run", "reason": "…"}` — accepted **only** alongside a
non-null `escalation`. The `.plan` (audit) field is injected by the writer from
`done-plan/<task_key>.json`, not supplied in the payload.

`review_rounds` (integer, optional) is an **informational** judgment field — how many
review rounds were used (Step 6). Neither the writer nor the gate enforces it (no new
structural state); it only captures effort in done-state.

Review evidence lives beside it: `.claude/.harness/review-log/<HEAD>.json` with **zero
blocking findings** (recomputed by the gate/writer from `findings[].severity` +
`min_review_level`), written by the Step-5 review subagent.

### Step 8 — Report

One paragraph: changeset stat, what passed (test counts, app startup, review outcome,
task-check outcomes), anything escalated and why. Escalations are surfaced on the same
turn — no silent passes. It also carries an **EFFORT line**: review rounds used (of
`max_review_rounds`), fix attempts made, and wall-clock elapsed if readily available.
**Token/dollar cost is not measurable from the shell** — the reported proxies are
rounds/attempts/elapsed, not estimated cost.

---

## Task-specific verifications (`task_checks`)

Task-stated checks ("visually verify the UI") drift out of focus **exactly like
the agent's standing instructions do** — so they are captured at **task start**, not recalled at the end.

- At task start (or first `/done`), the agent extracts explicit verification
  requirements from the task and writes them into done-state `task_checks`.
- `/done` step 4 executes them alongside the built-ins, blocking equally.
- The harness thus reliably runs both the built-in checklist **and** whatever the
  task itself demanded.

---

## Harness Definition of Done (self-hosted & extensible)

The harness enforces an **explicit DoD artifact**, never a checklist hardcoded in the
skill. This has two faces.

### Runtime — the effective DoD (assembled per task)

**Base DoD** — `completion-harness/dod/base-dod.md`, installed to
`.claude/dod/base-dod.md` (portable, committed). The built-in checklist: tests green
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

> **Cross-turn: the pending-escalation one-shot (#6).** Before calling
> `AskUserQuestion` for a Category-C or `user_halt` escalation, `/done` writes
> `pending-escalation/<task_key>.json`. Otherwise the AskUserQuestion turn ends
> with a Stop the gate would block (no green done-state yet) — trapping the very
> question meant for the user. The gate consumes that marker **once** (Step 2b:
> `rm` + allow), so the question reaches the user; the next Stop finds no marker
> and re-gates normally. It is a one-shot pass, **not** a disarm.
>
> **Cross-session: the escalation-accept sidecar (#6).** An accepted escalation is
> persisted twice — in the done-state (`.escalation`, honored at Step 7) **and** as
> `escalation-accept/<HEAD>.json` keyed to the exact committed HEAD (written by
> `done-write-state.sh`, honored at Step 3d **before** the done-state checks). The
> sidecar lets a *fresh* session — which has no done-state under the task key — still
> pass at that unchanged HEAD. Both disarm only that exact sha: a new/amended commit
> moves HEAD → no match → re-block.

**`user_halt` — the user spontaneously stops the task mid-work.** Unlike A/B/C (each
check-blocked), this records the user halting before the gate is green. It routes through
the **same gate path** (non-null escalation → honored for the current HEAD only), routes to
the **user** (never a silent self-waiver), requires an actual user statement in the
transcript (like C), is echoed in step 8, and **disarms only the current changeset** — a
later commit moves HEAD → the gate blocks again → `/done` re-runs.
```json
"escalation":{"type":"user_halt","step":"<where work stopped>",
  "user_decision":"<verbatim what the user said>",
  "completed":"<what IS done/verified>","remaining":"<what is NOT>"}
```

**Honest limitation.** A bash gate can't *prove* a user answered — some field is always
written. Mitigation: A and B require captured command output (faking = fabricating an
error string, visible in transcript); C and `user_halt` require an actual user turn/statement
in the transcript (an escalation with no such exchange is a detectable lie in the record);
every escalation is echoed in the step-8 summary for the user to see.

---

## Config file: `.claude/done-config.json`

```json
{
  "contract_version": 1,
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
  "start_check_cmd": null,
  "start_timeout": 30,
  "trunk": null,
  "auto_branch": true,
  "branch_prefix": "task/",
  "untracked_policy": "baseline",
  "min_review_level": "high"
}
```

`effective = overrides ?? detected`. `overrides`, `max_fix_attempts`,
`max_review_rounds`, `baseline_snapshot`, `deploy_check_cmd`, `start_check_cmd`,
`start_timeout`, `trunk`, `auto_branch`, `branch_prefix`, `untracked_policy`,
`min_review_level` are human-owned and sticky; `detected` + `source_fingerprint`
are auto-managed. The example matches exactly what `done-detect.sh` and
`install.sh` seed. `contract_version` (const `1`) stamps the config as conforming
to `done-config.schema.json`; `done-detect.sh` validates the config against that
schema **before writing** (a broken detection never overwrites a good config) and
**auto-upgrades** a pre-v1 config in place — seeding any newly-added keys while
preserving every human-owned field. See *Hard contracts*.

`max_review_rounds` (default `2`) caps the Step-6 fix → re-review loop: round 1 is
the initial full-changeset review, round 2 is the confirming pass scoped to the
fix diff. It is a **prompt-level** cap the `/done` agent obeys — exactly like
`max_fix_attempts` — with no gate/writer counter behind it; a clean changeset
(round-1 zero blocking findings) costs exactly one review. Seeded by `done-detect.sh`
and `install.sh` and preserved thereafter.

`start_check_cmd` (default `null`) and `start_timeout` (default `30`) bound Step 3's app
startup so a server/whole-stack `start` script can never block `/done` forever. When
`start_check_cmd` is set it is run as an explicit readiness probe (exit code checked, parallel
to `deploy_check_cmd`); otherwise the effective `start` is run backgrounded, bounded by
`start_timeout` seconds, then terminated (success = came up without crashing). Both default to
the **safe/strict** behavior (no probe assumed; a bounded, never-unbounded run), are
human-owned/sticky, and are seeded by `done-detect.sh` and `install.sh` and preserved thereafter.

`untracked_policy` (default `"baseline"`, values `baseline` | `strict`) governs the
`hc_tree_status` classifier: `"baseline"` applies the baseline-relative rule to **both**
untracked and tracked-modified lines (a line blocks iff it is not in the pinned tree
baseline); `"strict"` makes **every** untracked (`??`) line a blocker regardless of the
baseline, while tracked-modified lines stay baseline-relative. `untracked_policy: "baseline"`
is seeded by `done-detect.sh` and `install.sh` and preserved thereafter.

`min_review_level` (default `"high"`, values `low` | `medium` | `high` | `critical`) is the
**"good enough" threshold** for code-review findings. Every review finding is tagged
`severity`; the gate and writer compute the BLOCKING count structurally via
`hc_review_blocking` (in `harness-common.sh`): a finding blocks iff
`rank(severity) >= rank(min_review_level)` (ranks `low=0 medium=1 high=2 critical=3`). So the
default `high` blocks only high+critical findings — medium/low are **advisory** (recorded,
never gating), which is what stops nits/style findings causing endless fix→re-review churn.
`min_review_level: "low"` is strictest (everything blocks). An unknown/missing severity ranks
as blocking (safe direction); a missing/malformed log fails toward block; old-style logs with
no `findings[]` fall back to the `open_findings` integer. It is human-owned/sticky, seeded by
`done-detect.sh` and `install.sh` and preserved thereafter.

---

## Deployment environment

Cannot be fully automated generically.
- `deploy_check_cmd` set → run it, check exit code.
- Absent → `/done` forces the agent to **state** the deploy target and whether it was
  exercised. Makes the gap visible instead of claiming false coverage.

App startup (Step 3) has the parallel `start_check_cmd` / `start_timeout` pair: a
long-running server never blocks the gate — either a lightweight `start_check_cmd` readiness
probe is run, or the `start` script is run bounded by `start_timeout` and then terminated.
Same principle: automate what can be, force an explicit statement of reduced coverage
otherwise, never claim false coverage.

---

## Files — portable bundle (trial: per-project, not global)

The bundle lives under `completion-harness/` and is copied into a target project's
`.claude/` by `install.sh`. All hook paths use `$CLAUDE_PROJECT_DIR` — no `~` or machine
paths. After the trial proves out, the same bundle can be promoted to `~/.claude/` for
global use.

| File | Purpose |
|---|---|
| `completion-harness/scripts/done-gate.sh` | Stop hook gate |
| `completion-harness/scripts/harness-common.sh` | Shared library: `hc_resolve` (identity/base) + `hc_tree_status`/`hc_tree_remediation` (baseline-relative tree classifier) + `hc_validate` (jq-only JSON-Schema-subset validator; sets `HC_CONTRACTS_DIR`) |
| `completion-harness/scripts/harness-resolve.sh` | `/done` Step 1: executable resolver wrapper — prints a self-validated JSON object (resolver-output contract), `jq`-parsed by the skill |
| `completion-harness/contracts/*.json` | Hard-contract schema store: 6 JSON-Schemas (done-state, review-log, done-config, resolver-output, base-dod, done-plan) + `base-dod.json` (seed DoD) + `shell-abi.json` (declared, test-enforced shell ABI). Copied to `.claude/contracts/` |
| `completion-harness/scripts/baseline-snapshot.sh` | SessionStart: baseline SHA + tree baseline + background test snapshot (self-seeds config, inert-marker + systemMessage when no test cmd) |
| `completion-harness/scripts/auto-branch.sh` | PreToolUse(Write\|Edit): auto-branch off trunk + pin task tree-base from clean pre-edit snapshot |
| `completion-harness/scripts/done-preflight.sh` | `/done` Step 0 preflight: prove the gate is winnable (calls `hc_resolve`+`hc_tree_status`), non-zero on HARD problems; never seeds a baseline |
| `completion-harness/scripts/done-detect.sh` | `/done` config: probe + fingerprint + write done-config.json (seeds `untracked_policy`) |
| `completion-harness/scripts/done-triage.sh` | `/done` triage: compute applicable steps, write self-validated audit `done-plan/<task_key>.json`, print applicable steps; fail-safe → run all |
| `completion-harness/scripts/done-write-state.sh` | `/done` Step 7: inject live git facts + write done-state (refuses on introduced blockers, `not_run`-without-escalation, evidence-less green); folds `.plan`; writes `escalation-accept` sidecar |
| `completion-harness/skills/done/SKILL.md` | `/done` skill — thin entry point (runs triage, routes to `dod-protocol.md`) |
| `completion-harness/skills/done/dod-protocol.md` | `/done` full protocol reference (all step sections + escalation rules) |
| `completion-harness/dod/base-dod.md` | Base DoD (assembled into the effective DoD) |
| `completion-harness/DOD.md` | The harness project's own DoD (meta) |
| `completion-harness/install.sh` | Idempotent installer → target `.claude/` + `settings.local.json` |
| `completion-harness/README.md` | Install / use / uninstall / portability |

**Installed into a target project** (by `install.sh`):
`.claude/scripts/`, `.claude/skills/done/`, `.claude/dod/base-dod.md`,
`.claude/contracts/` (the schema store `hc_validate` reads),
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
| 4. No code review | Step 5 (mandatory before done-state) |
| 5. Review scope = whole repo | Step 1 changeset scope |
| 6. Findings not acted on | Step 6 loop |
| 7. No re-verify after fix | Step 6 → step 2 loop |
| 8. Tests not run | Step 2 (mandatory, before/after checkpoint) |
| 9. New coverage not checked | Step 5 review |
| 10. App startup | Step 3 |
| (new) Task-stated checks forgotten | `task_checks` captured at start, step 4 |

---

## Versioning

Maintainer tooling, not part of the shipped bundle. The version single source of
truth is `completion-harness/.claude-plugin/plugin.json` (`version`). It is
**derived from the conventional commits** in a pushed range and enforced on push.

- **0.x convention** (while major == 0): breaking → minor, `feat`/`fix`/`perf` →
  patch, everything else → no bump. From `1.0.0`: standard semver.
- The `pre-push` hook runs `check-version.sh <base> <head>`; if under-bumped it
  runs `bump-version.sh` to write + commit `chore(release): bump …` and aborts,
  so the release commit lands on the next push. Bypassable with `--no-verify`.
- Pure version math lives in the sourceable, unit-tested `version-lib.sh`
  (`test-version.sh`, run by `run-tests.sh`); `bump-version.sh --dry-run`
  previews without touching anything.

---

## Non-goals

- No enforcement on conversational turns (SHA guard).
- No enforcement in non-git repos (no changeset baseline).
- Does not guarantee the deploy environment was exercised — guarantees the agent must
  *state* whether it was.
- Does not arbitrate two agents committing to one tree — use worktrees.
