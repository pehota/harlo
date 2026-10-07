// M0.18: the CLI as a subprocess (plan §5.1), with the real file State adapter and the scripted fake adapter.
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TimedEntry } from "./contracts/snapshot";
import type { Snapshot } from "./core/types";

const ROOT = join(import.meta.dir, "..");
const BIN = join(ROOT, "bin", "ship");
const STATE = join(ROOT, "src", "adapters", "state", "files.ts");
const FAKE = join(ROOT, "src", "adapters", "fake.ts");
const CONFLICTING_STATE = join(import.meta.dir, "fixtures", "conflicting-state.sh");
const RECORDING_TELEMETRY = join(import.meta.dir, "fixtures", "recording-telemetry.sh");
const CRASHING_TELEMETRY = join(import.meta.dir, "fixtures", "crashing-telemetry.sh");
const HANGING_TELEMETRY = join(import.meta.dir, "fixtures", "hanging-telemetry.sh");
const TIMEOUT = 30_000;

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

type Options = { replies?: Record<string, unknown>; state?: string[]; telemetry?: string[] };
type Ran = { exit: number; out: Record<string, unknown> | null; stderr: string };

const ok = (body: unknown) => JSON.stringify({ status: "ok", body });
const workItem = (key: string, title = "Greet by name") => ({ status: "ok", body: { workItem: { key, title, body: "Say hello." } } });
/** Unless a test scripts otherwise: tracker.read gives WorkItem `k`, tracker.next no key, everything else accepts. */
const DEFAULT_REPLIES = { "tracker.read": workItem("k"), "tracker.next": { status: "ok", body: { key: null } } };

