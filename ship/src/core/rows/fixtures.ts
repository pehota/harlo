// Shared row fixtures for the core tables (plan §4). Every table under rows/ is built from these, so
// invariants.test.ts can sweep all rows with the same default Policy.
import type { CommandId, DeliveryId, Port, WorkItem } from "../../contracts/common";
import { parseCommandId } from "../ids";
import type { Awaiting, Command, Entry, Policy, Position, Snapshot } from "../types";

/** A start row (§4.1). A rejected start issues no commands. */
export type StartRow = {
  id: string;
  name: string;
  policy?: Policy;
  workItem: WorkItem;
  existing: Snapshot[];
  expect: {
    kind: "created" | "rejected";
    delivery: DeliveryId;
    commands: Command[];
    state?: Partial<Snapshot>; // created only
    entry: Pick<Entry, "from" | "to" | "issued" | "note">;
  };
};

export const D: DeliveryId = "k-1";
export const workItem: WorkItem = { key: "k", title: "Greet by name", body: "Say hello to the given name." };
export const workspace = "/ws/k-1";
export const criteria = ["greets the given name"];
export const runbook = ["run greet Ada and read the output"];
export const changeset = "cs-1";

export const policy: Policy = {
  fixRounds: 2,
  retryCap: { default: 1 },
  minimum: {
    accept: "person", land: "person", failure: "person", blocked: "person",
    decision: { scope: "person", advisory: "model" },
    question: { clarify: "model" },
  },
  outcomes: ["rolled_back", "abandoned"],
  tracker: {
    steps: {},
    outcomes: {
      delivered: { status: "done" },
      accepted_with_failure: { status: "done", comment: true },
      rolled_back: { status: "reopened", comment: true },
      abandoned: { comment: true },
    },
  },
};

export const id = (suffix: string, delivery: DeliveryId = D): CommandId => `${delivery}/${suffix}`;

/** An awaited command as the snapshot records it. */
export const awaited = (
  suffix: string, port: Port, op: string, payload: unknown, node: Awaiting["node"], kind: Awaiting["kind"],
  options?: string[],
): Awaiting => ({
  id: id(suffix), port, op, await: true, payload, node, kind, ...(options ? { options } : {}),
});

/** The command the core issues for an awaited entry (without node/kind/options). */
export const cmd = (a: Awaiting): Command => ({ id: a.id, port: a.port, op: a.op, await: a.await, payload: a.payload });

/**
 * A snapshot at `at` awaiting `awaiting`. Data fields are filled as if every step had run; rows override
 * what they pin. `seq` defaults to just the awaiting id's counter.
 */
export const snapshotAt = (at: Position, awaiting: Awaiting | null, over: Partial<Snapshot> = {}): Snapshot => {
  const parsed = awaiting ? parseCommandId(awaiting.id) : null;
  const seq = parsed ? { [parsed.name]: parsed.n } : {};
  return {
    v: 1, delivery: D, workItem, at,
    blockedAt: null, awaiting, lastRun: awaiting?.kind === "run" ? awaiting : null, blockedCmd: null,
    seq, retries: 0, fixRounds: 0,
    workspace, criteria, runbook, changeset, findings: [], evidence: [], outcome: null, reason: null,
    ...over,
  };
};
