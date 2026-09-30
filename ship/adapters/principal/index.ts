#!/usr/bin/env bun
// Terminal Principal (plan M0.20): prints each gate or question for a person, who answers by pasting a
// `ship signal` line. argv: [--out <path>] principal <op>; --out defaults to /dev/tty.
//   decide, ask → print, then {"status":"accepted"} (the answer arrives later through `ship signal`)
//   notify      → print, then ok {}
//   cancel      → print "withdrawn", then ok {}
// Every error is caught: nothing is printed for the person unless the write succeeded, so `failed` changed nothing.
import { appendFileSync } from "node:fs";
import type { Decide, GateEvidence, Stdin } from "../../src/contracts/common";
import type { AskPayload, CancelPayload, NotifyPayload } from "../../src/contracts/ports";
import { PLACEHOLDER } from "./placeholder";

const OK = { status: "ok", body: {} };
const ACCEPTED = { status: "accepted" };

/** One shell word: left bare when it is plain, else single-quoted with each `'` written as `'\''`. */
const shellQuote = (word: string): string => (/^[A-Za-z0-9._\/-]+$/.test(word) ? word : `'${word.replaceAll("'", `'\\''`)}'`);

const signalLine = (stdin: Stdin, answer: string): string => {
  const result = JSON.stringify({ status: "ok", body: { answer, by: "person" } });
  return `  ship signal ${[stdin.delivery, stdin.id, result].map(shellQuote).join(" ")}`;
};

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

/** The pasted answer lines: one per option, or one with a placeholder to replace. */
const answerLines = (stdin: Stdin, options: string[] | undefined): string[] =>
  options && options.length > 0
    ? ["Answer with one of:", ...options.map((o) => signalLine(stdin, o))]
    : [`Answer (replace ${PLACEHOLDER}):`, signalLine(stdin, PLACEHOLDER)];

const decide = (stdin: Stdin, p: Decide): string[] => [
  `── ${stdin.delivery}: decide ${p.on} (min ${p.min}) ──`,
  ...evidenceLines(p.evidence),
  ...answerLines(stdin, p.options),
  `  (optional: add "comment":"…" to the body)`,
];

const ask = (stdin: Stdin, p: AskPayload): string[] => [
  `── ${stdin.delivery}: question (min ${p.min}) ──`,
  p.prompt,
  ...evidenceLines(p.evidence),
  ...answerLines(stdin, p.options),
];

const notify = (stdin: Stdin, p: NotifyPayload): string[] => [
  `── ${stdin.delivery}: ${p.text} ──`,
  ...(p.evidence ? evidenceLines(p.evidence) : []),
];

const cancel = (stdin: Stdin, p: CancelPayload): string[] => [`── ${stdin.delivery}: ${p.target} withdrawn ──`];

const OPS: Record<string, { print: (stdin: Stdin, payload: never) => string[]; reply: unknown }> = {
  decide: { print: decide, reply: ACCEPTED },
  ask: { print: ask, reply: ACCEPTED },
  notify: { print: notify, reply: OK },
  cancel: { print: cancel, reply: OK },
};

const run = async (): Promise<unknown> => {
  const args = process.argv.slice(2);
  const at = args.indexOf("--out");
  const out = at === -1 ? "/dev/tty" : args[at + 1];
  const [port, op] = args.slice(-2);
  const handler = port === "principal" && op && Object.hasOwn(OPS, op) ? OPS[op] : undefined;
  if (!out || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const lines = handler.print(stdin, stdin.payload as never);
  appendFileSync(out, `\n${lines.join("\n")}\n`);
  return handler.reply;
};

try {
  console.log(JSON.stringify(await run()));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
