#!/usr/bin/env bun
// An OpenTelemetry telemetry sink (harlo-63): sends each event as one OTLP/HTTP JSON trace export, so any
// OTLP-compatible backend (an OpenTelemetry Collector, Jaeger, Tempo, Honeycomb, ...) can consume it. argv:
// --endpoint=<url> [--header=<name>=<value>]... [--resource=<key>=<value>]... telemetry notify; stdin: a
// TelemetryEvent (src/runner/telemetry.ts), sent fire-and-forget by the Runner. Prints the ack `{}`.
//
// - --endpoint is the OTLP/HTTP base URL (e.g. http://localhost:4318); `/v1/traces` is appended.
// - --header is sent on the export request (e.g. `--header=Authorization=Bearer abc`); repeatable.
// - --resource is a resource attribute (e.g. `--resource=service.name=ship`); repeatable. Pass service.name:
//   without it backends show `unknown_service`.
//
// Mapping. One Delivery = one trace: the trace id is derived from the Delivery id (the first 16 bytes of its
// sha256), so every event of a Delivery lands in the same trace without the adapter keeping state. Each event is
// one INTERNAL span named `<name> <phase>` (e.g. `setup resolved`, `accept awaiting`), ending now and starting
// elapsedMs earlier, so:
//   start    → a zero-length span marking when the step/gate began;
//   awaiting → a heartbeat span covering the wait so far (a gate waiting on the Principal);
//   resolved → a span covering the whole step/gate, from its start to its outcome.
// Attributes carry the event as-is: ship.delivery, ship.name, ship.op, ship.phase, ship.elapsed_ms (elapsedMs,
// unchanged).
//
// Best-effort, like tty.ts: an unsupported argv, bad stdin, an unreachable, slow or failing endpoint all exit 0
// (the reason goes to stderr), and the export is abandoned after REQUEST_TIMEOUT_MS, inside the Runner's
// fire-wait, so the adapter exits on its own rather than being killed.
import { createHash, randomBytes } from "node:crypto";
import { parseArgs } from "node:util";
import type { TelemetryEvent } from "../../runner/telemetry";

const REQUEST_TIMEOUT_MS = 300; // under the Runner's 500ms fire-wait (src/runner/telemetry.ts), leaving room for startup

type Options = { endpoint: string; headers: Record<string, string>; resource: Record<string, string> };
type KeyValue = { key: string; value: { stringValue: string } | { intValue: number } };

/** `<key>=<value>` pairs (split on the first `=`) as a record; a pair with no `=` or an empty key is rejected. */
const pairs = (flag: string, values: string[]): Record<string, string> =>
  Object.fromEntries(
    values.map((pair) => {
      const at = pair.indexOf("=");
      if (at <= 0) throw new Error(`--${flag} must be <key>=<value>; got ${JSON.stringify(pair)}`);
      return [pair.slice(0, at), pair.slice(at + 1)];
    }),
  );

/** Strict: an unknown flag, a missing --endpoint or a port/op other than `telemetry notify` throws. */
export const parseOptions = (args: string[]): Options => {
  const { values, positionals } = parseArgs({
    args,
    strict: true,
    allowPositionals: true,
    options: {
      endpoint: { type: "string" },
      header: { type: "string", multiple: true, default: [] },
      resource: { type: "string", multiple: true, default: [] },
    },
  });
  const [port, op, ...rest] = positionals;
  if (port !== "telemetry" || op !== "notify" || rest.length > 0) throw new Error(`unsupported: ${positionals.join(" ")}`);
  if (!values.endpoint) throw new Error("--endpoint=<url> is required");
  return { endpoint: values.endpoint, headers: pairs("header", values.header), resource: pairs("resource", values.resource) };
};

const str = (key: string, value: string): KeyValue => ({ key, value: { stringValue: value } });

/** The OTLP/JSON ExportTraceServiceRequest for one event, ending at `nowMs`. */
export const toOtlp = (event: TelemetryEvent, options: { resource: Record<string, string>; nowMs: number }): unknown => {
  const endNs = BigInt(options.nowMs) * 1_000_000n;
  const startNs = endNs - BigInt(event.elapsedMs) * 1_000_000n;
  return {
    resourceSpans: [{
      resource: { attributes: Object.entries(options.resource).map(([key, value]) => str(key, value)) },
      scopeSpans: [{
        scope: { name: "ship" },
        spans: [{
          traceId: createHash("sha256").update(event.delivery).digest("hex").slice(0, 32),
          spanId: randomBytes(8).toString("hex"),
          name: `${event.name} ${event.phase}`,
          kind: 1, // SPAN_KIND_INTERNAL
          startTimeUnixNano: startNs.toString(),
          endTimeUnixNano: endNs.toString(),
          attributes: [
            str("ship.delivery", event.delivery),
            str("ship.name", event.name),
            str("ship.op", event.op),
            str("ship.phase", event.phase),
            { key: "ship.elapsed_ms", value: { intValue: event.elapsedMs } },
          ],
        }],
      }],
    }],
  };
};

const run = async (): Promise<void> => {
  const options = parseOptions(process.argv.slice(2));
  const event = JSON.parse(await Bun.stdin.text()) as TelemetryEvent;
  const response = await fetch(`${options.endpoint.replace(/\/+$/, "")}/v1/traces`, {
    method: "POST",
    headers: { ...options.headers, "content-type": "application/json" },
    body: JSON.stringify(toOtlp(event, { resource: options.resource, nowMs: Date.now() })),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });
  if (!response.ok) throw new Error(`export failed: HTTP ${response.status}`);
};

if (import.meta.main) {
  try {
    await run();
  } catch (error) {
    // best-effort sink: never fail the Runner's fire-and-forget call
    console.error(`telemetry-otel: ${error instanceof Error ? error.message : String(error)}`);
  }
  console.log("{}");
  process.exit(0); // don't linger on an aborted connect (e.g. to an unroutable host)
}
