// M0.15: running an adapter and mapping what it did (plan §5.3), with the bash fixture adapter.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Port } from "../contracts/common";
import type { Command } from "../core/types";
import { D, workItem, workspace } from "../core/fixtures/builders.fixture";
import { type AdapterSpec, type Reply, processStartTime, spawnCommand } from "./spawn";

const FIXTURE = join(import.meta.dir, "fixtures", "adapter.sh");
const fixture = (...mode: string[]): AdapterSpec => ({ argv: ["bash", FIXTURE, ...mode], env: {}, tools: [] });

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-spawn-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const delivery = { delivery: D, workItem, workspace };
const setup: Command = { id: `${D}/setup-1`, port: "workspace", op: "setup", await: true, payload: {} };

/** Every port served by one spec, except the ones given. */
const adapters = (spec: AdapterSpec, over: Partial<Record<Port, AdapterSpec>> = {}): Record<Port, AdapterSpec> => ({
  define: spec, implement: spec, check: spec, integrate: spec, deploy: spec, verify: spec,
  tracker: spec, principal: spec, workspace: spec, state: spec, ...over,
});

const reply = async (spec: AdapterSpec, command: Command = setup): Promise<Reply> => {
  const spawned = spawnCommand(adapters(spec), delivery, command);
  return spawned.spawned ? await spawned.done : spawned.reply;
};

describe("§5.3 table: awaited workspace.setup", () => {
  const rows: { name: string; spec: AdapterSpec; expect: Reply | ((r: Reply) => void) }[] = [
    { name: "ok → that Result", spec: fixture("ok"),
      expect: { kind: "result", result: { status: "ok", body: { path: "/ws/k-1" } } } },
    { name: "accepted → waiting", spec: fixture("accepted"), expect: { kind: "accepted" } },
    { name: "explicit failed → that Result", spec: fixture("failed"),
      expect: { kind: "result", result: { status: "failed", info: "disk full" } } },
    { name: "invalid JSON → crash", spec: fixture("invalid_json"),
      expect: (r) => expect(r).toMatchObject({ kind: "crash", reason: expect.stringContaining("JSON") }) },
    { name: "schema-invalid body → crash", spec: fixture("schema_invalid"),
      expect: (r) => expect(r).toMatchObject({ kind: "crash", reason: expect.stringContaining("schema") }) },
    { name: "question from a service port → crash", spec: fixture("question"),
      expect: (r) => expect(r).toMatchObject({ kind: "crash" }) },
    { name: "exit 1 → crash with the stderr tail, stdout ignored", spec: fixture("exit1"),
      expect: { kind: "crash", reason: "exit 1", stderr: "boom\n" } },
    { name: "ENOENT → failed{info}, nothing ran", spec: { argv: ["ship-no-such-adapter"], env: {}, tools: [] },
      expect: (r) => expect(r).toMatchObject({ kind: "result", result: { status: "failed", info: expect.stringContaining("ship-no-such-adapter") } }) },
  ];
  test.each(rows)("$name", async ({ spec, expect: want }) => {
    const got = await reply(spec);
    if (typeof want === "function") want(got);
    else expect(got).toEqual(want);
  });

  test("ENOENT reports not spawned, so no `sent` is journaled", () => {
    const spawned = spawnCommand(adapters({ argv: ["ship-no-such-adapter"], env: {}, tools: [] }), delivery, setup);
    expect(spawned.spawned).toBe(false);
  });

  test("the stderr tail keeps the last 2 KB", async () => {
    const got = await reply(fixture("noisy"));
    if (got.kind !== "crash") throw new Error(`expected crash, got ${got.kind}`);
    expect(got.stderr.length).toBe(2048);
    expect(got.stderr.endsWith("xxEND")).toBe(true);
  });
});

