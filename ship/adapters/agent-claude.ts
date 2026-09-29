#!/usr/bin/env bun
// Coding-agent adapter (plan §6 M1.9–M1.11; spike M1.8, docs/adapters.md). Cross-cutting: serves `define`,
// `implement` and `check` (plan §6 amendment), so it stays flat under adapters/, not nested per port.
//
// argv: [--agent-bin <path>] <port> <op>, port one of "define" | "implement" | "check"; --agent-bin defaults
// to `claude` on PATH (a fake executable in tests, per M1.9's own test spec). stdin: Stdin (§3.1); stdout: one
// Result JSON line.
//
// `run` builds a prompt, then calls `<agent-bin> -p <prompt> --output-format json --json-schema <schema>
// [--resume <session-id>]` (M1.8 spike shape), parses stdout as JSON unconditionally, and branches on
// `is_error` vs `.structured_output`. `define` and `implement` each keep their OWN session id, keyed by
// Delivery, in their own small state file (P5: adapters own their state, never read another's — `implement`
// never reads `define`'s file, and vice versa). `check` never stores or reads a session id: P8 requires a
// fresh session on every call, so it simply never touches either state file.
//
// State file: ~/.local/state/ship/agent-claude/<port>.json = { [delivery]: session_id }. `check` has none.
//
// Crash vs `failed` (`implement` only): once the agent has made a real commit in the workspace, an error
// is never swallowed into `failed` (that would mean "changed nothing", which is false) — it is thrown past
// the top-level catch instead, so the process exits non-zero: a crash, per docs/adapters.md.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { Finding, Stdin, WorkItem } from "../src/contracts/common";
import type { CheckPayload, DefinePayload, ImplementPayload } from "../src/contracts/ports";
import { schemaFor } from "../src/contracts/ports";
import { check } from "../src/contracts/validate";

type StepPort = "define" | "implement" | "check";
const STEP_PORTS = ["define", "implement", "check"] as const satisfies readonly StepPort[];

type Ctx = { agentBin: string };

/** Thrown instead of returning `failed`, once a real commit has happened (implement only): a crash, never caught. */
class Crash extends Error {}

const expandHome = (dir: string): string =>
  dir === "~" ? homedir() : dir.startsWith("~/") ? join(homedir(), dir.slice(2)) : dir;

// ── Session state, per port, keyed by Delivery. `check` never calls these (P8). ──
const stateFile = (port: "define" | "implement"): string =>
  join(expandHome("~/.local/state/ship/agent-claude"), `${port}.json`);

const readState = (port: "define" | "implement"): Record<string, string> => {
  const file = stateFile(port);
  return existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Record<string, string>) : {};
};

const writeState = (port: "define" | "implement", state: Record<string, string>): void => {
  const file = stateFile(port);
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify(state));
};

// ── The agent binary ──
type AgentReply = { is_error: boolean; result: string; structured_output?: unknown; session_id?: string };

const callAgent = async (
  agentBin: string, prompt: string, schema: unknown, resume: string | undefined, cwd?: string,
): Promise<AgentReply> => {
  const args = [
    agentBin, "-p", prompt, "--output-format", "json", "--json-schema", JSON.stringify(schema),
    ...(resume ? ["--resume", resume] : []),
  ];
  const proc = Bun.spawn(args, { cwd, stdout: "pipe", stderr: "pipe" });
  // M1.8 spike: even a non-zero exit (e.g. auth failure) still prints one valid JSON object, so stdout is
  // always parsed as JSON first; the branch is on `is_error`, never on the exit code.
  const [out] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  return JSON.parse(out) as AgentReply;
};

const headSha = (dir: string): string => {
  const proc = Bun.spawnSync(["git", "-C", dir, "rev-parse", "HEAD"], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`git rev-parse HEAD failed in ${dir}: ${proc.stderr.toString()}`);
  return proc.stdout.toString().trim();
};

// ── define ──
const defineSchema = {
  type: "object",
  properties: {
    criteria: { type: "array", items: { type: "string" } },
    runbook: { type: "array", items: { type: "string" } },
    question: { type: "string" },
  },
  required: [],
  additionalProperties: false,
} as const;

const definePrompt = (workItem: WorkItem, payload: DefinePayload): string => {
  const lines = [
    `WorkItem ${workItem.key}: ${workItem.title}`,
    workItem.body,
    "Define acceptance criteria and a runbook for verifying them.",
  ];
  if (payload.feedback !== undefined) lines.push(`Feedback from a prior review: ${payload.feedback}`);
  if (payload.answer !== undefined) lines.push(`Answer to your previous question: ${payload.answer}`);
  return lines.join("\n\n");
};

