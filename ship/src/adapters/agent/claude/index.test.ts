// M1.9-M1.11: the Claude-agent adapter (define/implement/check), driven as an executable against a fake
// `claude` CLI (adapters/agent/claude/fake.ts, injected via --agent-bin), plus real temp git repos for
// implement's workspace so its `changeset` comes from a real commit, never an invented sha.
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../../../src/contracts/common";
import type { CheckPayload, DefinePayload, ImplementPayload } from "../../../../src/contracts/ports";
import { schemaFor } from "../../../../src/contracts/ports";

const ADAPTER = join(import.meta.dir, "index.ts");
const FAKE = join(import.meta.dir, "fake.ts");
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

const workItem: WorkItem = { key: "PROJ-1", title: "Greet by name", body: "Say hello to the given name." };

type Reply = {
  is_error: boolean;
  result: string;
  structured_output?: unknown;
  session_id?: string;
  exitCode?: number;
  commit?: boolean;
};

/** A fresh `<fixture-dir>/replies.json`, so the returned path is also usable as `<file>.calls` scratch space. */
const repliesFile = (fixtureDir: string, replies: Reply | Reply[]): string => {
  const file = join(fixtureDir, "replies.json");
  writeFileSync(file, JSON.stringify({ replies }));
  return file;
};