describe("fire commands ignore stdout", () => {
  const notify: Command = { id: `${D}/notify-1`, port: "principal", op: "notify", await: false, payload: { text: "hi" } };
  test.each([
    { name: "exit 0 with any stdout → fired", spec: fixture("invalid_json"), expect: { kind: "fired" } },
    { name: "exit 1 → fire_error", spec: fixture("exit1"), expect: { kind: "fire_error", info: "exit 1: boom\n" } },
  ])("$name", async ({ spec, expect: want }) => {
    expect(await reply(spec, notify)).toEqual(want as Reply);
  });
  test("ENOENT → fire_error", async () => {
    expect(await reply({ argv: ["ship-no-such-adapter"], env: {}, tools: [] }, notify))
      .toMatchObject({ kind: "fire_error", info: expect.stringContaining("ship-no-such-adapter") });
  });
});

describe("process identity for the `sent` entry", () => {
  test("pid and start time are known before the adapter exits", async () => {
    const release = join(tempDir(), "release");
    const spawned = spawnCommand(adapters(fixture("wait", release)), delivery, setup);
    if (!spawned.spawned) throw new Error("not spawned");
    expect(spawned.pid).toBeGreaterThan(0);
    expect(spawned.started).not.toBe("");
    expect(spawned.started).toBe(processStartTime(spawned.pid)); // still running: same start time
    writeFileSync(release, "");
    expect(await spawned.done).toEqual({ kind: "result", result: { status: "ok", body: { path: "/ws/k-1" } } });
  });

  test("a pid that is gone has no start time", async () => {
    const spawned = spawnCommand(adapters(fixture("ok")), delivery, setup);
    if (!spawned.spawned) throw new Error("not spawned");
    await spawned.done;
    expect(processStartTime(spawned.pid)).toBe("");
  });
});

describe("env", () => {
  test("a parent secret is absent; PATH, HOME and the profile env are present", async () => {
    process.env.SHIP_TEST_PARENT_SECRET = "must-not-leak";
    try {
      const out = join(tempDir(), "env");
      const spec: AdapterSpec = { ...fixture("env", out), env: { GH_TOKEN: "from-profile" } };
      expect(await reply(spec)).toMatchObject({ kind: "result" });
      const lines = readFileSync(out, "utf8").trim().split("\n");
      const vars = Object.fromEntries(lines.map((line) => [line.slice(0, line.indexOf("=")), line.slice(line.indexOf("=") + 1)]));
      expect(vars.SHIP_TEST_PARENT_SECRET).toBeUndefined();
      expect(vars.GH_TOKEN).toBe("from-profile");
      expect(vars.PATH).toBe(process.env.PATH);
      expect(vars.HOME).toBe(process.env.HOME);
      const bashOwn = ["PWD", "SHLVL", "_", "OLDPWD"];
      expect(Object.keys(vars).filter((name) => !bashOwn.includes(name)).sort()).toEqual(["GH_TOKEN", "HOME", "PATH"]);
    } finally {
      delete process.env.SHIP_TEST_PARENT_SECRET;
    }
  });
});

describe("cancel", () => {
  test("spawns the target's port adapter with `<port> cancel` and {target}; a fire, so exit 1 is a fire_error", async () => {
    const out = join(tempDir(), "cancel");
    const implement: AdapterSpec = { ...fixture("record", out, "1"), tools: ["git"] };
    const cancel: Command = {
      id: `${D}/cancel-1`, port: "implement", op: "cancel", await: false, payload: { target: `${D}/implement-1` },
    };
    const spawned = spawnCommand(adapters(fixture("exit1"), { implement }), delivery, cancel);
    if (!spawned.spawned) throw new Error("not spawned");
    expect(await spawned.done).toEqual({ kind: "fire_error", info: "exit 1: " });
    expect(readFileSync(`${out}.argv`, "utf8")).toBe("implement\ncancel\n");
    expect(JSON.parse(readFileSync(`${out}.stdin`, "utf8"))).toEqual({
      id: `${D}/cancel-1`, delivery: D, port: "implement", op: "cancel",
      workItem, workspace, payload: { target: `${D}/implement-1` }, tools: ["git"],
    });
  });
});

describe("stdin is validated before spawning (a Runner bug guard)", () => {
  test.each([
    { name: "payload outside the port/op schema", command: { ...setup, payload: { extra: 1 } } },
    { name: "unknown op", command: { ...setup, op: "explode" } },
  ])("$name throws", ({ command }) => {
    expect(() => spawnCommand(adapters(fixture("ok")), delivery, command)).toThrow();
  });
});
