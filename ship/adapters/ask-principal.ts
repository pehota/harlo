#!/usr/bin/env bun
// ask-principal adapter (plan M1.7): a manual gate standing in for a real Deploy or Verify system, for setups that
// don't have one yet — it asks the Principal directly instead. Cross-cutting: serves both `deploy` and `verify`
// (plan §6 amendment), so it stays flat under adapters/, not nested per port.
// argv: ask-principal <port> <op>, port one of "deploy" | "verify".
//   run, no `answer`  → question{about: "manual", prompt, options}: [live, not_live] for deploy, [pass, fail] for verify
//   run, `answer` set → the matching ok{verdict}; a negative answer (not_live/fail) also attaches findings:[{text: answer}]
//   cancel            → nothing runs in the background, so there is never anything to cancel: ok{}
import type { DeployPayload, VerifyPayload } from "../src/contracts/ports";
import { schemaFor } from "../src/contracts/ports";
import { check } from "../src/contracts/validate";

type GatedPort = "deploy" | "verify";
type RunPayload = DeployPayload | VerifyPayload;
type Body = { verdict: string; findings?: [{ text: string }] };

const OPTIONS: Record<GatedPort, [positive: string, negative: string]> = {
  deploy: ["live", "not_live"],
  verify: ["pass", "fail"],
};
const PROMPT: Record<GatedPort, string> = {
  deploy: "Is it live?",
  verify: "Does it pass?",
};

const run = (port: GatedPort, { answer }: RunPayload): unknown => {
  const [positive, negative] = OPTIONS[port];
  if (answer === undefined) return { status: "question", about: "manual", prompt: PROMPT[port], options: [positive, negative] };
  if (answer === positive) return { status: "ok", body: { verdict: positive } satisfies Body };
  if (answer === negative) return { status: "ok", body: { verdict: negative, findings: [{ text: answer }] } satisfies Body };
  throw new Error(`unexpected answer: ${JSON.stringify(answer)}`);
};

const ops: Record<string, (port: GatedPort, payload: never) => unknown> = {
  run,
  cancel: () => ({ status: "ok", body: {} }), // nothing runs in the background, so there is never anything to cancel
};

/** Every error is caught: `run` and `cancel` are both read/echo only, so a thrown error changed nothing. */
const main = async (): Promise<unknown> => {
  const [port, op] = process.argv.slice(2);
  const gated = port === "deploy" || port === "verify" ? port : undefined;
  const contract = gated && op ? schemaFor(gated, op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!gated || !contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as { payload?: unknown };
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return handler(gated, stdin.payload as never);
};

try {
  console.log(JSON.stringify(await main()));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
