---
status: accepted
---

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
a branch created *after* SessionStart had already run in SESSION mode. That case no
longer exists.

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
