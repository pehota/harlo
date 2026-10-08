// start(): create the next Delivery for a WorkItem, or reject while one is still open (plan §4.1).
import type { WorkItem } from "../contracts/common";
import { deliveryId } from "./ids";
import { enterStep } from "./steps";
import { isTerminal, type Policy, type Snapshot, type StartOutput } from "./types";

const fresh = (delivery: string, workItem: WorkItem): Snapshot => ({
  v: 1, delivery, workItem, at: "setup",
  blockedAt: null, awaiting: null, lastRun: null, blockedCmd: null,
  seq: {}, retries: 0, blockedCount: 0, fixRounds: 0,
  workspace: null, requirements: null, changeset: null,
  findings: [], evidence: [], outcome: null, reason: null,
});

export const start = (p: Policy, workItem: WorkItem, existing: Snapshot[]): StartOutput => {
  const signal = { kind: "start", workItem } as const;
  const earlier = existing.filter((s) => s.workItem.key === workItem.key); // a shared prefix is another key (S6)
  const open = earlier.find((s) => !isTerminal(s.at));
  if (open) {
    const entry = { delivery: open.delivery, signal, from: open.at, to: open.at, issued: [], note: "rejected_start" as const };
    return { kind: "rejected", delivery: open.delivery, entry };
  }

  const delivery = deliveryId(workItem.key, earlier.length + 1);
  const setup = enterStep(p, fresh(delivery, workItem), "setup");
  const entry = { delivery, signal, from: null, to: setup.state.at, issued: setup.commands.map((c) => c.id) };
  return { kind: "created", state: setup.state, commands: setup.commands, entry };
};
