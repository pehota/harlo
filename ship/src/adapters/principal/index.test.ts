// M0.20: the terminal Principal, driven as an executable. The paste-ready lines are run through bash to prove
// they quote safely and carry a Result the CLI accepts.
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Decide, GateEvidence, Stdin } from "../../../src/contracts/common";
import type { AskPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";

const ADAPTER = join(import.meta.dir, "index.ts");
const ajv = new Ajv();

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const workItem = { key: "k", title: "Greet by name", body: "Say hello.", url: "https://tracker.example/k" };
const evidence: GateEvidence = {
  workItem, criteria: ["greets Ada"], runbook: ["run greet Ada"], changeset: "abc123",
  findings: [{ text: "no test for empty name", ref: "greet.ts:3" }],
  evidence: [{ label: "plan", url: "file:///ws/k-1/plan.md" }], note: "workItem changed",
};

type Out = { exit: number; stdout: unknown; printed: string };

/** Run `principal/index.ts --out <file> principal <op>` with a Stdin envelope. */
const call = async (op: string, id: string, payload: unknown): Promise<Out> => {
  const dir = mkdtempSync(join(tmpdir(), "ship-principal-"));
  dirs.push(dir);
  const out = join(dir, "tty");
  const stdin: Stdin = { id, delivery: "k-1", port: "principal", op, workItem, workspace: "/ws/k-1", payload, tools: [] };
  const proc = Bun.spawn(["bun", ADAPTER, "--out", out, "principal", op], {
    stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe",
    env: { PATH: process.env.PATH ?? "", HOME: dir },
  });
  const [text, exit] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const stdout: unknown = JSON.parse(text);
  if (!ajv.validate(schemaFor("principal", op)!.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  return { exit, stdout, printed: readFileSync(out, "utf8") };
};

/** Each printed `ship signal …` line, run by bash with `ship` echoing its arguments: [delivery, id, result]. */
const pasted = (printed: string): [string, string, unknown][] =>
  printed.split("\n").filter((line) => line.trimStart().startsWith("ship signal ")).map((line) => {
    const echo = `ship() { printf '%s\\0' "$@"; }; ${line}`;
    const args = Bun.spawnSync(["bash", "-c", echo]).stdout.toString().split("\0").slice(0, -1);
    expect(args[0]).toBe("signal");
    return [args[1]!, args[2]!, JSON.parse(args[3]!)];
  });

const answer = (text: string) => ({ status: "ok", body: { answer: text, by: "person" } });

describe("principal/index", () => {
  test("decide prints the gate, options and evidence, one paste-ready line per option, and accepts", async () => {
    const payload: Decide = { on: "land", options: ["approve", "rework", "rescope"], min: "person", evidence };
    const ran = await call("decide", "k-1/land-1", payload);
    expect(ran).toMatchObject({ exit: 0, stdout: { status: "accepted" } });
    for (const text of ["land", "approve", "rework", "rescope", "Greet by name", "https://tracker.example/k", "greets Ada",
      "run greet Ada", "abc123", "no test for empty name", "greet.ts:3", "plan", "file:///ws/k-1/plan.md", "workItem changed"]) {
      expect(ran.printed).toContain(text);
    }
    const lines = pasted(ran.printed);
    expect(lines).toEqual(["approve", "rework", "rescope"].map((o) => ["k-1", "k-1/land-1", answer(o)]));
    for (const [, , result] of lines) expect(ajv.validate(schemaFor("principal", "decide")!.result, result)).toBe(true);
  });

  test("ask prints the prompt, and quotes options holding shell characters safely", async () => {
    const options = ["it's fine", "$(rm -rf ~) `x` \"y\""];
    const payload: AskPayload = { prompt: "Which greeting?", min: "person", options, evidence };
    const ran = await call("ask", "k-1/ask-1", payload);
    expect(ran.stdout).toEqual({ status: "accepted" });
    expect(ran.printed).toContain("Which greeting?");
    expect(pasted(ran.printed)).toEqual(options.map((o) => ["k-1", "k-1/ask-1", answer(o)]));
  });

  test("ask without options prints one line with a placeholder answer", async () => {
    const ran = await call("ask", "k-1/ask-2", { prompt: "Which port?", min: "person", evidence } satisfies AskPayload);
    const lines = pasted(ran.printed);
    expect(lines).toHaveLength(1);
    expect(lines[0]).toEqual(["k-1", "k-1/ask-2", answer("…")]);
  });

  test("notify prints the text and returns ok", async () => {
    const ran = await call("notify", "k-1/notify-1", { text: "closed: delivered" });
    expect(ran).toMatchObject({ exit: 0, stdout: { status: "ok", body: {} } });
    expect(ran.printed).toContain("closed: delivered");
  });

  test("cancel prints that the target is withdrawn and returns ok", async () => {
    const ran = await call("cancel", "k-1/cancel-1", { target: "k-1/accept-1" });
    expect(ran).toMatchObject({ exit: 0, stdout: { status: "ok", body: {} } });
    expect(ran.printed).toContain("withdrawn");
    expect(ran.printed).toContain("k-1/accept-1");
  });
});
