// harlo-63: the OTEL telemetry adapter — argv parsing, the event → OTLP span mapping, the export request against a
// local recording server, and fire-and-forget against unreachable, slow and failing endpoints.
import { afterEach, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { D, id, policy, workItem } from "../../core/fixtures/builders.fixture";
import { type Deps, type Pending, apply } from "../../runner/apply";
import { FakeSpawn, FakeState, type Script } from "../../runner/fixtures/fakes.fixture";
import { type TelemetryEvent, telemetryClient } from "../../runner/telemetry";
import { parseOptions, toOtlp } from "./otel";

const OTEL = join(import.meta.dir, "otel.ts");
const FIRE_WAIT_MS = 500; // the Runner client's per-event fire-wait (src/runner/telemetry.ts)
const TIMEOUT = 30_000;
const EVENT: TelemetryEvent = { delivery: "k-1", name: "accept", op: "decide", phase: "awaiting", elapsedMs: 1234 };

const cleanups: (() => void)[] = [];
afterEach(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

type Request = { path: string; headers: Headers; body: unknown };
/** A local OTLP/HTTP endpoint that records each request and replies with `respond` (default 200 `{}`). */
const recordingServer = (respond: () => Response | Promise<Response> = () => Response.json({})) => {
  const requests: Request[] = [];
  const server = Bun.serve({
    port: 0,
    fetch: async (req) => {
      requests.push({ path: new URL(req.url).pathname, headers: req.headers, body: await req.json() });
      return respond();
    },
  });
  cleanups.push(() => server.stop(true));
  return { url: `http://127.0.0.1:${server.port}`, requests };
};

/** A TCP endpoint that answers every connection with bytes that are not HTTP, then hangs up. */
const malformedServer = (): string => {
  const listener = Bun.listen({
    hostname: "127.0.0.1",
    port: 0,
    socket: { open: (socket) => { socket.write("not http at all\r\n\r\n"); socket.end(); }, data: () => {} },
  });
  cleanups.push(() => listener.stop(true));
  return `http://127.0.0.1:${listener.port}`;
};

/** A port nothing listens on: bound once to get a free port, then released. */
const closedPort = (): string => {
  const server = Bun.serve({ port: 0, fetch: () => new Response() });
  const url = `http://127.0.0.1:${server.port}`;
  server.stop(true);
  return url;
};

const adapter = async (args: string[], stdin: string = JSON.stringify(EVENT)) => {
  const started = Date.now();
  const proc = Bun.spawn(["bun", OTEL, ...args], { stdin: new Blob([stdin]), stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { stdout: stdout.trim(), stderr, exit, ms: Date.now() - started };
};

describe("parseOptions", () => {
  test("endpoint, repeatable headers and resource attributes come from argv", () => {
    const options = parseOptions([
      "--endpoint=http://collector:4318", "--header=Authorization=Bearer a=b", "--header", "x-team=ship",
      "--resource=service.name=ship", "--resource=deployment.environment=dev", "telemetry", "notify",
    ]);
    expect(options).toEqual({
      endpoint: "http://collector:4318",
      headers: { Authorization: "Bearer a=b", "x-team": "ship" },
      resource: { "service.name": "ship", "deployment.environment": "dev" },
    });
  });

  test.each([
    [["--endpoint=http://c:4318", "--bogus=1", "telemetry", "notify"]],
    [["telemetry", "notify"]],
    [["--endpoint=http://c:4318", "telemetry", "run"]],
    [["--endpoint=http://c:4318", "tracker", "notify"]],
    [["--endpoint=http://c:4318", "telemetry", "notify", "extra"]],
    [["--endpoint=http://c:4318", "--header=novalue", "telemetry", "notify"]],
    [["--endpoint=http://c:4318", "--resource==x", "telemetry", "notify"]],
  ])("rejects unsupported argv %j", (args) => {
    expect(() => parseOptions(args)).toThrow();
  });
});

describe("toOtlp", () => {
  const request = toOtlp(EVENT, { resource: { "service.name": "ship" }, nowMs: 10_000 }) as {
    resourceSpans: { resource: { attributes: unknown[] }; scopeSpans: { spans: Record<string, unknown>[] }[] }[];
  };
  const span = request.resourceSpans[0]?.scopeSpans[0]?.spans[0] ?? {};

  test("one INTERNAL span named `<name> <phase>`, ending now and starting elapsedMs earlier", () => {
    expect(span).toMatchObject({
      name: "accept awaiting", kind: 1, startTimeUnixNano: "8766000000", endTimeUnixNano: "10000000000",
    });
    expect(span.spanId).toMatch(/^[0-9a-f]{16}$/);
  });

  test("the event's fields are span attributes, elapsedMs unchanged", () => {
    expect(span.attributes).toEqual([
      { key: "ship.delivery", value: { stringValue: "k-1" } },
      { key: "ship.name", value: { stringValue: "accept" } },
      { key: "ship.op", value: { stringValue: "decide" } },
      { key: "ship.phase", value: { stringValue: "awaiting" } },
      { key: "ship.elapsed_ms", value: { intValue: 1234 } },
    ]);
  });

  test("the resource attributes are the argv-supplied ones", () => {
    expect(request.resourceSpans[0]?.resource.attributes).toEqual([{ key: "service.name", value: { stringValue: "ship" } }]);
  });

  test("every event of a Delivery shares one trace id; another Delivery gets another", () => {
    const traceOf = (event: TelemetryEvent): unknown =>
      (toOtlp(event, { resource: {}, nowMs: 0 }) as typeof request).resourceSpans[0]?.scopeSpans[0]?.spans[0]?.traceId;
    const trace = traceOf(EVENT);
    expect(trace).toMatch(/^[0-9a-f]{32}$/);
    expect(traceOf({ ...EVENT, name: "setup", phase: "start", elapsedMs: 0 })).toBe(trace);
    expect(traceOf({ ...EVENT, delivery: "k-2" })).not.toBe(trace);
  });
});

describe("telemetry notify", () => {
  test("POSTs the OTLP/JSON export to <endpoint>/v1/traces with the argv headers, and acks {}", async () => {
    const server = recordingServer();
    const ran = await adapter([
      `--endpoint=${server.url}/`, "--header=Authorization=Bearer s3cret", "--resource=service.name=ship", "telemetry", "notify",
    ]);
    expect(ran).toMatchObject({ exit: 0, stdout: "{}" });
    expect(server.requests).toHaveLength(1);
    const [req] = server.requests;
    expect(req?.path).toBe("/v1/traces");
    expect(req?.headers.get("authorization")).toBe("Bearer s3cret");
    expect(req?.headers.get("content-type")).toBe("application/json");
    expect(JSON.stringify(req?.body)).toContain('"name":"accept awaiting"');
    expect(JSON.stringify(req?.body)).toContain('{"key":"service.name","value":{"stringValue":"ship"}}');
  }, TIMEOUT);

  test("unsupported argv sends nothing, says why on stderr, and still exits 0 with the ack", async () => {
    const server = recordingServer();
    const ran = await adapter([`--endpoint=${server.url}`, "--bogus", "telemetry", "notify"]);
    expect(ran).toMatchObject({ exit: 0, stdout: "{}" });
    expect(ran.stderr).toContain("telemetry-otel:");
    expect(server.requests).toHaveLength(0);
  }, TIMEOUT);

  test("a malformed event on stdin exits 0 with the ack", async () => {
    const server = recordingServer();
    expect(await adapter([`--endpoint=${server.url}`, "telemetry", "notify"], "not json")).toMatchObject({ exit: 0, stdout: "{}" });
    expect(server.requests).toHaveLength(0);
  }, TIMEOUT);
});

describe("fire-and-forget", () => {
  const setupOk: Script = { reply: { kind: "result", result: { status: "ok", body: { path: "/ws/k-1", base: "trunk" } } } };
  const defineOk: Script = {
    reply: { kind: "result", result: { status: "ok", body: { criteria: ["greets"], runbook: ["greet Ada"] } } },
  };
  const startK: Pending = { kind: "start", workItem };

  /** Drive a Delivery through setup → define → the accept gate, optionally with the otel adapter as the sink. */
  const drive = async (endpoint: string | null) => {
    const state = new FakeState();
    const spawn = new FakeSpawn(state, { [id("setup-1")]: setupOk, [id("define-1")]: defineOk });
    const telemetry = telemetryClient(
      endpoint === null ? null : { argv: ["bun", OTEL, `--endpoint=${endpoint}`, "--resource=service.name=ship"], env: {}, tools: [] },
    );
    const deps: Deps = { policy, state, spawn: spawn.spawn, host: "h", now: () => "2026-10-09T00:00:00.000Z", telemetry };
    const report = await apply(deps, startK);
    return { report, telemetry, state };
  };

  const endpoints: [string, () => string][] = [
    ["an unreachable host (closed port)", closedPort],
    ["an unreachable host (unroutable address)", () => "http://10.255.255.1:4318"],
    ["a slow host that never responds", () => recordingServer(() => new Promise<Response>(() => {})).url],
    ["a 5xx response", () => recordingServer(() => new Response("down", { status: 503 })).url],
    ["a malformed response", malformedServer],
  ];

  test.each(endpoints)("%s: same step/gate results and persisted state as no telemetry", async (_, endpoint) => {
    const plain = await drive(null);
    const withOtel = await drive(endpoint());
    expect(withOtel.report).toEqual(plain.report);
    expect(withOtel.state.top(D)).toEqual(plain.state.top(D));
    expect(withOtel.state.entries(D)).toEqual(plain.state.entries(D));
    const draining = Date.now();
    await withOtel.telemetry.drain(); // every fire is bounded by the client's fire-wait
    expect(Date.now() - draining).toBeLessThan(10 * (FIRE_WAIT_MS + 250));
  }, TIMEOUT);

  test.each(endpoints)("%s: the adapter exits 0 with the ack, on its own, without hanging", async (_, endpoint) => {
    const ran = await adapter([`--endpoint=${endpoint()}`, "--resource=service.name=ship", "telemetry", "notify"]);
    expect(ran).toMatchObject({ exit: 0, stdout: "{}" });
    expect(ran.ms).toBeLessThan(FIRE_WAIT_MS + 250);
  }, TIMEOUT);
});
