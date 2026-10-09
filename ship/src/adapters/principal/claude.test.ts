// Model Principal, driven as an executable against a fake `claude` CLI (reuses adapters/agent/claude/fake.ts,
// injected via --agent-bin, same as agent/claude/index.test.ts): proves decide/ask/notify/cancel each resolve
// with no human interaction — the whole point of an unattended queue.
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { CommentRoute, Decide, GateEvidence, Stdin } from "../../../src/contracts/common";
import type { AskPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";

const ADAPTER = join(import.meta.dir, "claude.ts");
const FAKE = join(import.meta.dir, "..", "agent", "claude", "fake.ts");
const ajv = new Ajv();

const dirs: string[] = [];
const tempDir = (prefix: string): string => {
  const dir = mkdtempSync(join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const workItem = { key: "k", title: "Greet by name", body: "Say hello.", url: "https://tracker.example/k" };
const evidence: GateEvidence = {
  workItem, requirements: { criteria: ["greets Ada"], runbook: ["run greet Ada"] }, changeset: "abc123",
  findings: [{ text: "no test for empty name", ref: "greet.ts:3" }],
  evidence: [{ label: "plan", url: "file:///ws/k-1/plan.md" }], note: "workItem changed",
};

type Reply = { is_error: boolean; result: string; structured_output?: unknown; exitCode?: number };

const repliesFile = (dir: string, replies: Reply | Reply[]): string => {
  const file = join(dir, "replies.json");
  writeFileSync(file, JSON.stringify({ replies }));
  return file;
};

/** Run `principal/claude.ts --agent-bin <fake> [--agent-arg=<token>]... principal <op>` with a Stdin envelope, as
 *  the Runner does. `log`, when given, is where the fake CLI's own argv (the real `-p <prompt>` text included)
 *  is captured — for a test asserting what the adapter put in the prompt, not just what it returned. */
const call = async (
  op: string, payload: unknown, reply: Reply | Reply[], log?: string, agentArgs?: string[],
): Promise<{ exitCode: number; stdout: unknown; stderr: string }> => {
  const dir = tempDir("ship-principal-claude-");
  const stdin: Stdin = { id: "k-1/land-1", delivery: "k-1", port: "principal", op, workItem, workspace: "/ws/k-1", payload, tools: [] };
  const agentArgArgs = (agentArgs ?? []).map((token) => `--agent-arg=${token}`);
  const proc = Bun.spawn(["bun", ADAPTER, "--agent-bin", FAKE, ...agentArgArgs, "principal", op], {
    stdin: new Blob([JSON.stringify(stdin)]),
    cwd: dir,
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, FAKE_AGENT_REPLIES: repliesFile(dir, reply), ...(log ? { FAKE_AGENT_LOG: log } : {}) },
  });
  const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  const exitCode = await proc.exited;
  return { exitCode, stdout: JSON.parse(stdout.trim()), stderr };
};

/** The `-p` prompt text the adapter sent the CLI for this decide. */
const decidePromptOf = async (payload: Decide, reply: Reply): Promise<string> => {
  const log = join(tempDir("ship-principal-claude-log-"), "log.jsonl");
  await call("decide", payload, reply, log);
  const argv = JSON.parse(readFileSync(log, "utf8").trim().split("\n")[0]!) as string[];
  return argv[argv.indexOf("-p") + 1]!;
};

const LAND: Record<string, CommentRoute> = {
  approve: { goes: "dropped" }, rework: { goes: "feedback", to: "implement" }, rescope: { goes: "feedback", to: "define" },
};
const land = (options: string[]): Decide => ({ on: "land", options, comments: LAND, min: "model", evidence });

describe("principal/claude", () => {
  test("decide: the CLI's structured answer becomes the gate's reply, by model", async () => {
    const payload = land(["approve", "rework", "rescope"]);
    const { exitCode, stdout } = await call("decide", payload, {
      is_error: false, result: "", structured_output: { answer: "rescope" },
    });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "ok", body: { answer: "rescope", by: "model" } });
    expect(ajv.validate(schemaFor("principal", "decide")!.stdout, stdout)).toBe(true);
  });

  test("decide: a comment is kept only when the chosen option's route carries one", async () => {
    const payload = land(["approve", "rework"]);
    const { stdout } = await call("decide", payload, {
      is_error: false, result: "", structured_output: { answer: "rework", comment: "tests are missing" },
    });
    expect(stdout).toEqual({ status: "ok", body: { answer: "rework", by: "model", comment: "tests are missing" } });
  });

  test("decide: the prompt names which answers keep a comment and where it goes", async () => {
    const payload = land(["approve", "rework", "rescope"]);
    const prompt = await decidePromptOf(payload, { is_error: false, result: "", structured_output: { answer: "approve" } });
    expect(prompt).toContain("It is kept only with: rework (sent to implement as a directive), rescope (sent to define as a directive).");
    expect(prompt).not.toContain("approve (");
  });

  test("decide: a reason route is named as the recorded reason", async () => {
    const payload: Decide = {
      on: "decision", options: ["keep_going", "accept", "stop"], min: "model", evidence,
      comments: { keep_going: { goes: "feedback", to: "implement" }, accept: { goes: "dropped" }, stop: { goes: "reason" } },
    };
    const prompt = await decidePromptOf(payload, { is_error: false, result: "", structured_output: { answer: "stop" } });
    expect(prompt).toContain("stop (recorded as the reason)");
  });

  test("decide: blocked at Implement, retry's comment is named as a directive to implement (harlo-62)", async () => {
    const payload: Decide = {
      on: "blocked", options: ["retry", "stop"], min: "model", evidence,
      comments: { retry: { goes: "feedback", to: "implement" }, stop: { goes: "reason" } },
    };
    const prompt = await decidePromptOf(payload, { is_error: false, result: "", structured_output: { answer: "retry" } });
    expect(prompt).toContain("It is kept only with: retry (sent to implement as a directive), stop (recorded as the reason).");
  });

  test("decide: no comment line when every option's route is dropped", async () => {
    const prompt = await decidePromptOf(land(["approve"]), { is_error: false, result: "", structured_output: { answer: "approve" } });
    expect(prompt).not.toContain("It is kept only with");
  });

  test("decide: a comment on a dropped-route option is not forwarded", async () => {
    const payload = land(["approve", "rework"]);
    const { stdout } = await call("decide", payload, {
      is_error: false, result: "", structured_output: { answer: "approve", comment: "looks fine" },
    });
    expect(stdout).toEqual({ status: "ok", body: { answer: "approve", by: "model" } });
  });

  test("decide: an off-list answer fails (no side effect), never forwarded as if valid", async () => {
    const payload = land(["approve", "rework"]);
    const { stdout } = await call("decide", payload, {
      is_error: false, result: "", structured_output: { answer: "not-an-option" },
    });
    expect((stdout as { status: string }).status).toBe("failed");
  });

  test("decide: the evidence's note (e.g. a blocked-retry attempt count) reaches the CLI's prompt verbatim", async () => {
    const dir = tempDir("ship-principal-claude-log-");
    const log = join(dir, "log.jsonl");
    const payload: Decide = { ...land(["approve", "rework"]), evidence: { ...evidence, note: "This is retry attempt 3 at this gate." } };
    await call("decide", payload, { is_error: false, result: "", structured_output: { answer: "rework" } }, log);
    const [prompt] = (JSON.parse(readFileSync(log, "utf8").trim()) as string[]).slice(1, 2);
    expect(prompt).toContain("Note: This is retry attempt 3 at this gate.");
  });

  test("decide: an is_error CLI reply fails, never crashes (nothing has changed yet)", async () => {
    const payload = land(["approve", "rework"]);
    const { exitCode, stdout } = await call("decide", payload, { is_error: true, result: "auth failed" });
    expect(exitCode).toBe(0);
    expect((stdout as { status: string }).status).toBe("failed");
  });

  test("ask: the CLI's answer is returned by model, with no comment field at all", async () => {
    const payload: AskPayload = { prompt: "which env?", min: "model", options: ["staging", "prod"], evidence };
    const { stdout } = await call("ask", payload, { is_error: false, result: "", structured_output: { answer: "staging" } });
    expect(stdout).toEqual({ status: "ok", body: { answer: "staging", by: "model" } });
    expect(ajv.validate(schemaFor("principal", "ask")!.stdout, stdout)).toBe(true);
  });

  test("ask: open-ended (no options) accepts free text from the CLI", async () => {
    const payload: AskPayload = { prompt: "describe the risk", min: "model", evidence };
    const { stdout } = await call("ask", payload, { is_error: false, result: "", structured_output: { answer: "low risk, cosmetic only" } });
    expect(stdout).toEqual({ status: "ok", body: { answer: "low risk, cosmetic only", by: "model" } });
  });

  test("notify: acks ok without calling the CLI at all", async () => {
    const { exitCode, stdout } = await call("notify", { text: "closed: delivered" }, { is_error: true, result: "should never run" });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "ok", body: {} });
  });

  test("cancel: acks ok without calling the CLI at all", async () => {
    const { stdout } = await call("cancel", { target: "k-1/land-1" }, { is_error: true, result: "should never run" });
    expect(stdout).toEqual({ status: "ok", body: {} });
  });

  test("harlo-64: decide forwards --agent-arg=--plugin-dir entries to the agent bin, in order", async () => {
    const dir = tempDir("ship-principal-claude-log-");
    const log = join(dir, "log.jsonl");
    const payload = land(["approve", "rework"]);
    await call("decide", payload, { is_error: false, result: "", structured_output: { answer: "approve" } }, log, ["--plugin-dir=/a/dod", "--plugin-dir=/b/other"]);
    const argv = JSON.parse(readFileSync(log, "utf8").trim().split("\n")[0]!) as string[];
    expect(argv.filter((a) => a === "--plugin-dir")).toHaveLength(2);
    expect(argv[argv.indexOf("--plugin-dir") + 1]).toBe("/a/dod");
    expect(argv[argv.lastIndexOf("--plugin-dir") + 1]).toBe("/b/other");
  });

  test("harlo-64: ask forwards an --agent-arg=--plugin-dir entry to the agent bin", async () => {
    const dir = tempDir("ship-principal-claude-log-");
    const log = join(dir, "log.jsonl");
    const payload: AskPayload = { prompt: "which env?", min: "model", options: ["staging", "prod"], evidence };
    await call("ask", payload, { is_error: false, result: "", structured_output: { answer: "staging" } }, log, ["--plugin-dir=/a/dod"]);
    const argv = JSON.parse(readFileSync(log, "utf8").trim().split("\n")[0]!) as string[];
    expect(argv.filter((a) => a === "--plugin-dir")).toHaveLength(1);
    expect(argv[argv.indexOf("--plugin-dir") + 1]).toBe("/a/dod");
  });

  test("harlo-64: decide with no --agent-arg passes exactly the protocol part + the isolation set, no --safe-mode", async () => {
    const dir = tempDir("ship-principal-claude-log-");
    const log = join(dir, "log.jsonl");
    const payload = land(["approve", "rework"]);
    await call("decide", payload, { is_error: false, result: "", structured_output: { answer: "approve" } }, log);
    const argv = JSON.parse(readFileSync(log, "utf8").trim().split("\n")[0]!) as string[];
    expect(argv).toEqual([
      "-p", argv[1]!, "--output-format", "json", "--json-schema", argv[argv.indexOf("--json-schema") + 1]!,
      "--setting-sources", "project", "--settings", '{"disableAllHooks":true}', "--strict-mcp-config",
      "--mcp-config", '{"mcpServers":{}}', "--permission-mode", "bypassPermissions",
    ]);
  });

  test("harlo-64: --agent-arg ahead of port/op does not get absorbed into positional parsing", async () => {
    const payload = land(["approve", "rework"]);
    const { exitCode, stdout } = await call(
      "decide", payload, { is_error: false, result: "", structured_output: { answer: "approve" } }, undefined, ["--plugin-dir=/a/dod"],
    );
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "ok", body: { answer: "approve", by: "model" } });
  });
});

