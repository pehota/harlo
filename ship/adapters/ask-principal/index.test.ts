// M1.7: the ask-principal adapter, driven as an executable. It serves both `deploy` and `verify`: a manual gate
// standing in for a real deploy/verify system by asking the Principal directly.
import { describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../src/contracts/common";
import type { DeployPayload, VerifyPayload } from "../../src/contracts/ports";
import { schemaFor } from "../../src/contracts/ports";

const ADAPTER = join(import.meta.dir, "index.ts");
const ajv = new Ajv();

const workItem: WorkItem = { key: "k", title: "Greet by name", body: "Say hello." };

/** Run `ask-principal/index.ts <port> <op>` with a Stdin envelope, as the Runner does. */
const call = async (port: "deploy" | "verify", op: string, payload: unknown): Promise<{ exit: number; stdout: unknown }> => {
  const stdin: Stdin = { id: "k-1/run-1", delivery: "k-1", port, op, workItem, workspace: "/ws/k-1", payload, tools: [] };
  const proc = Bun.spawn(["bun", ADAPTER, port, op], {
    stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe",
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" },
  });
  const [text, exit] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const stdout: unknown = JSON.parse(text);
  if (!ajv.validate(schemaFor(port, op)!.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  return { exit, stdout };
};

describe("ask-principal", () => {
  test("deploy: no answer asks live/not_live", async () => {
    const payload: DeployPayload = { changeset: "ship/k-1@abc" };
    const ran = await call("deploy", "run", payload);
    expect(ran).toMatchObject({
      exit: 0,
      stdout: { status: "question", about: "manual", options: ["live", "not_live"] },
    });
  });

  test("deploy: answer live returns ok verdict live", async () => {
    const payload: DeployPayload = { changeset: "ship/k-1@abc", answer: "live" };
    const ran = await call("deploy", "run", payload);
    expect(ran).toEqual({ exit: 0, stdout: { status: "ok", body: { verdict: "live" } } });
  });

  test("deploy: answer not_live returns ok verdict not_live with findings", async () => {
    const payload: DeployPayload = { changeset: "ship/k-1@abc", answer: "not_live" };
    const ran = await call("deploy", "run", payload);
    expect(ran).toEqual({
      exit: 0,
      stdout: { status: "ok", body: { verdict: "not_live", findings: [{ text: "not_live" }] } },
    });
  });

  test("verify: no answer asks pass/fail", async () => {
    const payload: VerifyPayload = { runbook: ["run greet Ada"] };
    const ran = await call("verify", "run", payload);
    expect(ran).toMatchObject({
      exit: 0,
      stdout: { status: "question", about: "manual", options: ["pass", "fail"] },
    });
  });

  test("verify: answer pass returns ok verdict pass", async () => {
    const payload: VerifyPayload = { runbook: ["run greet Ada"], answer: "pass" };
    const ran = await call("verify", "run", payload);
    expect(ran).toEqual({ exit: 0, stdout: { status: "ok", body: { verdict: "pass" } } });
  });

  test("verify: answer fail returns ok verdict fail with findings", async () => {
    const payload: VerifyPayload = { runbook: ["run greet Ada"], answer: "fail" };
    const ran = await call("verify", "run", payload);
    expect(ran).toEqual({
      exit: 0,
      stdout: { status: "ok", body: { verdict: "fail", findings: [{ text: "fail" }] } },
    });
  });

  test("cancel is a no-op ok for either port", async () => {
    const ran = await call("deploy", "cancel", { target: "k-1/run-1" });
    expect(ran).toEqual({ exit: 0, stdout: { status: "ok", body: {} } });
  });
});