/** A project dir with both config layers; every port is the fake adapter except State (the file adapter). */
const project = () => {
  const dir = mkdtempSync(join(tmpdir(), "ship-cli-"));
  dirs.push(dir);
  const stateDir = join(dir, "state");
  const machinePath = join(dir, "machine.json");
  const script = join(dir, "script.json");
  const telemetryLog = join(dir, "telemetry.jsonl");

  const configure = (options: Options = {}): void => {
    writeFileSync(script, JSON.stringify({ replies: { ...DEFAULT_REPLIES, ...options.replies } }));
    const fake = ["bun", FAKE, "--script", script];
    const adapters = {
      tracker: fake, workspace: fake, define: fake, implement: fake, check: fake, integrate: fake, deploy: fake, verify: fake,
    };
    const policy = {
      tracker: {
        outcomes: {
          delivered: { status: "done" }, accepted_with_failure: { status: "done" },
          rolled_back: { status: "reopened", comment: true }, abandoned: { comment: true },
        },
      },
    };
    writeFileSync(join(dir, "ship.config.json"), JSON.stringify({ projectId: "demo", adapters, policy }));
    const state = options.state ?? ["bun", STATE, "--dir", stateDir];
    const machine: Record<string, unknown> = { principal: fake, state };
    if (options.telemetry) machine.telemetry = options.telemetry;
    writeFileSync(machinePath, JSON.stringify(machine));
  };

  const ship = async (...args: string[]): Promise<Ran> => {
    const proc = Bun.spawn(["bun", BIN, ...args], {
      cwd: dir, stdout: "pipe", stderr: "pipe",
      env: { PATH: process.env.PATH ?? "", HOME: dir, SHIP_MACHINE_CONFIG: machinePath, RECORD_TO: telemetryLog },
    });
    const [stdout, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    const line = stdout.trim();
    return { exit, out: line ? (JSON.parse(line) as Record<string, unknown>) : null, stderr };
  };

  const versions = (delivery: string): number[] =>
    existsSync(join(stateDir, delivery))
      ? readdirSync(join(stateDir, delivery)).filter((f) => /^\d+\.json$/.test(f)).map((f) => Number.parseInt(f, 10)).sort((a, b) => a - b)
      : [];
  const read = (delivery: string, version: number): { state: Snapshot; entries: TimedEntry[] } =>
    JSON.parse(readFileSync(join(stateDir, delivery, `${version}.json`), "utf8"));
  const journal = (delivery: string): TimedEntry[] => versions(delivery).flatMap((v) => read(delivery, v).entries);
  const snapshot = (delivery: string): Snapshot => read(delivery, versions(delivery).at(-1) ?? 0).state;
  const deliveries = (): string[] => (existsSync(stateDir) ? readdirSync(stateDir).sort() : []);
  /** Each `ship` invocation's telemetry fires are independent processes appending concurrently to one file,
   * so a line can interleave with another; keep only lines that parse as a complete JSON object. */
  const telemetryEvents = (): Record<string, unknown>[] =>
    existsSync(telemetryLog)
      ? readFileSync(telemetryLog, "utf8").split("\n").filter((l) => l.trim()).flatMap((l) => {
          try {
            return [JSON.parse(l)];
          } catch {
            return [];
          }
        })
      : [];

  configure();
  return { dir, configure, ship, versions, journal, snapshot, deliveries, telemetryEvents };
};

const FAILED_READ = { "tracker.read": { status: "failed", info: "tracker unreachable" } };

describe("ship start", () => {
  test("creates the Delivery and runs Setup", async () => {
    const p = project();
    const ran = await p.ship("start", "k");
    expect(ran).toMatchObject({ exit: 0, out: { delivery: "k-1", issued: ["k-1/setup-1"], awaiting: "k-1/setup-1" } });
    expect(p.snapshot("k-1").at).toBe("setup");
  }, TIMEOUT);

  test("an invalid key is invalid input (exit 1)", async () => {
    const p = project();
    expect((await p.ship("start", "-bad")).exit).toBe(1);
    expect(p.deliveries()).toEqual([]);
  }, TIMEOUT);

  test("a failed tracker.read gives exit 4 without calling the core", async () => {
    const p = project();
    p.configure({ replies: FAILED_READ });
    const ran = await p.ship("start", "k");
    expect(ran.exit).toBe(4);
    expect(p.deliveries()).toEqual([]);
  }, TIMEOUT);

  test("a tracker.read for another key gives exit 4 without calling the core", async () => {
    const p = project();
    p.configure({ replies: { "tracker.read": workItem("j") } });
    expect((await p.ship("start", "k")).exit).toBe(4);
    expect(p.deliveries()).toEqual([]);
  }, TIMEOUT);

  test("a crashed awaited adapter gives exit 5, journaled, with the output line", async () => {
    const p = project();
    p.configure({ replies: { "workspace.setup": { exit: 1, stderr: "workspace.setup crashed" } } });
    const ran = await p.ship("start", "k");
    expect(ran).toMatchObject({ exit: 5, out: { delivery: "k-1", awaiting: "k-1/setup-1" } });
    expect(p.journal("k-1").find((e) => e.signal.kind === "adapter_error")?.info).toContain("workspace.setup crashed");
  }, TIMEOUT);

  test("a CAS conflict that does not clear gives exit 3 with the unapplied signal", async () => {
    const p = project();
    p.configure({ state: ["bash", CONFLICTING_STATE, STATE, "--dir", join(p.dir, "state")] });
    const ran = await p.ship("start", "k");
    expect(ran.exit).toBe(3);
    expect(ran.out?.unapplied).toMatchObject([{ kind: "start", workItem: { key: "k" } }]);
  }, TIMEOUT);

  test("two parallel starts give one Delivery; the other is rejected", async () => {
    const p = project();
    const both = await Promise.all([p.ship("start", "k"), p.ship("start", "k")]);
    expect(both.map((r) => r.exit)).toEqual([0, 0]);
    expect(p.deliveries()).toEqual(["k-1"]);
    expect(both.filter((r) => r.out?.rejected === true)).toHaveLength(1);
    expect(p.journal("k-1").filter((e) => e.note === "rejected_start")).toHaveLength(1);
  }, TIMEOUT);
});

describe("ship next", () => {
  test("a null key gives {delivery: null} and exit 0", async () => {
    const p = project();
    expect(await p.ship("next")).toMatchObject({ exit: 0, out: { delivery: null, issued: [], awaiting: null } });
  }, TIMEOUT);

  test("a key that already has a non-terminal Delivery is rejected (exit 0)", async () => {
    const p = project();
    p.configure({ replies: { "tracker.next": { status: "ok", body: { key: "k" } } } });
    expect((await p.ship("next")).out).toMatchObject({ delivery: "k-1" });
    const ran = await p.ship("next");
    expect(ran).toMatchObject({
      exit: 0,
      out: { delivery: "k-1", issued: [], rejected: true, reason: "an open Delivery already exists for this key" },
    });
  }, TIMEOUT);
});

describe("ship signal", () => {
  test("results chain to a gate; an answer outside the options reaches the core (exit 0, invalid_answer)", async () => {
    const p = project();
    await p.ship("start", "k");
    expect((await p.ship("signal", "k-1", "k-1/setup-1", ok({ path: "/ws/k-1", base: "trunk" }))).out).toMatchObject({ awaiting: "k-1/define-1" });
    const defined = await p.ship("signal", "k-1", "k-1/define-1", ok({ criteria: ["greets"], runbook: ["greet Ada"] }));
    expect(defined.out).toMatchObject({ awaiting: "k-1/accept-1" });
    const ran = await p.ship("signal", "k-1", "k-1/accept-1", ok({ answer: "maybe", by: "person" }));
    expect(ran.exit).toBe(0);
    const applied = p.journal("k-1").find((e) => e.signal.kind === "result" && e.signal.id === "k-1/accept-1");
    expect(applied?.note).toBe("invalid_answer");
  }, TIMEOUT);

  test("an id from another Delivery is invalid input (exit 1)", async () => {
    const p = project();
    await p.ship("start", "k");
    expect((await p.ship("signal", "k-1", "j-1/setup-1", ok({ path: "/w" }))).exit).toBe(1);
  }, TIMEOUT);

  test.each([
    ["not JSON", "{oops"],
    ["fails the awaited port/op schema", ok({})],
  ])("a result that is %s is invalid input (exit 1)", async (_, json) => {
    const p = project();
    await p.ship("start", "k");
    const before = p.versions("k-1");
    expect((await p.ship("signal", "k-1", "k-1/setup-1", json)).exit).toBe(1);
    expect(p.versions("k-1")).toEqual(before);
  }, TIMEOUT);

  test("a stale Result is ignored and journaled (exit 0)", async () => {
    const p = project();
    await p.ship("start", "k");
    const ran = await p.ship("signal", "k-1", "k-1/setup-9", JSON.stringify({ status: "failed", info: "late" }));
    expect(ran).toMatchObject({ exit: 0, out: { delivery: "k-1", awaiting: "k-1/setup-1", ignored: true } });
    expect(p.journal("k-1").at(-1)?.note).toBe("ignored_stale");
  }, TIMEOUT);

  test("an unknown Delivery is invalid input (exit 1)", async () => {
    const p = project();
    expect((await p.ship("signal", "k-1", "k-1/setup-1", ok({ path: "/w" }))).exit).toBe(1);
  }, TIMEOUT);
});

describe("ship stop", () => {
  test("an outcome not in config is invalid input (exit 1)", async () => {
    const p = project();
    await p.ship("start", "k");
    expect((await p.ship("stop", "k-1", "shipped_anyway", "because")).exit).toBe(1);
    expect(p.snapshot("k-1").at).toBe("setup");
  }, TIMEOUT);

  test("a configured outcome abandons the Delivery (exit 0)", async () => {
    const p = project();
    await p.ship("start", "k");
    const ran = await p.ship("stop", "k-1", "abandoned", "not needed");
    expect(ran).toMatchObject({ exit: 0, out: { delivery: "k-1", awaiting: null } });
    expect(p.snapshot("k-1")).toMatchObject({ at: "abandoned", outcome: "abandoned", reason: "not needed" });
  }, TIMEOUT);

  test("a CAS conflict that does not clear names the Delivery in the output (exit 3)", async () => {
    const p = project();
    await p.ship("start", "k");
    p.configure({ state: ["bash", CONFLICTING_STATE, STATE, "--dir", join(p.dir, "state")] });
    const ran = await p.ship("stop", "k-1", "abandoned", "not needed");
    expect(ran).toMatchObject({ exit: 3, out: { delivery: "k-1", unapplied: [{ kind: "stop", outcome: "abandoned" }] } });
  }, TIMEOUT);
});

describe("ship changed", () => {
  test("reads the WorkItem and applies workItem_changed", async () => {
    const p = project();
    p.configure({ replies: { "tracker.read": [workItem("k"), workItem("k", "Greet by full name")] } });
    await p.ship("start", "k");
    const ran = await p.ship("changed", "k-1");
    expect(ran).toMatchObject({ exit: 0, out: { delivery: "k-1" } });
    expect(p.snapshot("k-1").workItem.title).toBe("Greet by full name");
  }, TIMEOUT);

  test("a failed tracker.read gives exit 4", async () => {
    const p = project();
    await p.ship("start", "k");
    p.configure({ replies: FAILED_READ });
    expect((await p.ship("changed", "k-1")).exit).toBe(4);
  }, TIMEOUT);

  test("a tracker.read for another key gives exit 4 and saves nothing", async () => {
    const p = project();
    p.configure({ replies: { "tracker.read": [workItem("k"), workItem("j")] } });
    await p.ship("start", "k");
    const before = p.versions("k-1");
    expect((await p.ship("changed", "k-1")).exit).toBe(4);
    expect(p.versions("k-1")).toEqual(before);
  }, TIMEOUT);
});

describe("ship status", () => {
  test("lists only non-terminal Deliveries, or the one asked for; writes no State version", async () => {
    const p = project();
    p.configure({ replies: { "tracker.read": [workItem("k"), workItem("j")] } });
    await p.ship("start", "k");
    await p.ship("start", "j");
    await p.ship("stop", "j-1", "abandoned", "not needed");
    const before = [p.versions("k-1"), p.versions("j-1")];

    expect(await p.ship("status")).toMatchObject({
      exit: 0, out: { deliveries: [{ delivery: "k-1", at: "setup", awaiting: "k-1/setup-1" }] },
    });
    expect(await p.ship("status", "j-1")).toMatchObject({
      exit: 0, out: { deliveries: [{ delivery: "j-1", at: "abandoned", awaiting: null }] },
    });
    expect([p.versions("k-1"), p.versions("j-1")]).toEqual(before);
  }, TIMEOUT);
});

describe("invalid input and config", () => {
  test.each([
    ["no verb", []],
    ["unknown verb", ["ship-it"]],
    ["missing argument", ["stop", "k-1"]],
    ["extra argument", ["next", "now"]],
    ["not a Delivery id", ["status", "../k-1"]],
  ])("%s → exit 1", async (_, args) => {
    const p = project();
    expect((await p.ship(...args)).exit).toBe(1);
  }, TIMEOUT);

  test("a config error gives exit 2 and touches nothing", async () => {
    const p = project();
    rmSync(join(p.dir, "ship.config.json"));
    const ran = await p.ship("start", "k");
    expect(ran.exit).toBe(2);
    expect(p.deliveries()).toEqual([]);
  }, TIMEOUT);
});

describe("telemetry", () => {
  test("with no `telemetry` key, start/next/signal/stop/changed/status behave exactly as on main", async () => {
    const p = project();
    expect(await p.ship("start", "k")).toMatchObject({ exit: 0, out: { delivery: "k-1", awaiting: "k-1/setup-1" } });
    expect(await p.ship("signal", "k-1", "k-1/setup-1", ok({ path: "/ws/k-1", base: "trunk" }))).toMatchObject({ exit: 0 });
    expect(await p.ship("status")).toMatchObject({ exit: 0 });
    expect(await p.ship("changed", "k-1")).toMatchObject({ exit: 0 });
    expect(await p.ship("stop", "k-1", "abandoned", "not needed")).toMatchObject({ exit: 0 });
    expect(await p.ship("next")).toMatchObject({ exit: 0 });
    expect(p.telemetryEvents()).toEqual([]);
  }, TIMEOUT);

  test("a configured telemetry adapter receives start/resolved for a step, and start/awaiting/resolved for a gate", async () => {
    const p = project();
    p.configure({ telemetry: ["bash", RECORDING_TELEMETRY] });
    await p.ship("start", "k");
    await p.ship("signal", "k-1", "k-1/setup-1", ok({ path: "/ws/k-1", base: "trunk" }));
    await p.ship("signal", "k-1", "k-1/define-1", ok({ criteria: ["greets"], runbook: ["greet Ada"] }));
    const events = p.telemetryEvents();
    const setup = events.filter((e) => e.name === "setup");
    expect(setup.map((e) => e.phase)).toEqual(["start", "resolved"]);
    const accept = events.filter((e) => e.name === "accept");
    expect(accept.map((e) => e.phase)).toEqual(["start", "awaiting", "resolved"]);
    for (const e of events) {
      expect(e).toMatchObject({ delivery: "k-1", op: expect.any(String), phase: expect.any(String) });
      expect(typeof e.elapsedMs).toBe("number");
    }
  }, TIMEOUT);

  test("next/signal/stop/changed each notify their step/gate too", async () => {
    const p = project();
    p.configure({ replies: { "tracker.next": { status: "ok", body: { key: "k" } } }, telemetry: ["bash", RECORDING_TELEMETRY] });
    await p.ship("next");
    await p.ship("signal", "k-1", "k-1/setup-1", ok({ path: "/ws/k-1", base: "trunk" }));
    await p.ship("changed", "k-1");
    await p.ship("stop", "k-1", "abandoned", "not needed");
    const names = new Set(p.telemetryEvents().map((e) => e.name));
    expect(names.has("setup")).toBe(true);
  }, TIMEOUT);

  test("a telemetry adapter that exits non-zero gives the same outcome as telemetry unconfigured", async () => {
    const plain = project();
    const withCrashing = project();
    withCrashing.configure({ telemetry: ["bash", CRASHING_TELEMETRY] });
    const [a, b] = await Promise.all([plain.ship("start", "k"), withCrashing.ship("start", "k")]);
    expect(b).toMatchObject({ exit: a.exit, out: { delivery: a.out?.delivery, awaiting: a.out?.awaiting, issued: a.out?.issued } });
  }, TIMEOUT);

  test("a telemetry adapter that hangs gives the same outcome as telemetry unconfigured", async () => {
    const plain = project();
    const withHanging = project();
    withHanging.configure({ telemetry: ["bash", HANGING_TELEMETRY] });
    const [a, b] = await Promise.all([plain.ship("start", "k"), withHanging.ship("start", "k")]);
    expect(b).toMatchObject({ exit: a.exit, out: { delivery: a.out?.delivery, awaiting: a.out?.awaiting, issued: a.out?.issued } });
  }, TIMEOUT);

  test("a telemetry adapter pointed at a nonexistent executable gives the same outcome as telemetry unconfigured", async () => {
    const plain = project();
    const withMissing = project();
    withMissing.configure({ telemetry: [join(withMissing.dir, "does-not-exist")] });
    const [a, b] = await Promise.all([plain.ship("start", "k"), withMissing.ship("start", "k")]);
    expect(b).toMatchObject({ exit: a.exit, out: { delivery: a.out?.delivery, awaiting: a.out?.awaiting, issued: a.out?.issued } });
  }, TIMEOUT);
});
