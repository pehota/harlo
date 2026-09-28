// Step → port/op/payload builders (plan §4 "run X"), and the command plumbing gates.ts shares.
import type { Port } from "../contracts/common";
import { commandId, nextId } from "./ids";
import type { Awaiting, Command, Snapshot, Step } from "./types";

/** What a handler returns: the next state and the commands it issues, in order. */
export type Move = { state: Snapshot; commands: Command[] };

const allocate = (s: Snapshot, name: string) => {
  const next = nextId(s.seq, name);
  return { id: commandId(s.delivery, next.suffix), seq: next.seq };
};

export const toCommand = (a: Awaiting): Command => ({ id: a.id, port: a.port, op: a.op, await: a.await, payload: a.payload });

/** Issue the one awaited command of a move (id named `name`) and record it as `awaiting`. */
export const awaitOn = (s: Snapshot, name: string, spec: Omit<Awaiting, "id" | "await">): Move => {
  const { id, seq } = allocate(s, name);
  const awaiting: Awaiting = { id, await: true, ...spec };
  return { state: { ...s, seq, awaiting }, commands: [toCommand(awaiting)] };
};

type Call = { port: Port; op: string; payload: Record<string, unknown> };
const STEP_CALL: { [S in Step]?: (s: Snapshot) => Call } = {
  setup: () => ({ port: "workspace", op: "setup", payload: {} }),
};

/** Enter a step: reset retries and issue its awaited command (`run X`). */
export const enterStep = (s: Snapshot, step: Step): Move => {
  const call = STEP_CALL[step];
  if (!call) throw new Error(`no command for step ${step} yet`);
  const entered: Snapshot = { ...s, at: step, retries: 0 };
  const run = awaitOn(entered, step, { ...call(entered), node: step, kind: "run" });
  return { ...run, state: { ...run.state, lastRun: run.state.awaiting } };
};
