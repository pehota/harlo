// Test data for lifecycle.property.test.ts: a pure model of the stall poller's rules (plan M1.4, §5.2), so the
// property can check "no silent stall" before env/poll-stalled.sh exists (M1). The clock lives only here.
import type { CommandId, Port } from "../../src/contracts/common";
import type { TimedEntry } from "../../src/contracts/snapshot";
import type { RunnerSignal, Snapshot } from "../../src/core/types";

export type Flag = "never sent" | "unknown host" | "dead" | "hung?";

/** What the poller sees: its clock, its host, its config, and `ps` (the current start time of a pid, or null). */
export type Poll = {
  now: number;
  host: string;
  grace: number;
  maxRuntime: (port: Port) => number;
  startOf: (pid: number) => string | null;
};

type Sent = Extract<RunnerSignal, { kind: "sent" }>;

/** Simulated start times are `<ms>#<serial>`: the serial makes two starts in the same ms differ. */
export const startedAt = (started: string): number => Number(started.split("#")[0]);

export const sentOf = (entries: TimedEntry[], id: CommandId): Sent | undefined =>
  entries.flatMap((e) => (e.signal.kind === "sent" && e.signal.id === id ? [e.signal] : [])).at(-1);

const has = (entries: TimedEntry[], id: CommandId, kinds: readonly string[]): boolean =>
  entries.some((e) => kinds.includes(e.signal.kind) && "id" in e.signal && e.signal.id === id);

export const isAccepted = (entries: TimedEntry[], id: CommandId): boolean => has(entries, id, ["accepted"]);

/** A Result, `accepted` or `adapter_error` entry for the id: the Runner saw how the process ended. */
export const hasOutcome = (entries: TimedEntry[], id: CommandId): boolean =>
  has(entries, id, ["result", "accepted", "adapter_error"]);

/** The poller's verdict for one Delivery (its latest snapshot and journal), or null when it raises nothing. */
export const stallFlag = (s: Snapshot, entries: TimedEntry[], poll: Poll): Flag | null => {
  const awaiting = s.awaiting;
  if (awaiting === null) return null;

  const sent = sentOf(entries, awaiting.id);
  if (!sent) {
    const last = entries.at(-1);
    const quietFor = last ? poll.now - Date.parse(last.time) : 0;
    return quietFor > poll.grace ? "never sent" : null;
  }
  if (sent.host !== poll.host) return "unknown host";
  if (hasOutcome(entries, awaiting.id)) return null; // `accepted` is not pid-checked: its work continues elsewhere

  const alive = poll.startOf(sent.pid) === sent.started; // (pid, started): a reused pid counts as dead
  if (!alive) return "dead";
  return poll.now - startedAt(sent.started) > poll.maxRuntime(awaiting.port) ? "hung?" : null;
};
