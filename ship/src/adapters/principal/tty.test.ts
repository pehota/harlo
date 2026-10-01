// M0.20 (sync transport): the terminal Principal, driven as an executable attached to a REAL pty
// (test/fixtures/pty-harness.py) -- not a pipe, not a mock -- so its /dev/tty reads and writes are exercised for
// real. Covers exact-name match, alias match, ambiguous re-prompt, comment attachment, and the open-ended
// (no-options) case, plus notify/cancel.
import { describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { join } from "node:path";
import type { Decide, GateEvidence, Stdin } from "../../../src/contracts/common";
import type { AskPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { runPty, type Turn } from "../../../test/fixtures/pty";

const ROOT = join(import.meta.dir, "..", "..", "..");
const ADAPTER = join(import.meta.dir, "tty.ts");
const ajv = new Ajv();

const workItem = { key: "k", title: "Greet by name", body: "Say hello.", url: "https://tracker.example/k" };
const evidence: GateEvidence = {
  workItem, criteria: ["greets Ada"], runbook: ["run greet Ada"], changeset: "abc123",
  findings: [{ text: "no test for empty name", ref: "greet.ts:3" }],
  evidence: [{ label: "plan", url: "file:///ws/k-1/plan.md" }], note: "workItem changed",
};

/** Run `tty.ts principal <op>` with a Stdin envelope, feeding `turns` to its /dev/tty. */
const call = async (op: string, id: string, payload: unknown, turns: Turn[] = []): Promise<{ stdout: unknown; printed: string }> => {
  const stdin: Stdin = { id, delivery: "k-1", port: "principal", op, workItem, workspace: "/ws/k-1", payload, tools: [] };
  const ran = await runPty(["bun", ADAPTER, "principal", op], JSON.stringify(stdin), { cwd: ROOT, turns });
  const stdout: unknown = JSON.parse(ran.stdout);
  if (!ajv.validate(schemaFor("principal", op)!.stdout, stdout)) throw new Error(`stdout breaks the contract: ${ran.stdout}`);
  return { stdout, printed: ran.ptyOutput };
};

const ok = (answer: string, comment?: string) => ({ status: "ok", body: { answer, by: "person", ...(comment === undefined ? {} : { comment }) } });

describe("principal/tty", () => {
  test("decide: exact option name matches, prints the gate and evidence, returns ok synchronously", async () => {
    const payload: Decide = { on: "land", options: ["approve", "rework", "rescope"], min: "person", evidence };
    const { stdout, printed } = await call("decide", "k-1/land-1", payload, [{ wait: "Answer with one of:", send: "rescope\n" }]);
    expect(stdout).toEqual(ok("rescope"));
    for (const text of ["land", "approve", "rework", "rescope", "Greet by name", "https://tracker.example/k", "greets Ada",
      "run greet Ada", "abc123", "no test for empty name", "greet.ts:3", "plan", "file:///ws/k-1/plan.md", "workItem changed"]) {
      expect(printed).toContain(text);
    }
  });

  test("decide: an alias picks the option of matching polarity", async () => {
    const payload: Decide = { on: "land", options: ["approve", "rework"], min: "person", evidence };
    const { stdout } = await call("decide", "k-1/land-1", payload, [{ wait: "Answer with one of:", send: "lgtm\n" }]);
    expect(stdout).toEqual(ok("approve"));
  });

  test("decide: an unclear reply re-prompts instead of failing", async () => {
    const payload: Decide = { on: "land", options: ["approve", "rework"], min: "person", evidence };
    const { stdout, printed } = await call("decide", "k-1/land-1", payload, [
      { wait: "Answer with one of:", send: "maybe later\n" },
      { wait: "unclear reply", send: "approve\n" },
    ]);
    expect(stdout).toEqual(ok("approve"));
    expect(printed).toContain("unclear reply");
  });

  test("decide: trailing text after the option becomes a comment", async () => {
    const payload: Decide = { on: "land", options: ["approve", "rework"], min: "person", evidence };
    const { stdout } = await call("decide", "k-1/land-1", payload, [
      { wait: "Answer with one of:", send: "approve, ship it once CI is green\n" },
    ]);
    expect(stdout).toEqual(ok("approve", "ship it once CI is green"));
  });

  test("ask: a comment is refused, not silently attached, since AskBody carries none", async () => {
    const payload: AskPayload = { prompt: "Which greeting?", min: "person", options: ["formal", "casual"], evidence };
    const { stdout, printed } = await call("ask", "k-1/ask-1", payload, [
      { wait: "Answer with one of:", send: "casual, why not\n" },
      { wait: "does not accept a comment", send: "casual\n" },
    ]);
    expect(stdout).toEqual({ status: "ok", body: { answer: "casual", by: "person" } });
    expect(printed).toContain("does not accept a comment");
  });

  test("ask without options: the whole reply is the answer, no matching", async () => {
    const payload: AskPayload = { prompt: "Which port?", min: "person", evidence };
    const { stdout } = await call("ask", "k-1/ask-2", payload, [
      { wait: "Answer (type your reply):", send: "the deploy port\n" },
    ]);
    expect(stdout).toEqual({ status: "ok", body: { answer: "the deploy port", by: "person" } });
  });

  test("notify prints the text and returns ok without blocking for a reply", async () => {
    const { stdout, printed } = await call("notify", "k-1/notify-1", { text: "closed: delivered" });
    expect(stdout).toEqual({ status: "ok", body: {} });
    expect(printed).toContain("closed: delivered");
  });

  test("cancel prints that the target is withdrawn and returns ok", async () => {
    const { stdout, printed } = await call("cancel", "k-1/cancel-1", { target: "k-1/accept-1" });
    expect(stdout).toEqual({ status: "ok", body: {} });
    expect(printed).toContain("withdrawn");
    expect(printed).toContain("k-1/accept-1");
  });
});
