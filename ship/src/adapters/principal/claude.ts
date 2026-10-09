#!/usr/bin/env bun
// Model Principal: an unattended `claude` CLI answers every decide/ask gate instead of a person, so a queue
// can run autonomously with nobody at a terminal. argv: [--agent-bin=<path>] [--agent-arg=<--flag[=value]>]...
// principal <op>, parsed by the shared parseAgentArgv and run by the shared runClaude (harlo-64,
// agent/claude/cli.ts: the same parser, isolation defaults and invocation agent/claude/index.ts uses); --agent-bin defaults to `claude` on PATH (a fake executable in
// tests); each --agent-arg passes one claude flag through to every CLI call `decide`/`ask` makes. A bad flag is a
// startup failure (exit 2, before stdin is read).
//   decide, ask → build a prompt from the gate's evidence/options, call the CLI with a `--json-schema` that
//                 forces `answer` into the given options, then {"status":"ok", body:{answer, by:"model", comment?}}
//   notify, cancel → no CLI call: ack {"status":"ok", body:{}} immediately, same as tty.ts
// The CLI always answers: there is no fallback to a human. A malformed or off-list reply changes nothing (no
// side effect has happened), so it is `failed`, same as any other adapter error before a side effect.
import type { Decide, GateEvidence, Stdin } from "../../../src/contracts/common";
import type { AskPayload, CancelPayload, NotifyPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { check } from "../../../src/contracts/validate";
import { type ClaudeReply, parseAgentArgv, runClaude } from "../agent/claude/cli";

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

/** The CLI to run and the merged claude args every call passes after its protocol part (harlo-64). */
type Agent = { agentBin: string; agentArgs: string[] };

/** The CLI's structured answer, or throws (caught at the top level as `failed`: nothing changed). */
const structuredReplyOf = (reply: ClaudeReply): Record<string, unknown> => {
  if (reply.is_error) throw new Error(`claude CLI reported an error: ${reply.result}`);
  if (typeof reply.structured_output !== "object" || reply.structured_output === null) {
    throw new Error(`claude CLI returned no structured_output: ${JSON.stringify(reply)}`);
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

const decide = async (agent: Agent, stdin: Stdin, p: Decide): Promise<unknown> => {
  const reply = await runClaude({ ...agent, prompt: decidePrompt(stdin, p), schema: answerSchema(p.options, true) });
  const { answer, comment } = answerOf(structuredReplyOf(reply), p.options);
  const carries = p.comments[answer] !== undefined && p.comments[answer]!.goes !== "dropped";
  return { status: "ok", body: { answer, by: "model", ...(comment !== undefined && carries ? { comment } : {}) } };
};

const ask = async (agent: Agent, stdin: Stdin, p: AskPayload): Promise<unknown> => {
  const reply = await runClaude({ ...agent, prompt: askPrompt(stdin, p), schema: answerSchema(p.options ?? undefined, false) });
  const { answer } = answerOf(structuredReplyOf(reply), p.options ?? undefined);
  return { status: "ok", body: { answer, by: "model" } };
};

const notify = (): unknown => ({ status: "ok", body: {} });
const cancel = (): unknown => ({ status: "ok", body: {} }); // every call above is async: nothing to cancel

const OPS: Record<string, (agent: Agent, stdin: Stdin) => Promise<unknown>> = {
  decide: (agent, stdin) => decide(agent, stdin, stdin.payload as Decide),
  ask: (agent, stdin) => ask(agent, stdin, stdin.payload as AskPayload),
  notify: () => Promise.resolve(notify()),
  cancel: () => Promise.resolve(cancel()),
};

/** A bad flag is a startup failure (exit 2, before stdin is read), never a silent default: the config is wrong.
 *  Same failure style as agent/claude/index.ts. */
const startup = (() => {
  try {
    return parseAgentArgv(process.argv.slice(2));
  } catch (error) {
    console.error(`principal-claude: ${error instanceof Error ? error.message : String(error)}`);
    process.exit(2);
  }
})();

const run = async (): Promise<unknown> => {
  const { agentBin, agentArgs, positionals: [port, op] } = startup;
  const contract = port === "principal" && op ? schemaFor("principal", op) : undefined;
  const handler = op && Object.hasOwn(OPS, op) ? OPS[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  const result = await handler({ agentBin, agentArgs }, stdin);
  const invalidResult = check(contract.stdout, result);
  if (invalidResult) throw new Error(`principal/claude would have printed a contract-violating Result: ${invalidResult}`);
  return result;
};

try {
  console.log(JSON.stringify(await run()));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
