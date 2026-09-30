// M0.19: the scripted fake adapter, driven as an executable, one process per call as the Runner does.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const FAKE = join(import.meta.dir, "fake.ts");

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

type Out = { exit: number; stdout: unknown; stderr: string };

/** A script in a temp dir, and a `call(port, op, payload)` that runs the fake on it. */
const scripted = (replies: Record<string, unknown>) => {
  const dir = mkdtempSync(join(tmpdir(), "ship-fake-"));
  dirs.push(dir);
  const script = join(dir, "script.json");
  writeFileSync(script, JSON.stringify({ replies }));

  const call = async (port: string, op: string, payload: unknown = {}): Promise<Out> => {
    const stdin = { id: null, delivery: null, port, op, workItem: null, workspace: null, payload, tools: [] };
    const proc = Bun.spawn(["bun", FAKE, "--script", script, port, op], {
      stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe",
      env: { PATH: process.env.PATH ?? "", HOME: dir },
    });
    const [text, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    return { exit, stdout: text.trim() ? JSON.parse(text) : null, stderr };
  };
  const log = (): { port: string; op: string; payload: unknown }[] =>
    readFileSync(`${script}.stdin.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
  return { call, log };
};

const ok = (body: unknown) => ({ status: "ok", body });

describe("fake adapter", () => {
  test("the nth call of a port/op returns the nth scripted stdout; each port/op counts on its own", async () => {
    const fake = scripted({ "define.run": [ok({ n: 1 }), ok({ n: 2 })], "check.run": [ok({ c: 1 })] });
    expect((await fake.call("define", "run")).stdout).toEqual(ok({ n: 1 }));
    expect((await fake.call("check", "run")).stdout).toEqual(ok({ c: 1 }));
    expect((await fake.call("define", "run")).stdout).toEqual(ok({ n: 2 }));
  });

  test.each([
    ["an unscripted port/op", {}],
    ["an exhausted list", { "define.run": [] }],
  ])("%s accepts", async (_, replies) => {
    expect(await scripted(replies).call("define", "run")).toMatchObject({ exit: 0, stdout: { status: "accepted" } });
  });

  test("a single scripted stdout (not a list) answers every call", async () => {
    const fake = scripted({ "tracker.next": ok({ key: null }) });
    const both = [await fake.call("tracker", "next"), await fake.call("tracker", "next")];
    expect(both.map((o) => o.stdout)).toEqual([ok({ key: null }), ok({ key: null })]);
  });

  test("an {exit, stderr} reply exits with that code and prints nothing", async () => {
    const fake = scripted({ "workspace.setup": [{ exit: 1, stderr: "workspace.setup crashed" }] });
    expect(await fake.call("workspace", "setup")).toMatchObject({ exit: 1, stdout: null, stderr: "workspace.setup crashed\n" });
  });

  test("parallel calls each take their own turn", async () => {
    const fake = scripted({ "tracker.read": [ok({ n: 1 }), ok({ n: 2 })] });
    const both = await Promise.all([fake.call("tracker", "read"), fake.call("tracker", "read")]);
    expect(both.map((o) => o.stdout)).toEqual(expect.arrayContaining([ok({ n: 1 }), ok({ n: 2 })]));
  });

  test("records every stdin, in call order, one JSON line each", async () => {
    const fake = scripted({});
    await fake.call("define", "run", { feedback: "shorter" });
    await fake.call("principal", "cancel", { target: "k-1/define-1" });
    expect(fake.log()).toMatchObject([
      { port: "define", op: "run", payload: { feedback: "shorter" } },
      { port: "principal", op: "cancel", payload: { target: "k-1/define-1" } },
    ]);
  });
});
