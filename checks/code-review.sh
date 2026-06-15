#!/usr/bin/env bash
# Code-review step (the soft checker — maker != checker). Reads a payload on stdin:
# task + acceptance criteria + changed file list + diff. Calls a read-only review agent and
# maps the verdict to an exit code: 0 = pass, 1 = changes requested.
#
# Point .harness.json at this:  "code-review": "bash \"$HARNESS_HOME/checks/code-review.sh\""
# Swap the agent without touching config:  CODE_REVIEW_CMD='codex exec --json' (must read stdin).
# Make it advisory instead of blocking: use a command that always exits 0 and never prints the token.
set -uo pipefail
payload=$(cat)

instr='You are a strict, read-only code reviewer for ONE task in an autonomous loop. The deterministic
gate (typecheck, lint, tests, mutation) ALREADY passed — do not re-check those. Review only what the
gate cannot: correctness against the acceptance criteria, whether the tests actually constrain behavior
(flag vacuous or tautological tests), missing edge cases and error handling, security, and architectural
fit. Be concrete (file:line). Do not edit anything. End with EXACTLY one final line:
  CODEREVIEW: PASS
or
  CODEREVIEW: CHANGES_REQUESTED
and if changes are requested, put a short, actionable fix list directly above that line.'

# Default agent: Claude, headless, read-only intent. Override with CODE_REVIEW_CMD.
out=$(printf '%s\n\n%s\n' "$instr" "$payload" | ${CODE_REVIEW_CMD:-claude -p --dangerously-skip-permissions} 2>&1 || true)
printf '%s\n' "$out"

printf '%s' "$out" | grep -q 'CODEREVIEW:[[:space:]]*CHANGES_REQUESTED' && exit 1
exit 0
