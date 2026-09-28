// Gates (plan §3.2, §4 "decide G"): option constants, the decide command and the evidence bundle (P9).
import type { Decide, DecidePoint, GateEvidence, PrincipalKind } from "../contracts/common";
import { type Move, awaitOn } from "./steps";
import type { Gate, Policy, Snapshot } from "./types";

/** Core constants, not config: the core branches on them. */
export const GATE_OPTIONS = {
  accept: ["accept", "adjust"],
  decision: ["keep_going", "accept", "stop"],
  land: ["approve", "rework", "rescope"],
  failure: ["fix_forward", "accept"],
  blocked: ["retry", "stop"],
} as const satisfies Record<DecidePoint, readonly string[]>;

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
