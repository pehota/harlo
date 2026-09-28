// transition(): apply one signal to a Delivery (plan §4). Dispatch is by position (Snapshot.at).
import type { Finding, Question, Result } from "../contracts/common";
import type {
  AskBody, CheckBody, DecideBody, DefineBody, DeployBody, ImplementBody, IntegrateBody, SetupBody, VerifyBody,
} from "../contracts/ports";
import { enterAsk, enterBlocked, enterDecision, enterGate } from "./gates";
import { type Move, abandon, enterClose, enterStep, present, reissue, withFire } from "./steps";
import {
  isTerminal, type Awaiting, type Entry, type Note, type Policy, type Position, type Signal, type Snapshot,
  type TransitionOutput,
} from "./types";

type ResultSignal = Extract<Signal, { kind: "result" }>;
type OnOk = (p: Policy, s: Snapshot, body: unknown) => Move;
type Applied = Move & { note?: Note }; // a move plus the note its entry carries

const unhandled = (s: Snapshot, what: string): Error => new Error(`no transition at ${s.at} for ${what}`);

/** Pick the move for a gate answer; an answer outside the cases is unhandled. */
const branch = (s: Snapshot, key: string, cases: Record<string, () => Move>): Move => {
  const next = Object.hasOwn(cases, key) ? cases[key] : undefined;
  if (!next) throw unhandled(s, `"${key}"`);
  return next();
};

type VerdictCases<B extends { verdict: string }> = { [V in B["verdict"]]?: (b: Extract<B, { verdict: V }>) => Move };

/** Pick the move for a step's verdict, narrowed to that verdict's body. */
const onVerdict = <B extends { verdict: string }>(s: Snapshot, body: B, cases: VerdictCases<B>): Move => {
  const verdict: B["verdict"] = body.verdict;
  const next = Object.hasOwn(cases, verdict) ? cases[verdict] : undefined;
  if (!next) throw unhandled(s, `"${verdict}"`);
  return (next as (b: B) => Move)(body);
};

/** Teardown done: the Delivery is Closed and the Principal is told (H12). */
const enterClosed = (s: Snapshot): Move =>
  withFire({ state: { ...s, at: "closed" }, commands: [] }, "principal", "notify", { text: `closed: ${present(s, "outcome")}` });

const feedback = (b: DecideBody) => (b.comment === undefined ? {} : { feedback: b.comment });

/** A `fix` verdict from Check or Integrate: another fix round while rounds are left, else the Decision gate. */
const fixRound = (p: Policy, s: Snapshot, findings: Finding[]): Move =>
  s.fixRounds < p.fixRounds
    ? enterStep(p, { ...s, findings, fixRounds: s.fixRounds + 1 }, "implement")
    : enterDecision(p, { ...s, findings }, "scope");

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
  check: (p, s, body) => onVerdict(s, body as CheckBody, {
    pass: () => enterGate(p, { ...s, findings: [] }, "land"),
    fix: (b) => fixRound(p, s, b.findings),
    decide: (b) => enterDecision(p, { ...s, findings: b.findings }, b.about),
  }),
  decision: (p, s, body) => {
    const b = body as DecideBody;
    return branch(s, b.answer, {
      keep_going: () => enterStep(p, { ...s, fixRounds: 0 }, "implement"),
      accept: () => enterGate(p, s, "land"),
      stop: () => abandon(p, s, "abandoned", b.comment ?? "stopped at decision"),
    });
  },
  land: (p, s, body) => {
    const b = body as DecideBody;
    return branch(s, b.answer, {
      approve: () => enterStep(p, s, "integrate"),
      rework: () => enterStep(p, s, "implement", feedback(b)),
      rescope: () => enterStep(p, s, "define", feedback(b)),
    });
  },
  integrate: (p, s, body) => onVerdict(s, body as IntegrateBody, {
    landed: () => enterStep(p, s, "deploy"),
    fix: (b) => fixRound(p, s, b.findings),
  }),
  deploy: (p, s, body) => onVerdict(s, body as DeployBody, {
    live: () => enterStep(p, s, "verify"),
    not_live: (b) => enterGate(p, { ...s, findings: b.findings ?? [] }, "failure"),
  }),
  verify: (p, s, body) => onVerdict(s, body as VerifyBody, {
    pass: () => enterClose(p, s, "delivered"),
    fail: (b) => enterGate(p, { ...s, findings: b.findings }, "failure"),
  }),
  failure: (p, s, body) => branch(s, (body as DecideBody).answer, {
    fix_forward: () => enterStep(p, s, "implement"),
    accept: () => enterClose(p, s, "accepted_with_failure"),
  }),
  close: (p, s) => enterStep(p, s, "teardown"),
  blocked: (p, s, body) => {
    const b = body as DecideBody;
    const node = present(s, "blockedAt");
    return branch(s, b.answer, {
      retry: () => reissue({ ...s, at: node, retries: 0, blockedAt: null, blockedCmd: null }, present(s, "blockedCmd")),
      stop: () => abandon(p, s, "abandoned", b.comment ?? `stopped at blocked ${node}`),
    });
  },
  teardown: (_, s) => enterClosed(s),
};