describe("principal/claude adapter: startup flags (harlo-64)", () => {
  for (const [name, flags, named] of [
    ["a protected --agent-arg", ["--agent-arg=--json-schema={}"], "--json-schema"],
    ["a protected --verbose", ["--agent-arg=--verbose"], "--verbose"],
    ["a protected --continue", ["--agent-arg=--continue"], "--continue"],
    ["a protected --session-id", ["--agent-arg=--session-id=x"], "--session-id"],
    ["a protected --fork-session", ["--agent-arg=--fork-session"], "--fork-session"],
    ["a protected --input-format", ["--agent-arg=--input-format=stream-json"], "--input-format"],
    ["the removed adapter --plugin-dir option", ["--plugin-dir", "/a/dod"], "--plugin-dir"],
  ] as const) {
    test(`harlo-64: ${name} fails at startup, naming it`, async () => {
      const dir = tempDir("ship-principal-claude-");
      const log = join(dir, "log.jsonl");
      const proc = Bun.spawn(["bun", ADAPTER, "--agent-bin", FAKE, ...flags, "principal", "decide"], {
        stdin: new Blob(["{}"]), cwd: dir, stdout: "pipe", stderr: "pipe",
        env: { ...process.env, FAKE_AGENT_REPLIES: repliesFile(dir, { is_error: true, result: "never" }), FAKE_AGENT_LOG: log },
      });
      const [stdout, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
      expect(exitCode).toBe(2);
      expect(stdout).toBe("");
      expect(stderr).toContain(named);
      expect(existsSync(log)).toBe(false);
    });
  }
});