const defineRun = async (ctx: Ctx, stdin: Stdin): Promise<unknown> => {
  const payload = stdin.payload as DefinePayload;
  const resume = payload.feedback !== undefined || payload.answer !== undefined;
  const state = readState("define");
  const sessionId = resume ? state[stdin.delivery] : undefined;
  const reply = await callAgent(ctx.agentBin, definePrompt(stdin.workItem, payload), defineSchema, sessionId);
  if (reply.session_id) writeState("define", { ...state, [stdin.delivery]: reply.session_id });
  if (reply.is_error) return { status: "failed", info: reply.result };
  const out = reply.structured_output as { criteria?: string[]; runbook?: string[]; question?: string } | undefined;
  if (out?.question) return { status: "question", about: "clarify", prompt: out.question };
  if (!out?.criteria || !out?.runbook) throw new Error(`agent reply missing criteria/runbook: ${reply.result}`);
  return { status: "ok", body: { criteria: out.criteria, runbook: out.runbook } };
};

// ── implement ──
const implementSchema = {
  type: "object",
  properties: { summary: { type: "string" } },
  required: [],
  additionalProperties: false,
} as const;

const implementPrompt = (workItem: WorkItem, payload: ImplementPayload): string => {
  const lines = [
    `WorkItem ${workItem.key}: ${workItem.title}`,
    "Implement it in this working directory and commit your changes.",
    "Criteria:", ...payload.criteria.map((c) => `- ${c}`),
  ];
  if (payload.findings.length > 0) {
    lines.push("Findings from a prior check:", ...payload.findings.map((f) => `- ${f.text}${f.ref ? ` (${f.ref})` : ""}`));
  }
  if (payload.feedback !== undefined) lines.push(`Feedback: ${payload.feedback}`);
  if (payload.answer !== undefined) lines.push(`Answer to your previous question: ${payload.answer}`);
  return lines.join("\n");
};

const implementRun = async (ctx: Ctx, stdin: Stdin): Promise<unknown> => {
  const payload = stdin.payload as ImplementPayload;
  const workspace = stdin.workspace;
  if (!workspace) throw new Error("implement run requires a workspace (from workspace.setup)");
  const before = headSha(workspace);

  // A re-issue after a fix round or a question answer resumes this delivery's own Implement session; the
  // very first call for a delivery starts fresh.
  const resume = payload.findings.length > 0 || payload.feedback !== undefined || payload.answer !== undefined;
  const state = readState("implement");
  const sessionId = resume ? state[stdin.delivery] : undefined;
  const prompt = implementPrompt(stdin.workItem, payload);

  let reply: AgentReply;
  try {
    reply = await callAgent(ctx.agentBin, prompt, implementSchema, sessionId, workspace);
  } catch (error) {
    if (headSha(workspace) !== before) throw new Crash(`agent call errored after a commit: ${String(error)}`);
    throw error;
  }

  const after = headSha(workspace);
  const committed = after !== before;
  if (reply.session_id) writeState("implement", { ...state, [stdin.delivery]: reply.session_id });

  if (reply.is_error) {
    if (committed) throw new Crash(`agent reported is_error after a commit: ${reply.result}`);
    return { status: "failed", info: reply.result }; // nothing committed: safe, changed nothing
  }
  if (!committed) return { status: "failed", info: "agent finished without committing any changes" };
  return { status: "ok", body: { changeset: `ship/${stdin.delivery}@${after}` } };
};

// ── check ──
// Keyed on `verdict`, mirroring `checkBody` in src/contracts/ports.ts: only the "decide" branch requires
// `about`, so a schema-conformant "decide" reply can never omit it (a plain `enum`+`required: ["verdict"]`
// shape let a conformant reply carry `verdict:"decide"` with no `about`, which checkRun then forwarded
// unchecked into a Result that violated `checkBody`'s own schema).
const findingSchema = {
  type: "object",
  properties: { text: { type: "string" }, ref: { type: "string" } },
  required: ["text"],
} as const;

