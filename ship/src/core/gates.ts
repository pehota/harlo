// Gates (plan §3.2, §4 "decide G"): option constants, the decide command and the evidence bundle (P9).
import type { Decide, DecidePoint, GateEvidence } from "../contracts/common";
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

/** Enter a gate whose Minimum Principal is one policy value: reset retries and await `principal.decide`. */
export const enterGate = (p: Policy, s: Snapshot, gate: Exclude<Gate, "decision">): Move => {
  const entered: Snapshot = { ...s, at: gate, retries: 0 };
  const options = [...GATE_OPTIONS[gate]];
  const payload: Decide = { on: gate, options, min: p.minimum[gate], evidence: evidenceBundle(entered) };
  return awaitOn(entered, gate, { port: "principal", op: "decide", payload, node: gate, kind: "decide", options });
};
