// harlo-63: the OTEL telemetry adapter against a REAL OpenTelemetry Collector (the otel/opentelemetry-collector
// image, run with podman or docker), with an OTLP/HTTP receiver and the debug exporter. Events go through the
// Runner's own telemetry client; the test reads them back from the collector's exported (debug) output.
// Opt-in: skipped unless SHIP_OTEL_E2E=1, so `bun run check` and the pre-push hook never need a container runtime
// or an image pull. With SHIP_OTEL_E2E=1, a collector that cannot start fails the test.
import { afterAll, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { type TelemetryEvent, telemetryClient } from "../../src/runner/telemetry";

const OTEL = join(import.meta.dir, "..", "..", "src", "adapters", "telemetry", "otel.ts");
const IMAGE = "docker.io/otel/opentelemetry-collector:0.162.0";
const CONFIG = "yaml:{receivers: {otlp: {protocols: {http: {endpoint: \"0.0.0.0:4318\"}}}}, "
  + "exporters: {debug: {verbosity: detailed}}, service: {pipelines: {traces: {receivers: [otlp], exporters: [debug]}}}}";
const TIMEOUT = 180_000; // room for a first image pull
const SERVICE = "ship-e2e";
const EVENTS: TelemetryEvent[] = [
  { delivery: "otel-1", name: "setup", op: "setup", phase: "start", elapsedMs: 0 },
  { delivery: "otel-1", name: "setup", op: "setup", phase: "resolved", elapsedMs: 42 },
  { delivery: "otel-1", name: "accept", op: "decide", phase: "awaiting", elapsedMs: 1500 },
];

const runtime = (): string => {
  const found = Bun.which("podman") ?? Bun.which("docker");
  if (!found) throw new Error("SHIP_OTEL_E2E=1 needs podman or docker on PATH");
  return found;
};

const sh = (argv: string[]): { exit: number; out: string } => {
  const ran = Bun.spawnSync(argv, { stdout: "pipe", stderr: "pipe" });
  return { exit: ran.exitCode, out: `${ran.stdout.toString()}${ran.stderr.toString()}` };
};

const freePort = (): number => {
  const server = Bun.serve({ port: 0, fetch: () => new Response() });
  const port = server.port ?? 0;
  server.stop(true);
  return port;
};

const name = `ship-otel-e2e-${process.pid}`;
let container: string | null = null;
afterAll(() => {
  if (container) sh([container, "rm", "-f", name]);
});

/** Start the collector and wait until its OTLP/HTTP receiver answers; throws if it never does. */
const startCollector = async (): Promise<string> => {
  container = runtime();
  const port = freePort();
  const started = sh([container, "run", "-d", "--rm", "--name", name, "-p", `127.0.0.1:${port}:4318`, IMAGE, `--config=${CONFIG}`]);
  if (started.exit !== 0) throw new Error(`collector did not start: ${started.out}`);
  const url = `http://127.0.0.1:${port}`;
  for (let i = 0; i < 120; i += 1) {
    const ready = await fetch(`${url}/v1/traces`, {
      method: "POST", headers: { "content-type": "application/json" }, body: "{}",
    }).then((r) => r.ok, () => false);
    if (ready) return url;
    await Bun.sleep(250);
  }
  throw new Error(`collector never became ready: ${sh([container, "logs", name]).out}`);
};

/** The collector's exported output, once it shows every event's span (or what it has after the wait). */
const exported = async (): Promise<string> => {
  let logs = "";
  for (let i = 0; i < 60; i += 1) {
    logs = sh([container ?? runtime(), "logs", name]).out;
    if (EVENTS.every((e) => logs.includes(`Name           : ${e.name} ${e.phase}`))) break;
    await Bun.sleep(250);
  }
  return logs;
};

describe.skipIf(process.env.SHIP_OTEL_E2E !== "1")("otel adapter → a real OpenTelemetry Collector", () => {
  test("each TelemetryEvent is accepted as OTLP and exported with its fields and the argv service.name", async () => {
    const url = await startCollector();
    const telemetry = telemetryClient({
      argv: ["bun", OTEL, `--endpoint=${url}`, `--resource=service.name=${SERVICE}`], env: {}, tools: [],
    });
    for (const event of EVENTS) telemetry.notify(event);
    await telemetry.drain();

    const logs = await exported();
    expect(logs).toContain(`service.name: Str(${SERVICE})`);
    for (const event of EVENTS) {
      expect(logs).toContain(`Name           : ${event.name} ${event.phase}`);
      expect(logs).toContain(`ship.op: Str(${event.op})`);
      expect(logs).toContain(`ship.phase: Str(${event.phase})`);
      expect(logs).toContain(`ship.elapsed_ms: Int(${event.elapsedMs})`);
    }
    expect(logs).toContain(`ship.delivery: Str(${EVENTS[0]?.delivery})`);
  }, TIMEOUT);
});
