// transition(): apply one signal to a Delivery (plan §4). Dispatch is by position (Snapshot.at).
import type { Ok } from "../contracts/common";
import type { CheckBody, DecideBody, DefineBody, ImplementBody, SetupBody } from "../contracts/ports";
import { enterGate } from "./gates";
import { type Move, enterStep } from "./steps";
import type { Awaiting, Entry, Policy, Position, Signal, Snapshot, TransitionOutput } from "./types";

type ResultSignal = Extract<Signal, { kind: "result" }>;
type OnOk = (p: Policy, s: Snapshot, body: unknown) => Move;

const unhandled = (s: Snapshot, what: string): Error => new Error(`no transition at ${s.at} for ${what}`);

/** Pick the move for a verdict or answer; values without a row yet are unhandled. */
const branch = (s: Snapshot, key: string, cases: Record<string, () => Move>): Move => {
  const next = Object.hasOwn(cases, key) ? cases[key] : undefined;
  if (!next) throw unhandled(s, `"${key}"`);
  return next();
};

const feedback = (b: DecideBody) => (b.comment === undefined ? {} : { feedback: b.comment });

/** ok results, by the position they arrive at. Gate answers are ok results of `principal.decide`. */
const onOk: { [P in Position]?: OnOk } = {
  setup: (p, s, body) => enterStep(p, { ...s, workspace: (body as SetupBody).path }, "define"),
  define: (p, s, body) => {
    const { criteria, runbook } = body as DefineBody;
    return enterGate(p, { ...s, criteria, runbook }, "accept");
  },
  accept: (p, s, body) => {
    const b = body as DecideBody;
    return branch(s, b.answer, {
      accept: () => enterStep(p, s, "implement"),
      adjust: () => enterStep(p, s, "define", feedback(b)),
    });
  },
  implement: (p, s, body) => enterStep(p, { ...s, changeset: (body as ImplementBody).changeset }, "check"),
  check: (p, s, body) => branch(s, (body as CheckBody).verdict, {
    pass: () => enterGate(p, { ...s, findings: [] }, "land"),
  }),
};

/** Principal answers carry `by` (I6); it is journaled, never checked (ADR 0003, 0005). */
const byOf = (awaiting: Awaiting, body: unknown): Pick<Entry, "by"> =>
  awaiting.port === "principal" ? { by: (body as DecideBody).by } : {};

const onResult = (p: Policy, s: Snapshot, sig: ResultSignal): TransitionOutput => {
  const awaiting = s.awaiting;
  if (awaiting === null || sig.id !== awaiting.id) throw unhandled(s, `stale result ${sig.id}`);
  if (sig.result.status !== "ok") throw unhandled(s, sig.result.status);

  const result: Ok<unknown> = sig.result;
  const handler = onOk[s.at];
  if (!handler) throw unhandled(s, "ok");
  const consumed: Snapshot = { ...s, awaiting: null, evidence: [...s.evidence, ...(result.evidence ?? [])] };
  const move = handler(p, consumed, result.body);

  const entry: Entry = {
    delivery: s.delivery, signal: sig, from: s.at, to: move.state.at,
    issued: move.commands.map((c) => c.id), ...byOf(awaiting, result.body),
  };
  return { ...move, entry };
};

export const transition = (p: Policy, s: Snapshot, sig: Signal): TransitionOutput => {
  switch (sig.kind) {
    case "result": return onResult(p, s, sig);
    default: throw unhandled(s, sig.kind);
  }
};
