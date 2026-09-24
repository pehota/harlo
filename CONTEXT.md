# harlo

A harness that makes a coding agent prove a task is done against an agreed
Definition of Done before it may stop.

## Language

### Review

**Finding**:
One issue the reviewer reports about a changeset, located at a file and line.
_Avoid_: comment, remark, issue

**Blocking finding**:
A finding with a concrete failure scenario — bug, security hole, broken
behaviour, spec violation. Fails the review.
_Avoid_: critical, error

**Advisory**:
A non-blocking finding, including a proactive improvement suggestion. Each one
is put to the user as a fix/skip decision.
_Avoid_: suggestion, nit, recommendation

**Impact trace**:
The reviewer's walk from each changed hunk up through its callers and
enclosing scope, naming the guarantees in force there (transaction, lock,
auth context, ordering) and whether the change stays inside them.
_Avoid_: blast radius, call-graph review

**Scope check**:
The reviewer's confirmation that every hunk of a changeset traces to the task,
and nothing planned was left out. Never skipped; the only lens that can stop
the review early.
_Avoid_: scope creep review, task-fit

**Scope creep**:
A change beyond the task: a hunk no part of the task or its requirements asks
for. Includes any standards file edit the task didn't request. Blocking, and
a decision for the user (revert, or accept and amend the task) — never an
auto-fix.
_Avoid_: unrequested change, out-of-scope edit

**Scope gap**:
A part of the task the changeset does not implement at all — no hunk even
attempts it. Blocking, and fixed like any other failing requirement. Not the
same as getting an attempted part wrong, which is a spec finding.
_Avoid_: missing requirement, incomplete task

**Review depth**:
How much of the review runs: `full` (every lens) or `scope` (scope check
only). `scope` needs the user's explicit consent; the agent may only propose it.
_Avoid_: skipped review, light review

### Context

**Context collector**:
The fresh agent that writes the context brief at define time.
_Avoid_: context agent, discoverer

**Context brief**:
The project standards and domain invariants relevant to a task, collected
once at define time by a fresh agent and shared by implementers and the
reviewer. A floor for the reviewer, never a ceiling.
_Avoid_: context doc, task context

**Project standards**:
The written and de-facto conventions of the reviewed project — its rule files,
ADRs, and the idioms of its framework and neighbouring code. Fixed for the
life of a task.
_Avoid_: style guide, best practices

**Standards file**:
A file the harness treats as project standards by path alone, mechanically:
`CLAUDE.md`, `AGENTS.md`, `CONTEXT.md` at any depth, `docs/adr/*`,
`.claude/rules/*`, `.cursor/rules/*`, `.github/copilot-instructions.md`.
_Avoid_: rule file, config file