/** Journal the signal and change nothing (I5). */
const ignore = (s: Snapshot, sig: Signal, note: Note): TransitionOutput => ({
  state: s, commands: [], entry: { delivery: s.delivery, signal: sig, from: s.at, to: s.at, issued: [], note },
});

/** Principal answers carry `by` (I6); it is journaled, never checked (ADR 0003, 0005). */
const byOf = (awaiting: Awaiting, result: Result): Pick<Entry, "by"> =>
  awaiting.port === "principal" && result.status === "ok" ? { by: (result.body as DecideBody).by } : {};

const ASKING: ReadonlySet<Position> = new Set(["define", "implement", "check", "integrate", "deploy", "verify"]);

/** Only step ports raise questions (the Runner rejects the rest); the question goes to the Principal. */
const onQuestion = (p: Policy, s: Snapshot, awaiting: Awaiting, q: Question): Move => {
  if (awaiting.kind !== "run" || !ASKING.has(s.at)) throw unhandled(s, "question");
  return enterAsk(p, s, awaiting, q);
};

/** An ask answered: back to its step with the answer (Q3, Q4), or a conflict's rework → Implement (Q5). */
const onAsk = (p: Policy, s: Snapshot, asked: Awaiting, value: string): Move => {
  if (asked.node === "integrate" && asked.about === "conflict" && value === "rework") return enterStep(p, s, "implement");
  const run = present(s, "lastRun");
  return reissue({ ...s, retries: 0 }, { ...run, payload: { ...(run.payload as object), answer: value } });
};

/**
 * `failed` changed nothing, so re-issue it up to the node's cap (an ask uses its step's cap), then Blocked.
 * The Principal failing at Blocked leaves it awaiting nothing; only a Delivery signal moves it (B6).
 */
const onFailed = (p: Policy, s: Snapshot, failed: Awaiting): Move => {
  if (failed.node === "blocked") return { state: s, commands: [] };
  const cap = p.retryCap[failed.node] ?? p.retryCap.default;
  return s.retries < cap
    ? reissue({ ...s, retries: s.retries + 1 }, failed)
    : enterBlocked(p, s, failed.node, failed);
};

/** A step's ok result or a gate's answer, by the position it arrives at. */
const onPosition = (p: Policy, s: Snapshot, body: unknown): Move => {
  const handler = onOk[s.at];
  if (!handler) throw unhandled(s, "ok");
  return handler(p, s, body);
};

/** A Principal's answer (decide or ask ok); one outside the allowed options is re-asked (Q6, B5, B7). */
const onAnswer = (p: Policy, s: Snapshot, awaiting: Awaiting, body: unknown): Applied => {
  const value = (body as AskBody).answer;
  if (awaiting.options !== undefined && !awaiting.options.includes(value)) {
    return { ...reissue(s, awaiting), note: "invalid_answer" };
  }
  if (awaiting.kind === "ask") return onAsk(p, s, awaiting, value);
  return onPosition(p, s, body);
};

/** The awaited command's Result, applied to the state that no longer awaits it. */
const onAwaited = (p: Policy, s: Snapshot, awaiting: Awaiting, result: Result): Applied => {
  switch (result.status) {
    case "question": return onQuestion(p, s, awaiting, result);
    case "failed": return onFailed(p, s, awaiting);
    case "ok": return awaiting.kind === "run" ? onPosition(p, s, result.body) : onAnswer(p, s, awaiting, result.body);
  }
};

const onResult = (p: Policy, s: Snapshot, sig: ResultSignal): TransitionOutput => {
  const awaiting = s.awaiting;
  if (awaiting === null || sig.id !== awaiting.id) return ignore(s, sig, "ignored_stale"); // R1

  const result = sig.result;
  const passed = result.status === "failed" ? [] : result.evidence ?? []; // appended, never read (P9)
  const consumed: Snapshot = { ...s, awaiting: null, evidence: [...s.evidence, ...passed] };
  const { note, ...move } = onAwaited(p, consumed, awaiting, result);

  const entry: Entry = {
    delivery: s.delivery, signal: sig, from: s.at, to: move.state.at,
    issued: move.commands.map((c) => c.id), ...byOf(awaiting, result), ...(note === undefined ? {} : { note }),
  };
  return { ...move, entry };
};

export const transition = (p: Policy, s: Snapshot, sig: Signal): TransitionOutput => {
  if (isTerminal(s.at)) return ignore(s, sig, "ignored_terminal"); // R2
  switch (sig.kind) {
    case "result": return onResult(p, s, sig);
    default: throw unhandled(s, sig.kind);
  }
};
