# The core is a signal-driven pure function

The core is `(state, signal) → (state′, commands)`. It never calls a port and
waits: it issues a command carrying an id, records what it awaits and returns;
the Runner saves state. Every result — an adapter finishing, a Principal answering, CI
going green — returns later as a signal through the input port
(`start`, `next`, `signal`, `stop`, `changed`). We chose this over synchronous port calls
and over a long-running daemon because it makes control flow deterministic,
survives waits of hours, and turns duplicate or stale results into a single
id comparison.

## Consequences

- One signal is applied per Delivery at a time.
- A Result whose command id is not awaited is ignored; Delivery signals
  (`start`, `stop`, `workItem_changed`) are matched by Delivery only.
- A command made moot by a Delivery signal is cancelled with `cancel{id}`.
- Staying reachable (bot, webhook) is the environment's concern, not the core's.
