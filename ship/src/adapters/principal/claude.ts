#!/usr/bin/env bun
// Model Principal: an unattended `claude` CLI answers every decide/ask gate instead of a person, so a queue
// can run autonomously with nobody at a terminal. argv: [--agent-bin <path>] [--plugin-dir <path>]...
// principal <op>; --agent-bin defaults to `claude` on PATH (a fake executable in tests, mirroring
// agent/claude/index.ts); --plugin-dir is repeatable and forwarded to every CLI call `decide`/`ask` makes.
//   decide, ask → build a prompt from the gate's evidence/options, call the CLI with a `--json-schema` that
//                 forces `answer` into the given options, then {"status":"ok", body:{answer, by:"model", comment?}}
//   notify, cancel → no CLI call: ack {"status":"ok", body:{}} immediately, same as tty.ts
// The CLI always answers: there is no fallback to a human. A malformed or off-list reply changes nothing (no
// side effect has happened), so it is `failed`, same as any other adapter error before a side effect.
import type { Decide, GateEvidence, Stdin } from "../../../src/contracts/common";
import type { AskPayload, CancelPayload, NotifyPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { check } from "../../../src/contracts/validate";

/** `requirements` is opaque to the core (harlo-58): rendered as pretty-printed JSON, same as any other evidence
 *  the adapter doesn't interpret — never assumes a `criteria`/`runbook` shape inside it. */
const requirementsLines = (requirements: unknown): string[] =>
  requirements === null || requirements === undefined ? [] : ["Requirements:", JSON.stringify(requirements, null, 2)];

/** The evidence bundle as plain lines (P9: passed through as given, never interpreted) — same shape as tty.ts,
 *  since the CLI reads it as plain prompt text, not structured JSON. */
const evidenceLines = (e: GateEvidence): string[] => [
  `WorkItem ${e.workItem.key}: ${e.workItem.title}${e.workItem.url ? ` <${e.workItem.url}>` : ""}`,
  ...e.workItem.body.split("\n").map((line) => `  ${line}`),
  ...requirementsLines(e.requirements),
  ...(e.changeset === null ? [] : [`Changeset: ${e.changeset}`]),
  ...(e.findings.length > 0 ? ["Findings:", ...e.findings.map((f) => `  - ${f.ref ? `${f.text} (${f.ref})` : f.text}`)] : []),
  ...(e.evidence.length > 0 ? ["Evidence:", ...e.evidence.map((i) => `  - ${[i.label, i.text, i.url].filter(Boolean).join(" — ")}`)] : []),
  ...(e.note === undefined ? [] : [`Note: ${e.note}`]),
];

/** Which answers keep a comment and where it goes, so the model knows a comment on them is acted on. */
const commentLines = (p: Decide): string[] => {
  const kept = p.options.flatMap((option) => {
    const route = p.comments[option];
    if (!route || route.goes === "dropped") return [];
    return [`${option} (${route.goes === "feedback" ? `sent to ${route.to} as a directive` : "recorded as the reason"})`];
  });
  return kept.length > 0 ? [`Put any short comment in the \`comment\` field. It is kept only with: ${kept.join(", ")}.`] : [];
};

const decidePrompt = (stdin: Stdin, p: Decide): string => [
  `You are the unattended Principal for an autonomous delivery queue (${stdin.delivery}).`,
  `Decide: ${p.on}`,
  ...evidenceLines(p.evidence),
  `Answer with exactly one of: ${p.options.join(", ")}.`,
  ...commentLines(p),
].join("\n");

const askPrompt = (stdin: Stdin, p: AskPayload): string => [
  `You are the unattended Principal for an autonomous delivery queue (${stdin.delivery}).`,
  p.prompt,
  ...evidenceLines(p.evidence),
  ...(p.options && p.options.length > 0 ? [`Answer with exactly one of: ${p.options.join(", ")}.`] : ["Answer in plain text."]),
].join("\n");

/** Runs the `claude` CLI with a prompt and a JSON schema that constrains its structured answer; mirrors
 *  agent/claude/index.ts's call shape (`-p`, `--output-format json`, `--safe-mode`, `bypassPermissions`), minus
 *  session/resume (a gate reply is always a single, independent call, never continued). */
const callAgent = async (agentBin: string, pluginDirs: string[], prompt: string, schema: object): Promise<string> => {
  const proc = Bun.spawn(
    [
      agentBin, "-p", prompt, "--output-format", "json", "--json-schema", JSON.stringify(schema), "--safe-mode", "--permission-mode", "bypassPermissions",
      ...pluginDirs.flatMap((dir) => ["--plugin-dir", dir]),
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [out] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  return out;
};

type AgentReply = { is_error: boolean; result: string; structured_output?: unknown };

/** The CLI's structured answer, or throws (caught at the top level as `failed`: nothing changed). */
const structuredReplyOf = (stdout: string): Record<string, unknown> => {
  const reply = JSON.parse(stdout) as AgentReply;
  if (reply.is_error) throw new Error(`claude CLI reported an error: ${reply.result}`);
  if (typeof reply.structured_output !== "object" || reply.structured_output === null) {
    throw new Error(`claude CLI returned no structured_output: ${stdout}`);
  }
  return reply.structured_output as Record<string, unknown>;
};

/** The JSON schema sent as `--json-schema`: a flat object (no root oneOf/allOf/anyOf — the real API rejects
 *  those at the root), `answer` constrained to `options` when given, `comment` only when the gate allows one. */
const answerSchema = (options: string[] | undefined, commentAllowed: boolean): object => ({
  type: "object",
  properties: {
    answer: options && options.length > 0 ? { type: "string", enum: options } : { type: "string" },
    ...(commentAllowed ? { comment: { type: "string" } } : {}),
  },
  required: ["answer"],
  additionalProperties: false,
});

type Answer = { answer: string; comment?: string };

/** Validates the CLI's structured answer against the gate's real options (the JSON schema is a hint to the
 *  model, not a guarantee), since an off-list answer must crash rather than be forwarded as if it were valid. */
const answerOf = (structured: Record<string, unknown>, options: string[] | undefined): Answer => {
  const answer = structured.answer;
  if (typeof answer !== "string" || (options && options.length > 0 && !options.includes(answer))) {
    throw new Error(`claude CLI answered outside the allowed options: ${JSON.stringify(structured)}`);
  }
  const comment = structured.comment;
  return typeof comment === "string" && comment !== "" ? { answer, comment } : { answer };
};

const decide = async (agentBin: string, pluginDirs: string[], stdin: Stdin, p: Decide): Promise<unknown> => {
  const stdout = await callAgent(agentBin, pluginDirs, decidePrompt(stdin, p), answerSchema(p.options, true));
  const { answer, comment } = answerOf(structuredReplyOf(stdout), p.options);
  const carries = p.comments[answer] !== undefined && p.comments[answer]!.goes !== "dropped";
  return { status: "ok", body: { answer, by: "model", ...(comment !== undefined && carries ? { comment } : {}) } };
};

const ask = async (agentBin: string, pluginDirs: string[], stdin: Stdin, p: AskPayload): Promise<unknown> => {
  const stdout = await callAgent(agentBin, pluginDirs, askPrompt(stdin, p), answerSchema(p.options ?? undefined, false));
  const { answer } = answerOf(structuredReplyOf(stdout), p.options ?? undefined);
  return { status: "ok", body: { answer, by: "model" } };
};

const notify = (): unknown => ({ status: "ok", body: {} });
const cancel = (): unknown => ({ status: "ok", body: {} }); // every call above is async: nothing to cancel

const OPS: Record<string, (agentBin: string, pluginDirs: string[], stdin: Stdin) => Promise<unknown>> = {
  decide: (agentBin, pluginDirs, stdin) => decide(agentBin, pluginDirs, stdin, stdin.payload as Decide),
  ask: (agentBin, pluginDirs, stdin) => ask(agentBin, pluginDirs, stdin, stdin.payload as AskPayload),
  notify: () => Promise.resolve(notify()),
  cancel: () => Promise.resolve(cancel()),
};

/** argv after the script: `[--agent-bin <path>] [--plugin-dir <path>]... <port> <op>`; --agent-bin defaults to
 *  `claude` on PATH; --plugin-dir is repeatable and defaults to none, mirroring agent/claude/index.ts. */
const parseArgs = (
  args: string[],
): { agentBin: string; pluginDirs: string[]; port: string | undefined; op: string | undefined } => {
  let agentBin = "claude";
  const pluginDirs: string[] = [];
  const positional: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--agent-bin") { agentBin = args[i + 1] ?? agentBin; i += 1; }
    else if (args[i] === "--plugin-dir") { if (args[i + 1] !== undefined) pluginDirs.push(args[i + 1] as string); i += 1; }
    else positional.push(args[i] as string);
  }
  const [port, op] = positional;
  return { agentBin, pluginDirs, port, op };
};

const run = async (): Promise<unknown> => {
  const { agentBin, pluginDirs, port, op } = parseArgs(process.argv.slice(2));
  const contract = port === "principal" && op ? schemaFor("principal", op) : undefined;
  const handler = op && Object.hasOwn(OPS, op) ? OPS[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  const result = await handler(agentBin, pluginDirs, stdin);
  const invalidResult = check(contract.stdout, result);
  if (invalidResult) throw new Error(`principal/claude would have printed a contract-violating Result: ${invalidResult}`);
  return result;
};

try {
  console.log(JSON.stringify(await run()));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