const checkSchema = {
  type: "object",
  oneOf: [
    {
      type: "object",
      properties: { verdict: { type: "string", const: "pass" } },
      required: ["verdict"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: { verdict: { type: "string", const: "fix" }, findings: { type: "array", items: findingSchema } },
      required: ["verdict", "findings"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: {
        verdict: { type: "string", const: "decide" },
        about: { type: "string", enum: ["scope", "advisory"] },
        findings: { type: "array", items: findingSchema },
      },
      required: ["verdict", "about", "findings"],
      additionalProperties: false,
    },
  ],
} as const;

const checkPrompt = (workItem: WorkItem, payload: CheckPayload): string => {
  const lines = [
    `WorkItem ${workItem.key}: ${workItem.title}`,
    "Check this changeset against the acceptance criteria.",
    `Changeset: ${payload.changeset}`,
    "Criteria:", ...payload.criteria.map((c) => `- ${c}`),
  ];
  if (payload.answer !== undefined) lines.push(`Answer to your previous question: ${payload.answer}`);
  return lines.join("\n");
};

const checkRun = async (ctx: Ctx, stdin: Stdin): Promise<unknown> => {
  const payload = stdin.payload as CheckPayload;
  const prompt = checkPrompt(stdin.workItem, payload);
  // P8: Check runs independently of the worker that implemented — always a fresh session, so no `--resume`
  // and no read of either `define`'s or `implement`'s state file, ever.
  const reply = await callAgent(ctx.agentBin, prompt, checkSchema, undefined, stdin.workspace ?? undefined);
  if (reply.is_error) return { status: "failed", info: reply.result };
  const out = reply.structured_output as { verdict?: string; about?: string; findings?: Finding[] } | undefined;
  let result: unknown;
  if (out?.verdict === "pass") result = { status: "ok", body: { verdict: "pass" } };
  else if (out?.verdict === "fix") result = { status: "ok", body: { verdict: "fix", findings: out.findings ?? [] } };
  else if (out?.verdict === "decide") {
    // A schema-conformant reply can't get here with `about` missing/invalid any more (see checkSchema above),
    // but the agent's actual reply is never trusted blindly: guard again at runtime, never forward an `about`
    // that isn't one of the two values `checkBody` accepts, so a bad reply can't produce a contract-violating
    // Result. Nothing has been committed at Check time, so `failed` (via the top-level catch, below) is safe.
    if (out.about !== "scope" && out.about !== "advisory") {
      throw new Error(`agent reply had verdict "decide" without a valid "about" (scope|advisory): ${reply.result}`);
    }
    result = { status: "ok", body: { verdict: "decide", about: out.about, findings: out.findings ?? [] } };
  } else {
    throw new Error(`agent reply had an unexpected verdict: ${reply.result}`);
  }
  // Belt-and-braces: validate the mapped Result against the port's own stdout contract before printing it,
  // mirroring how adapters/state/files.ts validates its own stored payload on the way in.
  const invalid = check(schemaFor("check", "run")!.stdout, result);
  if (invalid) throw new Error(`agent-claude check would have printed a contract-violating Result: ${invalid}`);
  return result;
};

const RUN: Record<StepPort, (ctx: Ctx, stdin: Stdin) => Promise<unknown>> = {
  define: defineRun, implement: implementRun, check: checkRun,
};
const cancelOp = async (): Promise<unknown> => ({ status: "ok", body: {} }); // nothing runs in the background

/** argv after the script: `[--agent-bin <path>] <port> <op>`; --agent-bin defaults to `claude` on PATH. */
const parseArgs = (args: string[]): { agentBin: string; port: string | undefined; op: string | undefined } => {
  const at = args.indexOf("--agent-bin");
  const agentBin = at === -1 ? "claude" : (args[at + 1] ?? "claude");
  const positional = at === -1 ? args : [...args.slice(0, at), ...args.slice(at + 2)];
  const [port, op] = positional;
  return { agentBin, port, op };
};

const main = async (): Promise<unknown> => {
  const { agentBin, port, op } = parseArgs(process.argv.slice(2));
  const stepPort = (STEP_PORTS as readonly string[]).includes(port ?? "") ? (port as StepPort) : undefined;
  const contract = stepPort && op ? schemaFor(stepPort, op) : undefined;
  const handler = op === "run" ? RUN[stepPort as StepPort] : op === "cancel" ? cancelOp : undefined;
  if (!stepPort || !contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return op === "cancel" ? cancelOp() : RUN[stepPort]({ agentBin }, stdin);
};

try {
  console.log(JSON.stringify(await main()));
} catch (error) {
  if (error instanceof Crash) throw error; // a crash, never `failed`: a commit already happened
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
