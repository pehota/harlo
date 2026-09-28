# State is a snapshot plus an append-only journal

The State port stores a snapshot of each Delivery (the source of truth) and an
append-only journal of every step result and decision, with the kind of
Principal who made it (audit only, never replayed). We considered full event
sourcing — deterministic replay for free — and rejected it for simplicity:
volume was never the issue (a Delivery produces tens of journal entries), but a
snapshot is the simplest thing that still records who decided what.