/** A real git repo with one commit on `main`, used as an implement/check workspace. */
const gitRepo = (): string => {
  const dir = tempDir("ship-agent-ws-");
  const git = (...args: string[]): void => {
    const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
    if (proc.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${proc.stderr.toString()}`);
  };
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@example.com");
  git("config", "user.name", "T");
  writeFileSync(join(dir, "README.md"), "hello\n");
  git("add", "-A");
  git("commit", "-q", "-m", "init");
  return dir;
};

const headSha = (dir: string): string => {
  const proc = Bun.spawnSync(["git", "-C", dir, "rev-parse", "HEAD"], { stdout: "pipe" });
  return proc.stdout.toString().trim();
};

type CallOpts = {
  port: "define" | "implement" | "check";
  op: string;
  payload: unknown;
  home: string;
  agentReplies: string;
  delivery?: string;
  workspace?: string | null;
  log?: string;
  pluginDirs?: string[];
};

/** Run `agent/claude/index.ts --agent-bin <fake> [--plugin-dir <dir>]... <port> <op>` with a Stdin envelope, as the Runner does. */
const call = async (opts: CallOpts): Promise<{ exitCode: number; stdout: unknown }> => {
  const delivery = opts.delivery ?? "PROJ-1-1";
  const stdin: Stdin = {
    id: `${delivery}/${opts.port}-1`, delivery, port: opts.port, op: opts.op,
    workItem, workspace: opts.workspace ?? null, payload: opts.payload, tools: [],
  };
  const pluginDirArgs = (opts.pluginDirs ?? []).flatMap((dir) => ["--plugin-dir", dir]);
  const proc = Bun.spawn(["bun", ADAPTER, "--agent-bin", FAKE, ...pluginDirArgs, opts.port, opts.op], {
    stdin: new Blob([JSON.stringify(stdin)]),
    stdout: "pipe",
    stderr: "pipe",
    env: {
      PATH: process.env.PATH ?? "",
      HOME: opts.home,
      FAKE_AGENT_REPLIES: opts.agentReplies,
      ...(opts.log ? { FAKE_AGENT_LOG: opts.log } : {}),
    },
  });
  const [text, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  let stdout: unknown;
  try { stdout = JSON.parse(text); } catch { stdout = undefined; }
  if (stdout !== undefined) {
    const contract = schemaFor(opts.port, opts.op);
    if (contract && !ajv.validate(contract.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  }
  return { exitCode, stdout };
};

const readLog = (log: string): string[][] =>
  readFileSync(log, "utf8").trim().split("\n").map((line) => JSON.parse(line) as string[]);

describe("agent-claude adapter: define", () => {
  test("run maps structured output to ok{criteria, runbook}", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "…", session_id: "sess-def-1",
      structured_output: { criteria: ["greets the given name"], runbook: ["run greet Ada"] },
    });
    const payload: DefinePayload = {};
    const { exitCode, stdout } = await call({ port: "define", op: "run", payload, home, agentReplies });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({
      status: "ok",
      body: { criteria: ["greets the given name"], runbook: ["run greet Ada"] },
      evidence: [{ label: "reasoning", text: "…" }],
    });
  });

  test("run maps a question field to question{about:'clarify'}", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "…", structured_output: { question: "Which greeting style?" },
    });
    const payload: DefinePayload = {};
    const { exitCode, stdout } = await call({ port: "define", op: "run", payload, home, agentReplies });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "question", about: "clarify", prompt: "Which greeting style?" });
  });

  test("resumes its own session on a re-issue carrying an answer, fresh on the first call", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, [
      { is_error: false, result: "r1", session_id: "sess-def-2", structured_output: { criteria: ["c"], runbook: ["r"] } },
      { is_error: false, result: "r2", session_id: "sess-def-2", structured_output: { criteria: ["c2"], runbook: ["r2"] } },
    ]);
    await call({ port: "define", op: "run", payload: {}, home, agentReplies, log });
    await call({ port: "define", op: "run", payload: { answer: "yes" } satisfies DefinePayload, home, agentReplies, log });
    const [first, second] = readLog(log);
    expect(first).not.toContain("--resume");
    expect(second).toContain("--resume");
    expect(second![second!.indexOf("--resume") + 1]).toBe("sess-def-2");
  });

  test("a resumed call sends only the answer, not the whole WorkItem again", async () => {
    // Found by dogfooding M1.12: resending the full WorkItem + instructions on top of "here's an answer"
    // reads, to a real agent, as a brand-new ambiguous request and re-triggers a confirm-first question loop
    // instead of proceeding. The resumed session already has the original task in its history.
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, [
      { is_error: false, result: "r1", session_id: "sess-def-3", structured_output: { question: "which style?" } },
      { is_error: false, result: "r2", session_id: "sess-def-3", structured_output: { criteria: ["c"], runbook: ["r"] } },
    ]);
    await call({ port: "define", op: "run", payload: {}, home, agentReplies, log });
    await call({ port: "define", op: "run", payload: { answer: "formal" } satisfies DefinePayload, home, agentReplies, log });
    const [first, second] = readLog(log);
    const prompt = (argv: string[]): string => argv[argv.indexOf("-p") + 1]!;
    expect(prompt(first!)).toContain(workItem.title);
    expect(prompt(second!)).not.toContain(workItem.title);
    expect(prompt(second!)).toContain("formal");
  });

  test("always passes --safe-mode to the agent bin", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "…", structured_output: { criteria: ["c"], runbook: ["r"] },
    });
    await call({ port: "define", op: "run", payload: {}, home, agentReplies, log });
    expect(readLog(log)[0]).toContain("--safe-mode");
  });

  test("always passes --permission-mode bypassPermissions, unconditionally", async () => {
    // Unattended calls have no person at a terminal to approve anything, so the loosest mode is always
    // correct — this is not conditional on the op the way --disallowedTools is.
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "…", structured_output: { criteria: ["c"], runbook: ["r"] },
    });
    await call({ port: "define", op: "run", payload: {}, home, agentReplies, log });
    const argv = readLog(log)[0]!;
    expect(argv[argv.indexOf("--permission-mode") + 1]).toBe("bypassPermissions");
  });

  test("forwards configured --plugin-dir entries to the agent bin, in order", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "…", structured_output: { criteria: ["c"], runbook: ["r"] },
    });
    await call({ port: "define", op: "run", payload: {}, home, agentReplies, log, pluginDirs: ["/a/dod", "/b/other"] });
    const argv = readLog(log)[0]!;
    expect(argv.filter((a) => a === "--plugin-dir")).toHaveLength(2);
    expect(argv[argv.indexOf("--plugin-dir") + 1]).toBe("/a/dod");
    expect(argv[argv.lastIndexOf("--plugin-dir") + 1]).toBe("/b/other");
  });

  test("never lets the agent edit files: --disallowedTools Edit Write NotebookEdit", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "…", structured_output: { criteria: ["c"], runbook: ["r"] },
    });
    await call({ port: "define", op: "run", payload: {}, home, agentReplies, log });
    const argv = readLog(log)[0]!;
    const at = argv.indexOf("--disallowedTools");
    expect(at).toBeGreaterThan(-1);
    expect(argv.slice(at + 1, at + 4)).toEqual(["Edit", "Write", "NotebookEdit"]);
  });
});

describe("agent-claude adapter: implement", () => {
  test("first call for a delivery reaches the fake bin with no --resume", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, { is_error: false, result: "done", commit: true, session_id: "sess-impl-1" });
    const payload: ImplementPayload = { criteria: ["c"], findings: [] };
    const { exitCode } = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies, log });
    expect(exitCode).toBe(0);
    expect(readLog(log)[0]).not.toContain("--resume");
  });

  test("passes --permission-mode bypassPermissions so headless mode doesn't silently deny its own edits", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, { is_error: false, result: "done", commit: true, session_id: "sess-impl-perm" });
    const payload: ImplementPayload = { criteria: ["c"], findings: [] };
    await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies, log });
    const argv = readLog(log)[0]!;
    expect(argv[argv.indexOf("--permission-mode") + 1]).toBe("bypassPermissions");
  });

  test("commits in the workspace and returns ok{changeset: ship/<d>@<sha>} from a real commit", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, { is_error: false, result: "done", commit: true, session_id: "sess-impl-2" });
    const payload: ImplementPayload = { criteria: ["c"], findings: [] };
    const { exitCode, stdout } = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({
      status: "ok",
      body: { changeset: `ship/PROJ-1-1@${headSha(ws)}` },
      evidence: [{ label: "reasoning", text: "done" }],
    });
  });

  test("a re-issue with findings resumes this delivery's own stored session", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, [
      { is_error: false, result: "r1", commit: true, session_id: "sess-impl-3" },
      { is_error: false, result: "r2", commit: true, session_id: "sess-impl-3" },
    ]);
    await call({
      port: "implement", op: "run", payload: { criteria: ["c"], findings: [] } satisfies ImplementPayload,
      home, workspace: ws, agentReplies, log,
    });
    await call({
      port: "implement", op: "run",
      payload: { criteria: ["c"], findings: [{ text: "fix this" }] } satisfies ImplementPayload,
      home, workspace: ws, agentReplies, log,
    });
    const [first, second] = readLog(log);
    expect(first).not.toContain("--resume");
    expect(second).toContain("--resume");
    expect(second![second!.indexOf("--resume") + 1]).toBe("sess-impl-3");
  });

  test("a resumed call sends only the findings/answer, not the whole WorkItem again", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, [
      { is_error: false, result: "r1", commit: true, session_id: "sess-impl-4" },
      { is_error: false, result: "r2", commit: true, session_id: "sess-impl-4" },
    ]);
    await call({
      port: "implement", op: "run", payload: { criteria: ["c"], findings: [] } satisfies ImplementPayload,
      home, workspace: ws, agentReplies, log,
    });
    await call({
      port: "implement", op: "run",
      payload: { criteria: ["c"], findings: [{ text: "fix the greeting" }] } satisfies ImplementPayload,
      home, workspace: ws, agentReplies, log,
    });
    const [first, second] = readLog(log);
    const prompt = (argv: string[]): string => argv[argv.indexOf("-p") + 1]!;
    expect(prompt(first!)).toContain(workItem.title);
    expect(prompt(second!)).not.toContain(workItem.title);
    expect(prompt(second!)).toContain("fix the greeting");
  });

  const feedback = "Reject an empty name — don't re-explain the guard.\n```diff\n-  if (name) greet(name);\n+  if (!name) throw new Error(\"empty name\");\n```\nThen commit.";

  /** First call stores the session; the second carries `feedback` with the given agent reply. */
  const feedbackRound = async (second: Reply) => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, [
      { is_error: false, result: "r1", commit: true, session_id: "sess-impl-fb" },
      { session_id: "sess-impl-fb", ...second },
    ]);
    await call({
      port: "implement", op: "run", payload: { criteria: ["c"], findings: [] } satisfies ImplementPayload,
      home, workspace: ws, agentReplies, log,
    });
    const payload: ImplementPayload = { criteria: ["c"], findings: [{ text: "empty name is not rejected" }], feedback };
    const result = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies, log });
    return { ...result, ws, argv: readLog(log)[1]! };
  };

  test("feedback resumes the stored session and reaches the prompt verbatim, framed as a Principal directive", async () => {
    const { exitCode, stdout, ws, argv } = await feedbackRound({
      is_error: false, result: "r2", commit: true, structured_output: { feedback: { outcome: "applied", reason: "added the throw" } },
    });
    expect(exitCode).toBe(0);
    expect(argv[argv.indexOf("--resume") + 1]).toBe("sess-impl-fb");
    const prompt = argv[argv.indexOf("-p") + 1]!;
    expect(prompt).toContain(feedback);
    expect(prompt).toContain("PRINCIPAL DIRECTIVE");
    expect(prompt).toContain("takes priority over your earlier reading of the same finding");
    expect(prompt).toContain("explicitly decline it with a stated reason");
    expect(prompt).toContain("Re-explaining or defending the existing code is not an acceptable response");
    expect(prompt).not.toContain("Feedback: ");
    expect(JSON.parse(argv[argv.indexOf("--json-schema") + 1]!).required).toEqual(["feedback"]);
    expect(stdout).toEqual({
      status: "ok",
      body: { changeset: `ship/PROJ-1-1@${headSha(ws)}`, feedback: { outcome: "applied", reason: "added the throw" } },
      evidence: [{ label: "reasoning", text: "r2" }],
    });
  });

  test("feedback on the first call (Define-gate accept) starts fresh with the full task plus the directive", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "r1", commit: true, session_id: "sess-impl-new",
      structured_output: { feedback: { outcome: "applied", reason: "kept it short" } },
    });
    const payload: ImplementPayload = { criteria: ["greets the given name"], findings: [], feedback };
    const { exitCode, stdout } = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies, log });
    expect(exitCode).toBe(0);
    const [argv] = readLog(log);
    expect(argv).not.toContain("--resume");
    const prompt = argv![argv!.indexOf("-p") + 1]!;
    expect(prompt).toContain(workItem.title);
    expect(prompt).toContain("- greets the given name");
    expect(prompt).toContain("PRINCIPAL DIRECTIVE");
    expect(prompt).toContain(feedback);
    expect(prompt).not.toContain("Continue implementing");
    expect(JSON.parse(argv![argv!.indexOf("--json-schema") + 1]!).required).toEqual(["feedback"]);
    expect(stdout).toMatchObject({ status: "ok", body: { feedback: { outcome: "applied", reason: "kept it short" } } });
  });

  test("an explicit decline with a reason is ok even without a new commit", async () => {
    const { stdout, ws } = await feedbackRound({
      is_error: false, result: "r2", structured_output: { feedback: { outcome: "declined", reason: "the caller validates" } },
    });
    expect(stdout).toEqual({
      status: "ok",
      body: { changeset: `ship/PROJ-1-1@${headSha(ws)}`, feedback: { outcome: "declined", reason: "the caller validates" } },
      evidence: [{ label: "reasoning", text: "r2" }],
    });
  });

  for (const [name, structured_output] of [
    ["missing", { summary: "the guard already handles it" }],
    ["outside {applied, declined}", { feedback: { outcome: "explained", reason: "it already works" } }],
    ["with an empty reason", { feedback: { outcome: "declined", reason: "  " } }],
  ] as const) {
    test(`a feedback outcome ${name} is failed when nothing was committed`, async () => {
      const { exitCode, stdout } = await feedbackRound({ is_error: false, result: "r2", structured_output });
      expect(exitCode).toBe(0);
      expect((stdout as { status: string }).status).toBe("failed");
    });

    test(`a feedback outcome ${name} is a crash once a commit happened`, async () => {
      const { exitCode, stdout } = await feedbackRound({ is_error: false, result: "r2", commit: true, structured_output });
      expect(exitCode).not.toBe(0);
      expect(stdout).toBeUndefined();
    });
  }

  test("feedback reported applied with no commit is failed", async () => {
    const { stdout } = await feedbackRound({
      is_error: false, result: "r2", structured_output: { feedback: { outcome: "applied", reason: "done" } },
    });
    expect((stdout as { status: string }).status).toBe("failed");
  });

  test("without feedback the --json-schema does not ask for it and the body stays { changeset }", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "done", commit: true, structured_output: { feedback: { outcome: "applied", reason: "x" } },
    });
    const payload: ImplementPayload = { criteria: ["c"], findings: [] };
    const { stdout } = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies, log });
    const argv = readLog(log)[0]!;
    expect(JSON.parse(argv[argv.indexOf("--json-schema") + 1]!).properties).not.toHaveProperty("feedback");
    expect((stdout as { body: unknown }).body).toEqual({ changeset: `ship/PROJ-1-1@${headSha(ws)}` });
  });

  test("returns failed when the agent errors before committing (safe: nothing changed)", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, { is_error: true, result: "boom" });
    const payload: ImplementPayload = { criteria: ["c"], findings: [] };
    const { exitCode, stdout } = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "failed", info: "boom" });
  });

  test("never returns failed once a real commit happened: a crash (non-zero exit) instead", async () => {
    const home = tempDir("ship-agent-home-");
    const ws = gitRepo();
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, { is_error: true, result: "boom", commit: true });
    const payload: ImplementPayload = { criteria: ["c"], findings: [] };
    const { exitCode, stdout } = await call({ port: "implement", op: "run", payload, home, workspace: ws, agentReplies });
    expect(exitCode).not.toBe(0);
    expect(stdout).toBeUndefined(); // no stdout Result line was printed: a crash, not a swallowed `failed`
  });
});

