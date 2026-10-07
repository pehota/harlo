// Telemetry port client (harlo-55): an optional, best-effort sink for Delivery lifecycle events. Unlike the
// other ports, a notify here is fire-and-forget off the Runner's own clock, not a core Command: a slow, crashing
// or missing telemetry adapter must never change a step/gate's outcome, so failures are swallowed, not surfaced.
import type { DeliveryId } from "../contracts/common";
import type { AdapterSpec } from "./spawn";

export type TelemetryPhase = "start" | "resolved" | "awaiting";
export type TelemetryEvent = {
  delivery: DeliveryId;
  name: string; // step or gate name
  op: string;
  phase: TelemetryPhase;
  elapsedMs: number;
};

export type Telemetry = {
  notify(event: TelemetryEvent): void;
  drain(): Promise<void>; // resolves once every notify()'d event has been fired, in order
};

const noopTelemetry: Telemetry = { notify: () => {}, drain: async () => {} };

const FIRE_WAIT_MS = 500; // caps how long one event's fire can delay the next: a hung adapter must never stall the queue

/** Fire `spec` with `event` on stdin and wait (briefly) for it to exit, so the next queued event's write can
 * never land on the sink before this one's. Any spawn error, non-zero exit or hang is ignored (best-effort
 * only) once the wait caps out, so a hung or missing adapter delays later events but never blocks them. */
const fire = async (spec: AdapterSpec, event: TelemetryEvent): Promise<void> => {
  try {
    const proc = Bun.spawn([...spec.argv, "telemetry", "notify"], {
      stdin: new Blob([JSON.stringify(event)]),
      stdout: "ignore",
      stderr: "ignore",
      detached: true, // its own process group, so a timeout can kill the whole tree (e.g. a shell wrapping a hung child), not just the direct child
    });
    const timedOut = Symbol("timedOut");
    const outcome = await Promise.race([proc.exited, Bun.sleep(FIRE_WAIT_MS).then(() => timedOut)]).catch(() => timedOut);
    if (outcome === timedOut) {
      try {
        process.kill(-proc.pid, "SIGKILL");
      } catch {
        proc.kill();
      }
    }
  } catch {
    // unreachable in practice (Bun.spawn throws synchronously only on bad args), kept for defense-in-depth
  }
};

/**
 * A client that fires events one at a time, in call order: concurrent `fire`s would race as independent
 * OS processes with no ordering guarantee, scrambling a sink's view of a step's own start/awaiting/resolved.
 * `drain()` lets a short-lived CLI process wait for the queue to finish before exiting.
 */
const serialClient = (spec: AdapterSpec): Telemetry => {
  let queue = Promise.resolve();
  const notify = (event: TelemetryEvent): void => {
    queue = queue.then(() => fire(spec, event));
  };
  return { notify, drain: () => queue };
};

export const telemetryClient = (spec: AdapterSpec | null): Telemetry => (spec === null ? noopTelemetry : serialClient(spec));
