# Migration plan — `completion-harness` (harlo) → `done-gate` (coding-agents)

**Decisions (confirmed with user):**

| Question | Answer |
|---|---|
| Plugin name | `done-gate` — skill invokes as `/done-gate:done` |
| Version | reset to `0.1.0` |
| Docs | port to `plugins/done-gate/docs/` |
| harlo repo | copy only; leave harlo untouched and working |

Source: `/Users/localadmin/Work/mine/harlo/completion-harness/`
Target: `/Users/localadmin/Work/job/git/coding-agents/plugins/done-gate/`

---

## Audit findings (done — these size the plan)

1. **Path resolution is already plugin-root-relative.** All 21 test suites resolve
   the bundle via `$(dirname "$0")/../scripts` and `../contracts`. All 9 runtime
   scripts source siblings via `$(dirname "$0")` / `BASH_SOURCE`. Nesting one level
   deeper (`plugins/done-gate/` vs `harlo/completion-harness/`) changes nothing.
2. **Exactly one line baked the plugin name into path resolution** —
   `tests/test-install.sh:22`. That file is now dropped (Step 3b), so **zero** lines
   in the ported bundle depend on the plugin's name for path resolution.
3. Every other `completion-harness` occurrence inside the bundle (7 test files,
   3 scripts) is **comment text only**.
4. **State dir renames too: `.claude/.harness` → `.claude/.done-gate`** (user call —
   an engineer finding `.harness` in their `.claude/` has no way to trace it back to
   a plugin). 245 occurrences across 27 files, but only ~12 are the actual path
   definition (`HARNESS_DIR=` in 4 scripts, bare literals in `done-triage.sh`,
   `done-write-state.sh`, `harness-common.sh` defaults).
   The rest are test fixture literals and prose. Single global `sed` on the string
   `.claude/.harness`; the 21 suites are the verification.
   - **`HARNESS_DIR` (the variable) does NOT rename.** It is pinned by
     `contracts/shell-abi.json` and asserted by `test-abi.sh`. Traceability is about
     what an engineer sees on disk, not an internal shell var.
   - **No migration shim.** `done-gate` ships at 0.1.0 with no install base. Any
     stale `.claude/.harness/` left by a `completion-harness` install is regenerated-
     on-SessionStart session state — safe to delete by hand. Note it in the README;
     don't write code for it.
   - `.claude/done-config.json` renames to `.claude/done-gate-config.json` on the
     same rationale — see Step 3c.
5. **`package.json` needs no change** — target's test script globs
   `plugins/*/tests/test-*.sh`, which picks `done-gate` up automatically.
6. **`done-gate` would be the first plugin in coding-agents that ships `hooks/`.**
   No existing plugin has a `hooks/` dir. Its Stop hook blocks task completion —
   highest-blast-radius artifact in that repo. Dev-marketplace-only registration is
   non-negotiable until the user explicitly publishes.
7. **No `/plugin-dev:create-plugin` command exists** in the target checkout
   (`.claude/commands/` has only `publish-plugin/`). Scaffold by hand, register
   dev-only — deviating from target CLAUDE.md's "use the guided workflow" line
   because the workflow isn't present.
8. **Name-collision check clear.** Target has an *uncommitted* draft
   `docs/features/feature-flow-harness/` — a different thing (autonomous pipeline
   runner CLI). `done-gate` does not collide with it. Flag to user, no action.
9. **Target working tree is dirty** (uncommitted `.specs/`, `sdlc-*.plan.md`,
   modified `plugins/dev-toolkit/plugin.json`). Branch off before touching it.

---

## Steps

### 1. Target repo — work on `main` (user call)
- [ ] Verified 2026-07-30: `coding-agents` is on `main`, clean, in sync with
      `origin/main`. No feature branch; commit directly to `main`.
- [ ] `done-gate`'s own `PreToolUse: Write|Edit` auto-branch hook is NOT active in
      that repo during authoring (plugin not installed yet), so nothing will move
      you off `main` mid-edit. Step 5's live install is where that changes.

