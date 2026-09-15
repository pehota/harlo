# Handoff — claim → verify gating for the `dod` plugin

Written 2026-09-15. Repo `harlo`, branch `main`, clean at `9a22e74`.

## Read this first: repo state

- `main` is **clean**. Nothing from the previous attempt is committed.
- The previous attempt ("option B": classify-and-demand Stop gate) is **stashed**:
  `stash@{0}` — "dod option B: classify-and-demand gate + 10 review fixes".
  Backup patch also at `<scratchpad>/dod-option-b.patch` (851 lines).
- **Do not pop that stash to build on it.** It carries four confirmed blocking
  defects and a deeper design problem (below). Read it for context if useful,
  but the new work starts from `main`.
- The task-DoD contract from that session was removed by the user, so the Stop
  gate is currently silent.

## The goal

The agent declares it has finished; the harness then verifies whether that is
true. Replace "guess when the task is done" with "react to an explicit claim".

```
agent finishes work
      │
      ▼
runs complete_task ──► records a CLAIM keyed to the changeset state
      │
      ▼
dod verifies whether the claim actually holds
      │
no claim arrives ──► soft reminder, once per changeset state
```

## Why the previous approach failed (do not repeat these)

### 1. The Stop hook fires at turn end, not task end
`Stop` fires every time the agent yields the turn. `stop_reason` is `"end_turn"`
both when the agent is finished and when it is asking the user a question. There
is **no hook that fires when the agent considers the task complete** — confirmed
against current docs (34 hook events; `TaskCompleted` exists but fires on the
`TaskCreate`/`TaskComplete` tool lifecycle and is **observe-only**, it cannot
block).

Consequence in the previous attempt: the gate blocked at the end of *every*
turn for ~15 consecutive turns while work was legitimately in progress.

### 2. "No progress for N turns" is not a usable completion signal
The user's own rules (`MY_RULES.md`) say the main agent orchestrates and does
not implement. So the orchestrating agent legitimately writes **nothing** for
many consecutive turns while subagents work. No value of N is safe.

### 3. Prose detection was considered and rejected
`Stop`'s payload does include `last_assistant_message`, so the agent's claim is
available without parsing the transcript. It was still rejected: brittle,
phrasing-dependent, NLP in bash. An explicit `complete_task` invocation is
deterministic and strictly better. **Do not implement prose matching.**

