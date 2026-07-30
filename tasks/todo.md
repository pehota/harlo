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

1. **Path resolution is already plugin-root-relative.** All 16 test suites resolve
   the bundle via `$(dirname "$0")/../scripts` and `../contracts`. All 9 runtime
   scripts source siblings via `$(dirname "$0")` / `BASH_SOURCE`. Nesting one level
   deeper (`plugins/done-gate/` vs `harlo/completion-harness/`) changes nothing.
2. **Exactly one line bakes the plugin name into path resolution:**
   `tests/test-install.sh:22` — `$(dirname "$0")/../..` + `/completion-harness/install.sh`.
   Must become `$(dirname "$0")/..` + `/install.sh` (name-independent afterwards).
3. Every other `completion-harness` occurrence inside the bundle (7 test files,
   3 scripts) is **comment text only**.
4. **Runtime state is already name-agnostic** — `HARNESS_DIR=$PROJECT_DIR/.claude/.harness`,
   config `.claude/done-config.json`. No state-key rename needed, and no migration
   burden for anyone already running the harness. Verified the adjacent risk:
   `install.sh:59,64` rewrites on the **literal token** `${CLAUDE_PLUGIN_ROOT}`
   (single-quoted sed, `s#${CLAUDE_PLUGIN_ROOT}#$CLAUDE_PROJECT_DIR/.claude#g`) —
   no path fragment containing the plugin name, so the rename cannot break the
   fallback installer.
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

### 1. Branch in target repo
- [ ] `cd coding-agents`, confirm `main` up to date, `git switch -c feat/done-gate-plugin`
- [ ] Do not stage the pre-existing dirty files.

### 2. Copy the bundle
- [ ] `cp -R harlo/completion-harness/ coding-agents/plugins/done-gate/`
- [ ] `cp -R harlo/docs/ coding-agents/plugins/done-gate/docs/`
- [ ] Copies verbatim: `scripts/` (9), `tests/` (16 + `fixtures/`), `contracts/` (8),
      `skills/done/` (SKILL.md + dod-protocol.md), `dod/base-dod.md`, `hooks/hooks.json`,
      `install.sh`, `README.md`, `DOD.md`, `.claude-plugin/plugin.json`
- [ ] Preserve executable bits (`cp -R` does; verify with `test-install.sh`, which
      asserts them explicitly).

### 3. Rename + version reset
- [ ] `plugin.json`: `name: done-gate`, `version: 0.1.0`, `description` unchanged,
      `author: ClimatePartner` — matches every other plugin in that org marketplace.
- [ ] **Fix `tests/test-install.sh:22`** — the one real path edit (finding #2).
- [ ] Sweep comment-only mentions: `completion-harness` → `done-gate` across
      tests/scripts/README/docs (`grep -rl` then `sed -i ''`).
- [ ] `README.md` + `docs/`: install line becomes
      `/plugin install done-gate@cp-marketplace-dev --scope local`
      (was `/plugin install completion-harness@harlo`).
- [ ] `baseline-snapshot.sh:260` — the injected context string `[completion-harness]`
      is **agent-visible output**, not a comment. Rename to `[done-gate]`.

### 4. Register — dev marketplace ONLY
- [ ] Add to `.dev-marketplace/.claude-plugin/marketplace.json`:
      `{"name":"done-gate","source":"./plugins/done-gate","description":"..."}`
- [ ] **Do NOT touch `.claude-plugin/marketplace.json`.** Production publish is a
      separate, user-initiated `/publish-plugin` run (finding #6).

### 5. Verify
- [ ] `bash plugins/done-gate/tests/test-<each>.sh` from **repo root** — target's
      runner does not `cd` first, harlo's `run-tests.sh` does. Confirms cwd-independence
      empirically rather than by inspection.
- [ ] `pnpm run test` at target root — all 16 done-gate suites + every pre-existing
      plugin suite green.
- [ ] `grep -rn 'completion-harness\|harlo' plugins/done-gate/` returns nothing.
- [ ] Live install: `/plugin install done-gate@cp-marketplace-dev --scope local`,
      reload, confirm `/done-gate:done` resolves and the Stop hook fires.

  > **Only step with side effects outside `plugins/done-gate/`.** A live install
  > arms three hooks *in the target repo*: `Stop` (blocks completion),
  > `SessionStart` (`baseline-snapshot.sh` writes `.claude/.harness/` and seeds
  > `.claude/done-config.json`), `PreToolUse: Write|Edit` (`auto-branch.sh` can
  > create a branch). The target tree is already dirty with unrelated work.
  > Therefore: run this on the feature branch only, and afterwards
  > (a) `rm -rf .claude/.harness/`, (b) remove the seeded `done-config.json`
  > unless the repo genuinely wants the gate on itself, (c) decide whether
  > `.claude/.harness/` belongs in target `.gitignore` — it does if the repo
  > dogfoods done-gate, otherwise leave `.gitignore` alone.

- [ ] Fresh-context code review of the diff (independent agent).

### 6. Commit (conventional, one bundle per commit)
- [ ] `feat(done-gate): add Definition-of-Done completion gate plugin`
- [ ] `chore(marketplace): register done-gate in dev marketplace`

---

## Explicitly NOT migrated (scoped out, not forgotten)

| Artifact | Why |
|---|---|
| `bump-version.sh`, `check-version.sh`, `version-lib.sh` | Target owns versioning via `/publish-plugin`; target CLAUDE.md says *do not manually bump*. |
| `test-version.sh` | Tests harlo's version tooling — its subject isn't porting, so the coverage isn't lost, it's inapplicable. **The 16 harness suites all port.** |
| `.githooks/pre-push` | Target already runs `pnpm test` pre-push via husky. |
| `run-tests.sh` | Target's `package.json` glob replaces it. |
| `.claude/done-config.json`, `.claude/.harness/` | harlo's own dogfooding state — must not be copied. |
| harlo root `CLAUDE.md`, `README.md` | Repo-level, not plugin-level. Plugin `README.md` ports. |

## Known mismatch to declare in the plugin README

Target CLAUDE.md states an install.sh invariant: `do_install`/`do_uninstall` are a
mirror pair. **`done-gate/install.sh` has no `do_uninstall`** — it is a non-plugin
fallback installer (mirrors the bundle into a target project's `.claude/`), not a
managed-files installer like `dev-toolkit`'s. Its `tests/test-install.sh` verifies
shipped layout + path rewriting, not install/uninstall symmetry. State this in the
plugin README so a target-repo reviewer does not read it as a violated invariant.

Open alternative: drop `install.sh` + `tests/test-install.sh` entirely (the plugin
path is the primary distribution and works in the target repo). Costs 340 lines and
one whole suite. Recommend **keep** — the user asked for functionality *and* tests.

---

## Review

_(fill in after execution)_
