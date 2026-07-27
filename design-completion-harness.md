# Design prompt: completion harness for Claude Code

## Problem

CLAUDE.md has a Definition of Done section, but it does not fire reliably.
In a recent session the agent had to be nudged for every step of it:

1. Real verification vs. code reading — agent described what the code does instead of running it.
2. Operator-executable verification — presented a plan that required sudo without checking whether that was feasible.
3. Deployment environment fit — verified code logic but not whether the feature works in the actual deployment target (Docker, sysfs mount missing).
4. Independent code review — declared done without initiating one.
5. Review scope — was about to review the whole codebase, not the changeset.
6. Acting on findings — presented review results and stopped; did not address them.
7. Re-verification after fixes — fixed findings and committed without another review pass.
8. Existing test suite — never ran it after making changes.
9. New test coverage — added new functionality without checking whether new tests were needed.
10. App startup — never confirmed the app still starts.

CLAUDE.md instructions are read once at session start and then drift out of focus
during long implementation threads. The agent completes the immediate task
(code change, patch apply, conflict resolve) and anchors there, treating
"implementation done" as "task done."

## Goal

A harness that makes the completion checklist unavoidable — not advisory text
the agent can ignore, but a structural forcing function that runs automatically
or is trivially invokable after any non-trivial code change.

## Design space to explore

Consider these mechanisms and their trade-offs:

**Hooks** — Claude Code settings.json supports PostToolUse and Stop hooks.
A Stop hook could block the session exit or emit a checklist that Claude must
respond to. A PostToolUse hook on `git commit` could inject a reminder.
Trade-off: hooks run shell commands, not Claude prompts — they can print
text but can't force Claude to reason.

**Skill (`/done` or `/ship`)** — A slash command the developer calls when
they think work is complete. The skill runs through the checklist in order,
blocks on each step, and only declares done when all pass. Forces explicit
invocation but still requires the developer to remember to call it.

**Autonomous loop** — A background agent that wakes periodically, checks
whether there are uncommitted changes or recent commits without a review, and
nudges. High noise risk.

**CLAUDE.md rewrite** — Restructure the Definition of Done as a numbered
protocol with explicit "do not output the word done until steps 1-N are
confirmed" phrasing. Easiest to deploy, least reliable (same problem as today).

**Checklist task injection** — When an implementation task starts, the agent
immediately creates a TaskList with the completion steps and is required to
tick them off. The task tracker is visible throughout the thread.

## What to design

Produce a concrete harness design that:

1. Identifies which mechanism (or combination) best fits the Claude Code
   extension model — hooks, skills, CLAUDE.md, task tracking, or other.
2. Specifies exactly what fires, when, and what it checks:
   - Tests green (run command, check exit code)
   - App starts (run command, check output)
   - Code review run on the changeset (not the whole repo)
   - Findings addressed (how does the harness know?)
   - Re-verification done after fixes
   - Verification is real (exercised flow) not synthetic (diff read)
   - Deployment environment covered (how to make this checkable?)
3. Keeps friction low for the developer — one command or zero commands.
4. Is implementable within the Claude Code plugin/settings model.
5. Includes a concrete implementation plan: which files to create/modify,
   what the hook/skill/CLAUDE.md text looks like.

Start by reading the Claude Code settings and hooks documentation, then
propose a design before writing any code.
