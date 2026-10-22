# Gates are owned by the core, not by the worker

Every decision point (accept, decision, land, failure) is a core state between
steps, routed to the Principal the project configures. The worker doing a step
never decides a gate; at most it raises a `question` signal. We chose this over
trusting a worker to route its own confirmations because a headless worker that
skips the route would silently decide for itself — the wrong decider — and
nothing after the fact could tell. Routing is guaranteed by construction, so no
proof of who decided is needed.

Addendum (2026-10-22): the core does not enforce a gate's Minimum Principal
either. It passes `min` in the `decide`/`ask` payload and journals the answer's
`by` unchecked; honouring `min` is the Principal adapter's job
(`principal/claude.ts` answers every gate as `model`).
