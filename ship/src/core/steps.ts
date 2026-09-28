// Step → port/op/payload builders (plan §4 "run X"), and the command plumbing gates.ts shares.
import type { Port } from "../contracts/common";
import { commandId, nextId } from "./ids";
import type { Awaiting, Command, Policy, Snapshot, Step } from "./types";

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

/** Append a fire command (not awaited, id named after its op). */
export const withFire = (move: Move, port: Port, op: string, payload: unknown): Move => {
  const { id, seq } = allocate(move.state, op);
  return { state: { ...move.state, seq }, commands: [...move.commands, { id, port, op, await: false, payload }] };
};

/** A snapshot field the position guarantees; null here is a core bug, not an input case. */
const present = <F extends "criteria" | "changeset">(s: Snapshot, field: F): NonNullable<Snapshot[F]> => {
  const value = s[field];
  if (value === null) throw new Error(`snapshot.${field} is null at ${s.at}`);
  return value;
};

type Call = { port: Port; op: string; payload: Record<string, unknown> };
const STEP_CALL: { [S in Step]?: (s: Snapshot) => Call } = {
  setup: () => ({ port: "workspace", op: "setup", payload: {} }),
  define: () => ({ port: "define", op: "run", payload: {} }),
  implement: (s) => ({ port: "implement", op: "run", payload: { criteria: present(s, "criteria"), findings: s.findings } }),
  check: (s) => ({ port: "check", op: "run", payload: { criteria: present(s, "criteria"), changeset: present(s, "changeset") } }),
};

/**
 * Enter a step (`run X`): reset retries, issue its awaited command with `extra` merged into the payload,
 * and fire `tracker.update` when policy maps the step to a status.
 */
export const enterStep = (p: Policy, s: Snapshot, step: Step, extra: Record<string, unknown> = {}): Move => {
  const call = STEP_CALL[step];
  if (!call) throw new Error(`no command for step ${step} yet`);
  const entered: Snapshot = { ...s, at: step, retries: 0 };
  const { port, op, payload } = call(entered);
  const run = awaitOn(entered, step, { port, op, payload: { ...payload, ...extra }, node: step, kind: "run" });
  const ran: Move = { ...run, state: { ...run.state, lastRun: run.state.awaiting } };
  const status = p.tracker.steps[step];
  return status === undefined ? ran : withFire(ran, "tracker", "update", { status });
};