### 4. THE BIG ONE — the gate is blind to committed work
`hc__resolve_session_base` (`dod/scripts/harness-common.sh:754`) advances
`HC_BASE` past every commit that is **not in the commit ledger**, treating
unledgered commits as foreign (someone else's work).

The ledger is written by `commit-ledger.sh`, a **`completion-harness`** hook
(`PreToolUse`/`PostToolUse` on Bash). The `dod` plugin's `hooks.json` registers
only `SessionStart` and `Stop`, and does not ship `commit-ledger.sh` at all.
`completion-harness@harlo` is currently **disabled** in `~/.claude/settings.json`.

Result: no ledger is ever written → every commit reads as foreign → `HC_BASE`
walks forward to HEAD → the committed range is always empty → **the gate can
only ever see uncommitted working-tree changes.**

Proven by execution, same fixture repo, only the ledger file differs:

```
committed product work, clean tree, no ledger  ->  ALLOW
same repo, commits now IN the ledger           ->  BLOCK
```

This matters because the user works on `main` and commits in logical bundles.
Committing makes the tree clean and the gate goes quiet.

**Any claim→verify design must decide what it measures.** Options:
- port the `commit-ledger.sh` hooks into `dod` (correct, largest);
- when no ledger infrastructure exists at all, refuse to advance the base —
  fail closed, matching `hc_tree_status`'s "missing baseline → everything
  blocks" doctrine (~3 lines; over-blocks on a human's mid-session commit);
- key the claim to something that does not depend on the resolver at all
  (see "fingerprint" below) — **probably the right answer here**, since the
  claim already tells you which state the agent means.

## Design to implement

### The asymmetry rule — the single most important constraint
**An agent-authored signal may only ever make the gate stricter, never looser.**

`dod-collect` violated this: not writing the contract was both the path of least
resistance *and* the path to zero enforcement. Evidence of the consequence — in
`~/Work/job/git/footprint-calculator`, `task-dod/` held **0 files** while
`done-state/` held 17, across 12 days. The collection skill never once fired.

Applied here:

| Signal | Gate behaviour |
|---|---|
| no unverified product changes | silent |
| unverified product changes, no claim | **soft reminder, once per changeset state** |
| `complete_task` claim recorded for the current state | **hard block until verified** |

Skipping `complete_task` must buy the agent nothing — the per-state reminder
still fires. Running it must not clear anything.

### `complete_task`
- Records a claim. **It must not clear the gate.** Clearance stays exclusively
  with a `dod-verify` result for the current state. A script that both claims
  and clears is a bypass with a friendly name.
- Keys the claim to a **changeset fingerprint**, so any later edit invalidates
  the claim automatically and the script needs no arguments.
- Keep it dumb: record the claim, print "now run dod-verify", exit.
- One job. It is not a verifier and must not become one — the judgement parts
  (independent review, task-specific checks) belong to the `dod-verify` skill,
  which already exists at `dod/skills/dod-verify/`.

### The fingerprint — get this right
Must be **content-sensitive**. `git status --porcelain` emits ` M path`; editing
the same already-modified file again produces byte-identical output, so a
porcelain-based fingerprint reports "no change" across real progress. This bug
was made and caught during the previous session.

Use `HEAD` sha + a hash of `git diff HEAD` + hashed contents of untracked files
(`git ls-files -o --exclude-standard`), or an equivalent that observes content.

The fingerprint's job is **deduplication, not completion detection** — it only
answers "have I already said this?", which is always answerable. Do not push it
into answering "is the agent done?", which is not.

### Ledger for completions
`TaskCompleted` cannot gate, but it can record. Writing `task_id`,
`task_description`, `task_state` to `.claude/.harness/task-log/` gives the
plugin the audit trail it currently lacks — the user's original complaint at the
start of the previous session was that they could not see what the plugin was
doing, because it wrote nothing.

## Hard constraints (inherited, non-negotiable)

Match `dod/scripts/dod-gate.sh`'s existing discipline exactly:
- **FAIL-SAFE = ALLOW.** Any unexpected condition releases the Stop. Never trap
  the user.
- Block contract: print `{"decision":"block","reason":"..."}` on stdout, exit 0.
  **Never exit 2.** Allow = exit 0 with **empty** stdout.
- No `set -e`. No catch-all `EXIT` trap. Every `git` and `jq` call guarded.
- No `jq` available → allow.
- Keep the category-scoped recursion brake in `block()` working; a *different*
  category must still block under `stop_hook_active`.
- Do not modify `hc_tree_status` in `harness-common.sh` — `completion-harness`
  depends on it.
- Never advertise `dod/scripts/dod-stub-done.sh` in any agent-facing block text.
  It writes a trivially-passing result with no checks run; naming it as the
  remedy instructs the agent to fake verification. Point at the `dod-verify`
  skill. (Keep the stub for tests.)

## Landmines found the hard way — check each before writing code

1. **Porcelain is a path/status list, not content.** See fingerprint above.
2. **Git collapses a wholly-untracked directory** to `?? .claude/`. That path is
   not matched by a `.claude/.harness/*` exclusion. `dod-session-start.sh`
   *creates* `.claude/` by writing `current-session`, so in any repo without a
   `.claude/.harness/` gitignore entry the plugin manufactures its own trap.
   If you expand collapsed dirs with a pathspec, note that **porcelain paths are
   repo-root-relative while a git pathspec is CWD-relative** — with
   `CLAUDE_PROJECT_DIR` set to a subdirectory of the repo, `git status
   --porcelain -uall -- "$path"` silently emits nothing. Use `:/` prefixed
   pathspecs.
3. **`artifact_paths` is reachable from the session config layer**
   (`.claude/.harness/session-config.json` — harness-own, never blocks,
   gitignored). `{"artifact_paths":["*"]}` disables path classification
   entirely. `harness-common.sh` already states the governing rule for exactly
   this hazard at `hc__detect_trunk`: some knobs carry too much authority for an
   ephemeral, agent-written file. If your design reads config that can disarm
   the gate, pin it outside the session layer.
4. **`git rev-parse -q --verify <x>` succeeds for any resolvable refname**, not
   just shas. A file named `HEAD.json` or `main.json` in a state directory
   became a full gate bypass in the previous attempt. Validate shape (40 hex)
   before resolving.
5. **`task-dod/archive/` is not excluded from `baseline-snapshot.sh`'s 14-day
   reap** (unlike `task-base/`, `tree-base/`, `review-log/`). Anything that
   depends on an archived anchor surviving will break on a delay.
6. **`git commit --amend` is routine and detaches archived anchors.** A design
   that measures from a previously-archived sha must handle the anchor being
   resolvable-but-no-longer-an-ancestor without falling open.

## Definition of Done

1. Every stated requirement met, behaviour and appearance.
2. Verified by **exercising the real flow** — run the hook against live fixture
   repos and observe stdout and exit status. Not by reading the diff. The
   previous session's test suite passed 65/65 while four bypasses were live,
   because every fixture used the repo toplevel and a single task key. **Make
   fixtures that are untidy on purpose:** subdirectory project roots, wholly
   untracked `.claude/`, planted state files, amended commits, multiple task
   keys.
3. Reviewed by a **fresh agent with clean context** (`dod:dod-reviewer`), which
   runs `git diff` itself rather than trusting a summary. Fix only findings that
   block correctness. Batch everything else to the user with a fix/skip
   recommendation and a reason — never silently fix, never silently drop.
4. `./run-tests.sh` fully green. `shellcheck -S error -x` clean on changed shell
   files.
5. Bump the `dod` plugin version. Note the repo's 0.x convention: MINOR only
   moves on a `breaking` conventional-commit level, so a behaviour change needs
   a `!` or a `BREAKING CHANGE:` footer for the pre-push enforcer to agree.
6. **ADR-0003** (0001 and 0002 are taken — 0002 is remove-auto-branching)
   recording the gating-model change: claim-triggered verification, fingerprint
   deduplication, and the asymmetry rule. Amend ADR-0001 with a pointer.
7. Re-sync any doc the code contradicts — `dod/README.md`, the gate's header
   comment, `docs/architecture.md`. Per `CLAUDE.md`: trust the code, fix the doc.

## Useful file map

| Path | What |
|---|---|
| `dod/hooks/hooks.json` | hook registration — `SessionStart` + `Stop` only |
| `dod/scripts/dod-gate.sh` | the Stop blocker; block contract and recursion brake |
| `dod/scripts/dod-session-start.sh` | writes `current-session`, seeds baselines; emits nothing to the model |
| `dod/scripts/lib-classify.sh` | product-vs-artifact path classifier; fails closed |
| `dod/scripts/harness-common.sh` | `hc_resolve`, `hc_tree_status`, `hc__resolve_session_base`, `hc_cfg` |
| `dod/scripts/dod-write.sh` | append-only contract writer |
| `dod/scripts/dod-verify-*.sh` | detect / preflight / triage / write-result |
| `dod/skills/dod-verify/` | the real verification protocol |
| `dod/docs/base-dod.md` | the baseline checklist |
| `dod/tests/test-dod.sh` | main suite; `test-helpers.sh` has the fixture builders |
| `completion-harness/scripts/commit-ledger.sh` | the ledger writer `dod` does **not** ship |

## Open questions for the user

1. What does the gate measure — port the commit ledger, fail closed without it,
   or key everything to the claim's fingerprint and sidestep the resolver?
2. Does a claim expire? A claim keyed to a fingerprint dies on the next edit,
   which is probably right, but confirm.
3. Should `complete_task` be a script, a skill, or both? A script is observable
   from a `PostToolUse` Bash hook; a skill is easier for the agent to find.
