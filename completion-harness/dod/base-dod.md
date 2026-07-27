# Base Definition of Done

The built-in checklist the completion harness enforces for **every** changeset.
`/done` reads this file, folds in external instruction sources (see Step 0.5 of
the `/done` skill), and produces the **effective DoD** for the task — then holds
the changeset to that merged, deduped list.

This is the low-precedence baseline. External/user instructions **augment** it
and, on conflict, **override** it. No item here or folded in may be silently
dropped: each becomes a blocking check, or surfaces as an escalation (A/B/C)
with a reason.

## Checklist

- [ ] **Tests green (before/after checkpoint).** Run the effective test command
      and diff against the baseline snapshot. Newly-red (passed on baseline,
      fails now) → you broke it → must fix, no escape. Already-red on baseline →
      boyscout default: fix it anyway. Do not proceed with red tests.
- [ ] **App starts.** Exercise `effective.start` (or the detected startup probe)
      and confirm the app comes up.
- [ ] **Changeset-scoped independent (fresh-agent) review.** Invoke `/code-review`
      scoped to the changeset diff — an independent reviewer, never self-review.
- [ ] **Findings addressed.** Every review finding is fixed, or explicitly
      justified as N/A.
- [ ] **Re-verified after fixes.** After applying any fix, return to the tests
      step and re-verify with the fixes in place.
- [ ] **Verification real (exercised), not synthetic (diff-read).** Verify by
      exercising the actual flow against an independent source of truth in the
      real target medium — never by reading the diff or grading your own render.
- [ ] **Deploy target stated.** Run `deploy_check_cmd` if set; otherwise state
      the deploy target explicitly and whether it was exercised. Never claim
      false coverage.
- [ ] **`task_checks` executed.** Run every task-specific verification captured
      at task start. Never silently skip one.
