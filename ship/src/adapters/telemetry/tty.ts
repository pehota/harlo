#!/usr/bin/env bun
// A human-readable telemetry sink (harlo-55): prints one line per event to its own process's stdout. argv:
// telemetry notify; stdin: a TelemetryEvent (src/runner/telemetry.ts), sent fire-and-forget by the Runner.
import type { TelemetryEvent } from "../../runner/telemetry";

const line = (event: TelemetryEvent): string =>
  `[telemetry] ${event.delivery} ${event.name} ${event.op} ${event.phase} ${event.elapsedMs}ms`;

const run = async (): Promise<void> => {
  const [port, op] = process.argv.slice(2);
  if (port !== "telemetry" || op !== "notify") throw new Error(`unsupported: ${port} ${op}`);
  const event = JSON.parse(await Bun.stdin.text()) as TelemetryEvent;
  console.log(line(event));
};

try {
  await run();
} catch {
  // best-effort sink: never fail the Runner's fire-and-forget call
}