### 2. Copy the bundle
- [ ] `cp -R harlo/completion-harness/ coding-agents/plugins/done-gate/`
- [ ] `cp -R harlo/docs/ coding-agents/plugins/done-gate/docs/`
- [ ] Copies verbatim: `scripts/` (9), `tests/` (15 + `fixtures/`), `contracts/` (8),
      `skills/done/` (SKILL.md + dod-protocol.md), `dod/base-dod.md`, `hooks/hooks.json`,
      `README.md`, `DOD.md`, `.claude-plugin/plugin.json`
- [ ] **Do NOT copy `install.sh` or `tests/test-install.sh`** — see Step 3b.
- [ ] Preserve executable bits (`cp -R` does). `test-install.sh` used to assert
      these explicitly and is being dropped — check `ls -l plugins/done-gate/scripts/`
      by hand once. Only `harness-common.sh` is non-executable (it is sourced).

### 3. Rename + version reset
- [ ] `plugin.json`: `name: done-gate`, `version: 0.1.0`, `description` unchanged,
      `author: ClimatePartner` — matches every other plugin in that org marketplace.
- [ ] **State dir rename** — global `sed 's#\.claude/\.harness#.claude/.done-gate#g'`
      across `scripts/ tests/ skills/ dod/ README.md DOD.md docs/`.
      Then sweep bare `.harness/` mentions in prose that the anchored pattern misses.
      Leave `HARNESS_DIR`, `harness-common.sh`, `harness-resolve.sh`, `hc_*` alone —
      internal names, pinned by `contracts/shell-abi.json`.
- [ ] Sweep comment-only mentions: `completion-harness` → `done-gate` across
      tests/scripts/README/docs (`grep -rl` then `sed -i ''`).
- [ ] `README.md` + `docs/`: install line becomes
      `/plugin install done-gate@cp-marketplace-dev --scope local`
      (was `/plugin install completion-harness@harlo`).
- [ ] `baseline-snapshot.sh:260` — the injected context string `[completion-harness]`
      is **agent-visible output**, not a comment. Rename to `[done-gate]`.

### 3b. Drop `install.sh` — and replace the one thing it did that matters

`install.sh` (180 lines) + `tests/test-install.sh` (160 lines) exist as a
**non-plugin fallback**: mirror the bundle into a project's `.claude/`,
sed-rewrite `${CLAUDE_PLUGIN_ROOT}` → `$CLAUDE_PROJECT_DIR/.claude`, merge hooks
into `settings.local.json`. In a plugin marketplace repo that path is dead. Drop both.

Audited what else it did, and whether the plugin path already covers it:

| install.sh did | Covered without it? |
|---|---|
| Merge 3 hooks into `settings.local.json` | Yes — `hooks/hooks.json` is the plugin's native mechanism |
| sed-rewrite `${CLAUDE_PLUGIN_ROOT}` in SKILL.md / dod refs | Moot — the token resolves natively under a plugin |
| Seed the config json | Yes — `done-detect.sh:192-222` writes it if absent, and SessionStart runs it |
| `mkdir -p` the state dirs | Yes — every writer already does `mkdir -p "$(dirname …)"` |
| **Add `.claude/.harness/` to the project `.gitignore`** | **NO — this is the gap** |

**Why the gitignore gap is not cosmetic.** The gate reads
`git status --porcelain` (`done-gate.sh:109,164`, `done-write-state.sh:114`) and
classifies every line against a pinned baseline. `hc_tree_status` has **no
exclusion filter for the harness's own state dir** — it relies entirely on the
dir being gitignored. State files are written *during* the session (done-state,
review-log, done-plan), i.e. after the baseline snapshot, so without the ignore
the harness sees its own writes as unexplained dirt at Stop time.
Confirmed: harlo's own `.gitignore:8` carries `.claude/.harness/` for exactly this.

**Replacement — self-ignoring state dir (1 line, verified):**

