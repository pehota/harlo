# Gates are owned by the core, not by the worker

Every decision point (accept, decision, land, failure) is a core state between
steps, routed to the Principal the project configures. The worker doing a step
never decides a gate; at most it raises a `question` signal. We chose this over
trusting a worker to route its own confirmations because a headless worker that
skips the route would silently decide for itself — the wrong decider — and
nothing after the fact could tell. Routing is guaranteed by construction, so no
proof of who decided is needed.
