// Gates (plan §3.2, §4 "decide G"), step questions routed to the Principal (§4.5), and the evidence bundle (P9).
import type { Decide, DecidePoint, GateEvidence, PrincipalKind, Question } from "../contracts/common";
import type { AskPayload } from "../contracts/ports";
import { type Move, awaitOn } from "./steps";
import type { Awaiting, Gate, Node, Policy, Snapshot } from "./types";

/** Core constants, not config: the core branches on them. */
export const GATE_OPTIONS = {
  accept: ["accept", "adjust"],
  decision: ["keep_going", "accept", "stop"],
  land: ["approve", "rework", "rescope"],
  failure: ["fix_forward", "accept"],
  blocked: ["retry", "stop"],
} as const satisfies Record<DecidePoint, readonly string[]>;

/** An Integrate conflict's answers: the core owns them, whatever the adapter offered (Q2). */
export const CONFLICT_OPTIONS = ["resolved", "rework"] as const;

/** What the Principal sees: the core passes it through and never reads `evidence` (P9). */
export const evidenceBundle = (s: Snapshot): GateEvidence => ({
  workItem: s.workItem, criteria: s.criteria, runbook: s.runbook, changeset: s.changeset,
  findings: s.findings, evidence: s.evidence,
});

/** Await `principal.decide` at a decide point with its constant options (`decide G`). */
const awaitDecide = (s: Snapshot, on: DecidePoint, min: PrincipalKind): Move => {
  const options = [...GATE_OPTIONS[on]];
  const payload: Decide = { on, options, min, evidence: evidenceBundle(s) };
  return awaitOn(s, on, { port: "principal", op: "decide", payload, node: on, kind: "decide", options });
};

/** Enter a gate whose Minimum Principal is one policy value: reset retries and await `principal.decide`. */
export const enterGate = (p: Policy, s: Snapshot, gate: Exclude<Gate, "decision">): Move =>
  awaitDecide({ ...s, at: gate, retries: 0 }, gate, p.minimum[gate]);

/** Enter the Decision gate; the kind of decision picks the Minimum Principal (N rounds used → scope). */
export const enterDecision = (p: Policy, s: Snapshot, about: keyof Policy["minimum"]["decision"]): Move =>
  awaitDecide({ ...s, at: "decision", retries: 0 }, "decision", p.minimum.decision[about]);

/** Enter Blocked: `node` stayed failed past its cap; keep the failed command for `retry` (B2, B3). */
export const enterBlocked = (p: Policy, s: Snapshot, node: Node, failed: Awaiting): Move =>
  awaitDecide({ ...s, at: "blocked", blockedAt: node, blockedCmd: failed }, "blocked", p.minimum.blocked);

/** Minimum Principal for a question's `about`; an unknown category gets the strictest, person. */
const questionMinimum = (p: Policy, about: string): PrincipalKind =>
  (Object.hasOwn(p.minimum.question, about) ? p.minimum.question[about] : undefined) ?? "person";

/**
 * Route a step's question to the Principal (Q1, Q2): await `principal.ask` on the asking step's node.
 * The step's command stays lastRun so the answer can go back to it (Q3).
 */
export const enterAsk = (p: Policy, s: Snapshot, run: Awaiting, q: Question): Move => {
  const asked: Snapshot = { ...s, retries: 0, lastRun: run };
  const conflict = run.node === "integrate" && q.about === "conflict";
  const options = conflict ? [...CONFLICT_OPTIONS] : q.options;
  const choice = options === undefined ? {} : { options };
  const payload: AskPayload = { prompt: q.prompt, min: questionMinimum(p, q.about), ...choice, evidence: evidenceBundle(asked) };
  return awaitOn(asked, "ask", { port: "principal", op: "ask", payload, node: run.node, kind: "ask", about: q.about, ...choice });
};
