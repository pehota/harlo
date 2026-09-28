// Step → port/op/payload builders (plan §4 "run X"), and the command plumbing gates.ts shares.
import type { Port } from "../contracts/common";
import { commandId, nextId } from "./ids";
import type { Awaiting, Command, Outcome, Policy, Snapshot, Step } from "./types";

/** What a handler returns: the next state and the commands it issues, in order. */
export type Move = { state: Snapshot; commands: Command[] };

const allocate = (s: Snapshot, name: string) => {
  const next = nextId(s.seq, name);
  return { id: commandId(s.delivery, next.suffix), seq: next.seq };
};

const toCommand = (a: Awaiting): Command => ({ id: a.id, port: a.port, op: a.op, await: a.await, payload: a.payload });

/** Issue the one awaited command of a move (id named `name`) and record it as `awaiting`. */
export const awaitOn = (s: Snapshot, name: string, spec: Omit<Awaiting, "id" | "await">): Move => {
  const { id, seq } = allocate(s, name);
  const awaiting: Awaiting = { id, await: true, ...spec };
  return { state: { ...s, seq, awaiting }, commands: [toCommand(awaiting)] };
};

/**
 * Re-issue an awaited command under a new id of its name (retry, re-ask, answer back to its step).
 * A re-issued step command is the new lastRun.
 */
export const reissue = (s: Snapshot, a: Awaiting): Move => {
  const { id: _stale, await: _awaited, ...spec } = a;
  const move = awaitOn(s, a.kind === "ask" ? "ask" : a.node, spec);
  return a.kind === "run" ? { ...move, state: { ...move.state, lastRun: move.state.awaiting } } : move;
};

/** Append a fire command (not awaited, id named after its op). */
export const withFire = (move: Move, port: Port, op: string, payload: unknown): Move => {
  const { id, seq } = allocate(move.state, op);
  return { state: { ...move.state, seq }, commands: [...move.commands, { id, port, op, await: false, payload }] };
};

/** A snapshot field the position guarantees; null here is a core bug, not an input case. */
export const present = <F extends "criteria" | "runbook" | "changeset" | "workspace" | "outcome" | "lastRun" | "blockedAt" | "blockedCmd",
>(
  s: Snapshot, field: F,
): NonNullable<Snapshot[F]> => {
  const value = s[field];
  if (value === null) throw new Error(`snapshot.${field} is null at ${s.at}`);
  return value;
};

/** Close awaits this status; config validation guarantees it for the core's own outcomes (plan §3.5). */
const outcomeStatus = (p: Policy, outcome: Outcome): string => {
  const status = p.tracker.outcomes[outcome]?.status;
  if (status === undefined) throw new Error(`policy.tracker.outcomes.${outcome}.status is not set`);
  return status;
};

type Call = { port: Port; op: string; payload: Record<string, unknown> };
const STEP_CALL: Record<Step, (p: Policy, s: Snapshot) => Call> = {
  setup: () => ({ port: "workspace", op: "setup", payload: {} }),
  define: () => ({ port: "define", op: "run", payload: {} }),
  implement: (_, s) => ({ port: "implement", op: "run", payload: { criteria: present(s, "criteria"), findings: s.findings } }),
  check: (_, s) => ({ port: "check", op: "run", payload: { criteria: present(s, "criteria"), changeset: present(s, "changeset") } }),
  integrate: (_, s) => ({ port: "integrate", op: "run", payload: { changeset: present(s, "changeset") } }),
  deploy: (_, s) => ({ port: "deploy", op: "run", payload: { changeset: present(s, "changeset") } }),
  verify: (_, s) => ({ port: "verify", op: "run", payload: { runbook: present(s, "runbook") } }),
  close: (p, s) => ({ port: "tracker", op: "update", payload: { status: outcomeStatus(p, present(s, "outcome")) } }),
  teardown: (_, s) => ({ port: "workspace", op: "teardown", payload: { path: present(s, "workspace") } }),
};

/**
 * Enter a step (`run X`): reset retries, issue its awaited command with `extra` merged into the payload,
 * and fire `tracker.update` when policy maps the step to a status.
 */
export const enterStep = (p: Policy, s: Snapshot, step: Step, extra: Record<string, unknown> = {}): Move => {
  const entered: Snapshot = { ...s, at: step, retries: 0 };
  const { port, op, payload } = STEP_CALL[step](p, entered);
  const run = awaitOn(entered, step, { port, op, payload: { ...payload, ...extra }, node: step, kind: "run" });
  const ran: Move = { ...run, state: { ...run.state, lastRun: run.state.awaiting } };
  const status = p.tracker.steps[step];
  return status === undefined ? ran : withFire(ran, "tracker", "update", { status });
};

const outcomeText = (s: Snapshot): string => {
  const outcome = present(s, "outcome");
  return s.reason === null ? outcome : `${outcome}: ${s.reason}`;
};

/** Enter Close with an outcome: await its tracker status, and fire a comment when policy asks for one. */
export const enterClose = (p: Policy, s: Snapshot, outcome: Outcome): Move => {
  const close = enterStep(p, { ...s, outcome }, "close");
  const comment = p.tracker.outcomes[outcome]?.comment === true;
  return comment ? withFire(close, "tracker", "comment", { text: outcomeText(close.state) }) : close;
};

/**
 * `abandon(o, r)`: position abandoned with outcome and reason; fire the outcome's tracker status and comment
 * when policy sets them, then notify the Principal. No Teardown: the workspace is kept (I4).
 */
export const abandon = (p: Policy, s: Snapshot, outcome: Outcome, reason: string): Move => {
  const state: Snapshot = { ...s, at: "abandoned", awaiting: null, blockedAt: null, blockedCmd: null, outcome, reason };
  const mapping = p.tracker.outcomes[outcome];
  const updated = mapping?.status === undefined
    ? { state, commands: [] }
    : withFire({ state, commands: [] }, "tracker", "update", { status: mapping.status });
  const commented = mapping?.comment === true
    ? withFire(updated, "tracker", "comment", { text: outcomeText(state) })
    : updated;
  return withFire(commented, "principal", "notify", { text: `abandoned: ${outcomeText(state)}` });
};