`baseline-snapshot.sh:40` already creates the state dir unconditionally:

```sh
mkdir -p "$BASELINE_DIR" "$HARNESS_DIR/done-state" "$HARNESS_DIR/pending-escalation" 2>/dev/null
printf '*\n' > "$HARNESS_DIR/.gitignore" 2>/dev/null          # <- add this
```

A nested `.gitignore` containing `*` ignores the directory's whole contents
*including itself*, so the dir never appears in porcelain. Verified empirically in
a throwaway repo: `git status --porcelain` -> 0 lines.

Strictly better than what install.sh did:
- Touches **no consumer file** — install.sh edited the project's `.gitignore`.
- Self-healing — works on a fresh clone, a new worktree, and for anyone who
  installs the plugin without ever running an installer.
- No install step to forget.

- [ ] Placement: `baseline-snapshot.sh:40`, immediately after the existing `mkdir -p`.
      **Not** in `hc_resolve()` — that is a pure resolver (computes branch, task key,
      baseline paths) with no disk writes; adding one there would put a side effect in
      a function all 8 scripts call, and cost a guard `stat` on every invocation.
      Line 40 is unconditional and runs *before* the no-git early exit at `:83` and
      before `harness-common.sh` is sourced at `:98`, so it always fires.
- [ ] Ordering is safe: `SessionStart` precedes `PreToolUse` within a session, so
      `auto-branch.sh` can never write state ahead of this line.
- [ ] Known edge, accepted: a project that installs the plugin *mid-session* has no
      `.gitignore` in its state dir until the next SessionStart. Self-heals; no code.
- [ ] This is **new behavior, not a port.** Its own commit, its own verification.
- [ ] Verify with `test-tree-status.sh` (the suite that would catch a regression)
      plus one new assertion: state written mid-session leaves porcelain clean in a
      repo whose `.gitignore` says nothing about the harness.
- [ ] `test-abi.sh` / `contracts/shell-abi.json` checked — **no reference to
      `install.sh`**. Deleting it breaks no other suite. 20 suites port, not 21.

### 3c. Rename `done-config.json` -> `done-gate-config.json` (user call)

Same rationale as the state dir: the one file an engineer opens by hand should name
its owner. 150 refs across 26 files; ~12 are the real path definition
(`CONFIG_FILE=` in 5 scripts, inline `jq` reads in `done-gate.sh:329`,
`done-write-state.sh:161,194`, `harness-common.sh:34,363,503,1588`).

- [ ] Global `sed 's#done-config#done-gate-config#g'` across
      `scripts/ tests/ contracts/ skills/ dod/ README.md DOD.md docs/`.
- [ ] `git mv contracts/done-config.schema.json contracts/done-gate-config.schema.json`
      — the same sed already fixes every reference to it. Leaving the schema named
      `done-config` while it validates `done-gate-config.json` is the same
      traceability defect one level in.
- [ ] **Do not miss `harness-common.sh:382`** — a bare `'.claude/done-config.json'`
      string in the tree-status whitelist (the config is allowed to change *during*
      `/done`). It is a literal, not a variable; a rename that skips it makes the
      gate flag its own config write as unexplained dirt. The global sed covers it —
      this line is the reason to sed rather than hand-edit the `CONFIG_FILE=` sites.
- [ ] No migration shim — 0.1.0, no install base. A project carrying an old
      `done-config.json` gets a fresh one seeded by `done-detect.sh` and can delete
      the orphan. README note.
- [ ] Verify: `grep -rn 'done-config' plugins/done-gate/` returns nothing.

### 4. Register — dev marketplace ONLY
- [ ] Add to `.dev-marketplace/.claude-plugin/marketplace.json`:
      `{"name":"done-gate","source":"./plugins/done-gate","description":"..."}`
