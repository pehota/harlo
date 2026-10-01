#!/usr/bin/env bun
// Terminal Principal (plan M0.20; sync transport, supersedes the old fire-and-forget design): prints each gate
// or question, then blocks on /dev/tty for the reply itself — the same invocation answers it, no second
// `ship signal` call needed. argv: principal <op>.
//   decide, ask → print, block for a reply on /dev/tty, match it, then {"status":"ok", body:{answer, by, comment?}}
//   notify      → print, then ok {}
//   cancel      → print "withdrawn", then ok {}
// Every error is caught: printing a gate the caller never sees the reply to would be worse than failing loudly.
import { closeSync, openSync, readSync, writeSync } from "node:fs";
import type { Decide, GateEvidence, Stdin } from "../../../src/contracts/common";
import type { AskPayload, CancelPayload, NotifyPayload } from "../../../src/contracts/ports";
import { match } from "./match";

const OK = { status: "ok", body: {} };

const list = (title: string, items: string[]): string[] => (items.length === 0 ? [] : [`${title}:`, ...items.map((i) => `  - ${i}`)]);

/** The evidence bundle as plain lines (P9: printed as given, never interpreted). */
const evidenceLines = (e: GateEvidence): string[] => [
  `WorkItem ${e.workItem.key}: ${e.workItem.title}${e.workItem.url ? ` <${e.workItem.url}>` : ""}`,
  ...e.workItem.body.split("\n").map((line) => `  ${line}`),
  ...list("Criteria", e.criteria ?? []),
  ...list("Runbook", e.runbook ?? []),
  ...(e.changeset === null ? [] : [`Changeset: ${e.changeset}`]),
  ...list("Findings", e.findings.map((f) => (f.ref ? `${f.text} (${f.ref})` : f.text))),
  ...list("Evidence", e.evidence.map((i) => [i.label, i.text, i.url].filter(Boolean).join(" — "))),
  ...(e.note === undefined ? [] : [`Note: ${e.note}`]),
];

/** The reply prompt: a plain option list, or a free-text invitation when the gate is open-ended. */
const answerLines = (options: string[] | undefined): string[] =>
  options && options.length > 0 ? ["Answer with one of:", ...options.map((o) => `  ${o}`)] : ["Answer (type your reply):"];

const decideLines = (stdin: Stdin, p: Decide): string[] => [
  `── ${stdin.delivery}: decide ${p.on} (min ${p.min}) ──`,
  ...evidenceLines(p.evidence),
  ...answerLines(p.options),
  `  (optional: add free text after your answer as a comment)`,
];

const askLines = (stdin: Stdin, p: AskPayload): string[] => [
  `── ${stdin.delivery}: question (min ${p.min}) ──`,
  p.prompt,
  ...evidenceLines(p.evidence),
  ...answerLines(p.options),
];

const notifyLines = (stdin: Stdin, p: NotifyPayload): string[] => [
  `── ${stdin.delivery}: ${p.text} ──`,
  ...(p.evidence ? evidenceLines(p.evidence) : []),
];

const cancelLines = (stdin: Stdin, p: CancelPayload): string[] => [`── ${stdin.delivery}: ${p.target} withdrawn ──`];

/** A /dev/tty handle open for both the prompt and the reply — never stdin/stdout, which carry the JSON contract. */
type Tty = { print: (lines: string[]) => void; readLine: () => string; close: () => void };

const openTty = (): Tty => {
  const fd = openSync("/dev/tty", "r+");
  return {
    print: (lines) => writeSync(fd, `\n${lines.join("\n")}\n`),
    readLine: () => {
      const bytes: number[] = [];
      const one = Buffer.alloc(1);
      while (readSync(fd, one, 0, 1, null) === 1 && one[0] !== 10) bytes.push(one[0]!);
      return Buffer.from(bytes).toString("utf8").replace(/\r$/, "");
    },
    close: () => closeSync(fd),
  };
};

/** Block for a reply against `options` (empty/undefined means open-ended: the whole reply is the answer). Loops
 * (not recurses) on an empty/unclear reply, so a stuck or flaky tty can't grow the call stack unboundedly. */
const answer = (tty: Tty, options: string[] | undefined, commentAllowed: boolean): { answer: string; comment?: string } => {
  for (;;) {
    if (!options || options.length === 0) {
      const reply = tty.readLine().trim();
      if (reply === "") {
        tty.print(["empty reply, try again:"]);
        continue;
      }
      return { answer: reply };
    }
    const reply = tty.readLine();
    const matched = match(reply, options, commentAllowed);
    if (matched.ok) return { answer: matched.answer, ...(matched.comment === undefined ? {} : { comment: matched.comment }) };
    tty.print([matched.reason, ...answerLines(options)]);
  }
};

const OPS: Record<string, { print: (stdin: Stdin, payload: never) => string[]; interactive: boolean }> = {
  decide: { print: decideLines, interactive: true },
  ask: { print: askLines, interactive: true },
  notify: { print: notifyLines, interactive: false },
  cancel: { print: cancelLines, interactive: false },
};

const run = async (): Promise<unknown> => {
  const [port, op] = process.argv.slice(2);
  const handler = port === "principal" && op && Object.hasOwn(OPS, op) ? OPS[op] : undefined;
  if (!handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const lines = handler.print(stdin, stdin.payload as never);
  const tty = openTty();
  try {
    tty.print(lines);
    if (!handler.interactive) return OK;
    const payload = stdin.payload as Decide | AskPayload;
    const { answer: text, comment } = answer(tty, payload.options, op === "decide");
    return { status: "ok", body: { answer: text, by: "person", ...(comment === undefined ? {} : { comment }) } };
  } finally {
    tty.close();
  }
};

try {
  console.log(JSON.stringify(await run()));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