describe("implement ok body contract (harlo-38)", () => {
  const stdout = schemaFor("implement", "run")!.stdout;
  const ok = (body: unknown) => ({ status: "ok", body });
  test.each([
    ["changeset only", { changeset: "c" }, true],
    ["applied with a reason", { changeset: "c", feedback: { outcome: "applied", reason: "done" } }, true],
    ["declined with a reason", { changeset: "c", feedback: { outcome: "declined", reason: "no" } }, true],
    ["outcome outside the enum", { changeset: "c", feedback: { outcome: "explained", reason: "x" } }, false],
    ["missing outcome", { changeset: "c", feedback: { reason: "x" } }, false],
    ["empty reason", { changeset: "c", feedback: { outcome: "declined", reason: "" } }, false],
    ["unknown key in feedback", { changeset: "c", feedback: { outcome: "applied", reason: "x", extra: 1 } }, false],
    ["unknown key in body", { changeset: "c", summary: "x" }, false],
  ] as const)("%s", (_, body, valid) => {
    expect(ajv.validate(stdout, ok(body))).toBe(valid);
  });
});

describe("agent-claude adapter: check", () => {
  test("never passes --resume, even called twice for the same delivery", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, { is_error: false, result: "ok", structured_output: { verdict: "pass" } });
    const payload: CheckPayload = { criteria: ["c"], changeset: "ship/PROJ-1-1@abc" };
    await call({ port: "check", op: "run", payload, home, agentReplies, log });
    await call({ port: "check", op: "run", payload, home, agentReplies, log });
    for (const argv of readLog(log)) expect(argv).not.toContain("--resume");
  });

  test.each([
    { name: "pass", output: { verdict: "pass" }, body: { verdict: "pass" } },
    { name: "fix", output: { verdict: "fix", findings: [{ text: "f1" }] }, body: { verdict: "fix", findings: [{ text: "f1" }] } },
    {
      name: "decide", output: { verdict: "decide", about: "scope", findings: [{ text: "f2" }] },
      body: { verdict: "decide", about: "scope", findings: [{ text: "f2" }] },
    },
  ])("maps verdict $name", async ({ output, body }) => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, { is_error: false, result: "r", structured_output: output });
    const payload: CheckPayload = { criteria: ["c"], changeset: "ship/PROJ-1-1@abc" };
    const { exitCode, stdout } = await call({ port: "check", op: "run", payload, home, agentReplies });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "ok", body, evidence: [{ label: "reasoning", text: "r" }] });
  });

  test("a 'decide' reply missing 'about' does not print a schema-violating Result (crash-worthy, not a bad ok)", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    // Even though checkSchema now requires `about` on a "decide" verdict, the agent's actual reply is never
    // trusted blindly: the fake bin is free to hand back a schema-violating shape (a real agent might too),
    // and the adapter must still refuse to forward it as a contract-violating `ok{verdict:"decide"}` Result.
    const agentReplies = repliesFile(fx, {
      is_error: false, result: "r", structured_output: { verdict: "decide", findings: [{ text: "f2" }] },
    });
    const payload: CheckPayload = { criteria: ["c"], changeset: "ship/PROJ-1-1@abc" };
    const { exitCode, stdout } = await call({ port: "check", op: "run", payload, home, agentReplies });
    // Nothing was committed at Check time, so a clean `failed` is safe (and `call`'s own ajv check already
    // asserts stdout fits the port's contract — a schema-violating `ok{verdict:"decide"}` would fail that
    // assertion before this expectation ever ran).
    expect(exitCode).toBe(0);
    expect(stdout).toMatchObject({ status: "failed" });
  });

  test("never lets the agent edit files: --disallowedTools Edit Write NotebookEdit", async () => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const log = join(fx, "log.jsonl");
    const agentReplies = repliesFile(fx, { is_error: false, result: "ok", structured_output: { verdict: "pass" } });
    const payload: CheckPayload = { criteria: ["c"], changeset: "ship/PROJ-1-1@abc" };
    await call({ port: "check", op: "run", payload, home, agentReplies, log });
    const argv = readLog(log)[0]!;
    const at = argv.indexOf("--disallowedTools");
    expect(at).toBeGreaterThan(-1);
    expect(argv.slice(at + 1, at + 4)).toEqual(["Edit", "Write", "NotebookEdit"]);
  });
});

describe("agent-claude adapter: cancel", () => {
  test.each(["define", "implement", "check"] as const)("%s cancel is a no-op ok{}", async (port) => {
    const home = tempDir("ship-agent-home-");
    const fx = tempDir("ship-agent-fx-");
    const agentReplies = repliesFile(fx, { is_error: false, result: "" });
    const { exitCode, stdout } = await call({ port, op: "cancel", payload: { target: "PROJ-1-1/run-1" }, home, agentReplies });
    expect(exitCode).toBe(0);
    expect(stdout).toEqual({ status: "ok", body: {} });
  });
});