- [ ] **Do NOT touch `.claude-plugin/marketplace.json`.** Production publish is a
      separate, user-initiated `/publish-plugin` run (finding #6).

### 5. Verify
- [ ] `bash plugins/done-gate/tests/test-<each>.sh` from **repo root** — target's
      runner does not `cd` first, harlo's `run-tests.sh` does. Confirms cwd-independence
      empirically rather than by inspection.
- [ ] `pnpm run test` at target root — all 20 done-gate suites + every pre-existing
      plugin suite green.
- [ ] `grep -rn 'completion-harness\|harlo' plugins/done-gate/` returns nothing.
- [ ] `grep -rn '\.claude/\.harness' plugins/done-gate/` returns nothing.
      (`HARNESS_DIR` / `harness-common.sh` hits are expected and correct.)
- [ ] Live install: `/plugin install done-gate@cp-marketplace-dev --scope local`,
      reload, confirm `/done-gate:done` resolves and the Stop hook fires.

  > **Only step with side effects outside `plugins/done-gate/`.** A live install
  > arms three hooks *in the target repo*: `Stop` (blocks completion),
  > `SessionStart` (`baseline-snapshot.sh` writes `.claude/.done-gate/` and seeds
  > `.claude/done-gate-config.json`), `PreToolUse: Write|Edit` (`auto-branch.sh` can
  > create a branch). Afterwards: (a) `rm -rf .claude/.done-gate/`, (b) remove the
  > seeded `done-gate-config.json` unless the repo genuinely wants the gate on itself.
  > Target `.gitignore` needs **no** entry — Step 3b's self-ignoring dir handles it,
  > and that is itself part of what this step verifies.
  > Because Step 1 puts us on `main`, this cleanup is mandatory, not optional —
  > there is no branch to throw away.

- [ ] Fresh-context code review of the diff (independent agent).

### 6. Commit (conventional, one bundle per commit)
- [ ] `feat(done-gate): add Definition-of-Done completion gate plugin`
- [ ] `chore(marketplace): register done-gate in dev marketplace`

---

## Explicitly NOT migrated (scoped out, not forgotten)

| Artifact | Why |
|---|---|
| `bump-version.sh`, `check-version.sh`, `version-lib.sh` | Target owns versioning via `/publish-plugin`; target CLAUDE.md says *do not manually bump*. |
| `test-version.sh` | Tests harlo's version tooling — its subject isn't porting, so the coverage isn't lost, it's inapplicable. |
| `install.sh` (180 lines) + `tests/test-install.sh` (160 lines) | Non-plugin fallback installer. Dead path in a plugin marketplace. See Step 3b for the audit and the 3-line replacement for the one thing it did that mattered. **20 of 22 suites port**; `test-version.sh` and `test-install.sh` drop because their subjects drop. |
| `.githooks/pre-push` | Target already runs `pnpm test` pre-push via husky. |
| `run-tests.sh` | Target's `package.json` glob replaces it. |
| `.claude/done-config.json`, `.claude/.harness/` | harlo's own dogfooding state — must not be copied. |
| The `.harness` → `.done-gate` rename **in harlo** | harlo's plugin is still named `completion-harness`; `.done-gate` there would recreate the exact traceability problem in reverse. The two copies diverge on this one string, by design. |
| harlo root `CLAUDE.md`, `README.md` | Repo-level, not plugin-level. Plugin `README.md` ports. |

## Consequences of dropping install.sh

- Target CLAUDE.md's `do_install`/`do_uninstall` mirror-pair invariant no longer
  applies — no installer, no invariant. The README caveat this plan previously
  carried is deleted, not deferred.
- `done-gate` matches `feature-flow`'s shape (scripts + tests, no installer), which
  is the majority pattern in that repo — only `dev-toolkit` ships an install.sh.
- The two lines that used to touch a consumer project (`.gitignore` edit, state
  `mkdir`) are gone. The plugin now writes nothing outside `.claude/.done-gate/`
  and `.claude/done-gate-config.json`.
- Plugin `README.md` loses its "Install without the plugin system" section.

---

## Review

_(fill in after execution)_
