# The environment owns result delivery, time and rollback

The core does not check the outside world, has no clock, and does not roll
back. Crashes between a command and its signal, delays and backoff, reminders,
expiry, escalation and rollback are the environment's job; they reach the core only
as signals (a result, `stop{outcome, reason}`, `workItem_changed`, …), and an outcome
decided outside arrives typed in `stop{outcome, reason}` (outcomes on the
core's own path, such as delivered, are derived from that path). These are deliberate
no's: they keep the core a pure, clock-free state machine that is testable as
a table of `(state, signal)` rows. Do not add timers, polling or
"already done?" checks to the core. The one retry the core owns is an
immediate re-issue of a `failed` command up to a per-step or per-gate cap — safe because
`failed` means the step changed nothing.
