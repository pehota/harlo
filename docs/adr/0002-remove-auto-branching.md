---
status: superseded
superseded-by: docs/design-v2.md
---

> **Superseded.** `docs/design-v2.md`'s `dod/` plugin never had auto-branching
> to begin with — this ADR's decision (branching is not the DoD gate's job)
> was carried forward by simply not building it. Kept as historical record of
> the reasoning; the mechanisms it references (`auto-branch.sh`,
> `done-config.json`) no longer exist.

# Auto-branching is removed, not merely defaulted off

`auto-branch.sh` was a `PreToolUse(Write|Edit)` hook that, on trunk, silently ran
`git checkout -b <branch_prefix><timestamp>` on the session's first edit — moving the
work into TASK mode so it got cross-session continuity. It is deleted outright, along
with the `auto_branch` and `branch_prefix` config keys.

**Decision:** branch creation is version-control policy, not completion verification —
deciding where a user's work lives is not the DoD gate's job (single responsibility).
It was also dead weight in practice: `auto_branch` already defaulted to `false` and was
`false` in this repo, so the hook never actually ran here. Deliberate isolation remains
available and better matches how this repo's owner actually works — "on main by
default; a worktree when told otherwise" — via `new-worktree.sh` / `run-task.sh`,
which put a session in TASK mode from the first commit rather than reacting to an edit
mid-session.

**Both anchor modes survive.** TASK mode still engages whenever HEAD is off trunk — a
branch or a worktree — exactly as before. Only the automatic mid-session trunk→branch
flip is gone. The `tree-base/<task_key>.dirty` pin is not orphaned by this: it was
already written by `baseline-snapshot.sh` (SessionStart) whenever a session starts off
trunk; `auto-branch.sh` only ever pinned it for the one case SessionStart could not —
a branch created *after* SessionStart had already run in SESSION mode. That case still
exists, and removing `auto-branch.sh` leaves it unhandled rather than closing it: a
human who branches mid-session while on trunk moves HEAD off trunk without a fresh
SessionStart in between, so the next session's first task-mode SessionStart is the one
that pins `tree-base/br-<branch>.dirty` — from *live* porcelain, which by then already
holds the previous session's uncommitted WIP. That WIP gets whitelisted into the tree
baseline, and the gate stops blocking on the agent's own unfinished work. This hole
predates this ADR — `auto-branch.sh` only masked it by pinning at checkout time from
the session's clean pre-edit SessionStart snapshot — and removing the hook removes that
masking, not the hole. It is now both unprotected and untested: the only end-to-end
test of this shape, `AUTO-BRANCH INVARIANT 2` in `test-tree-status.sh`, was deleted in
this same change as a duplicate of the surviving branch-at-SessionStart test. The
correct fix belongs in `baseline-snapshot.sh`, not here. It fires only on a human
branching mid-session while on trunk; `new-worktree.sh` and `run-task.sh` both start
their sessions already off trunk, so neither path is affected.

## Considered options

**Keep it, default off (status quo before this ADR).** The shipped default already was
`false`. Rejected as insufficient: an off-by-default flag is still a live code path the
gate's identity resolver (`hc_resolve`), the config schema, and every reader of
`done-config.json` must keep reasoning about — a dead branch that earns its keep only if
someone flips one config key back on. It also does not remove the single-responsibility
problem, just defers it.

**Keep it behind a flag, remove the default-on temptation entirely (e.g. delete from
`done-detect.sh` seeding, require explicit opt-in only).** Still rejected for the same
reason: the hook remains one config key away from firing, and firing means making a
version-control decision (branching) from a completion-verification component. The
separation-of-concerns argument doesn't weaken just because the default is safe.

**Delete it.** Chosen. Removes the dead config branch, the hook, and the class of
behavior (an agent branching a user's trunk without being asked) in one step.

## Consequences

**A trunk-based session now stays in SESSION anchor mode for its whole lifetime**
unless the user branches or opens a worktree deliberately. SESSION mode's anchor
(`baselines/<session_id>.sha`) is the weaker of the two: it advances past leading
foreign commits and is keyed to a session file rather than a pinned merge-base, so it
is more exposed to session-boundary noise (compaction, a lost/reaped baseline file)
than TASK mode's `merge-base(trunk, HEAD)` pin. A user who wants the stronger anchor
must branch or use a worktree first — the harness will not do it for them anymore.

**One less PreToolUse wiring.** `hooks/hooks.json` and `install.sh`'s `settings.local.json`
merge each drop from two `PreToolUse` entries to one (`commit-ledger.sh pre`); the
`Write|Edit` matcher this hook alone used is gone from the harness entirely.
