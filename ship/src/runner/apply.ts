// The apply loop (plan §5.2): load → core → save → execute, with CAS retry. Save before execute: nothing is
// sent until the state that awaits it is saved. Every command runs, whatever an earlier one returned; valid
// immediate Results are queued and applied in the same loop.
import type { CommandId, DeliveryId, WorkItem } from "../contracts/common";
import type { TimedEntry } from "../contracts/snapshot";
import { start } from "../core/start";
import { transition } from "../core/transition";
import type { Command, Entry, Note, Policy, RunnerSignal, Signal, Snapshot } from "../core/types";
import type { Reply, Spawned } from "./spawn";
import type { State } from "./state";

export type Deps = {
  policy: Policy;
  state: State;
  spawn: (snap: Snapshot, command: Command) => Spawned;
  host: string; // for `sent` entries
  now: () => string; // the Runner stamps `time`; the core has no clock
};

/** A signal waiting to be applied: a start for a WorkItem, or a signal for a Delivery. */
export type Pending =
  | { kind: "start"; workItem: WorkItem }
  | { kind: "signal"; delivery: DeliveryId; signal: Signal };

/** The CLI's JSON line (§5.1). */
export type Output = {
  delivery: DeliveryId | null;
  issued: CommandId[];
  awaiting: CommandId | null;
  ignored?: true;
  rejected?: true;
  unapplied?: (Signal | { kind: "start"; workItem: WorkItem })[];
  errors?: { id: CommandId; info: string }[];
};
export type Report = { exit: 0 | 3 | 5; output: Output };

const TRIES = 5;
const IGNORED: ReadonlySet<Note | undefined> = new Set<Note | undefined>(["ignored_stale", "ignored_terminal", "workitem_unchanged"]);

/** One core application, ready to save as `version` of `delivery`. */
type Planned = {
  delivery: DeliveryId;
  version: number;
  state: Snapshot;
  commands: Command[];
  entry: Entry;
  rejected: boolean;
};

const stamp = (deps: Deps, entry: Entry): TimedEntry => ({ ...entry, time: deps.now() });

const loadExisting = async (state: State, delivery: DeliveryId): Promise<{ version: number; state: Snapshot }> => {
  const loaded = await state.load(delivery);
  if (!loaded.state) throw new Error(`runner bug: no saved Delivery ${delivery}`);
  return { version: loaded.version, state: loaded.state };
};

/** A start (§5.1): the key's Deliveries → core.start → a new version 1, or the entry on the open Delivery. */
const planStart = async (deps: Deps, workItem: WorkItem): Promise<Planned> => {
  const ids = await deps.state.list(workItem.key);
  const loaded = await Promise.all(ids.map((d) => loadExisting(deps.state, d)));
  const out = start(deps.policy, workItem, loaded.map((l) => l.state));
  if (out.kind === "created") {
    return { delivery: out.state.delivery, version: 1, state: out.state, commands: out.commands, entry: out.entry, rejected: false };
  }
  const open = loaded.find((l) => l.state.delivery === out.delivery);
  if (!open) throw new Error(`runner bug: start rejected on unloaded ${out.delivery}`);
  return { delivery: out.delivery, version: open.version + 1, state: open.state, commands: [], entry: out.entry, rejected: true };
};

const planSignal = async (deps: Deps, delivery: DeliveryId, signal: Signal): Promise<Planned> => {
  const { version, state } = await loadExisting(deps.state, delivery);
  const out = transition(deps.policy, state, signal);
  return { delivery, version: version + 1, ...out, rejected: false };
};

/** Apply one pending signal with CAS: reload and re-run the (pure) core on a conflict, up to TRIES times. */
const applyOnce = async (deps: Deps, pending: Pending): Promise<Planned | null> => {
  for (let attempt = 1; attempt <= TRIES; attempt += 1) {
    const planned = pending.kind === "start"
      ? await planStart(deps, pending.workItem)
      : await planSignal(deps, pending.delivery, pending.signal);
    const saved = await deps.state.save(planned.delivery, planned.version, planned.state, [stamp(deps, planned.entry)]);
    if (saved) return planned;
  }
  return null;
};

/**
 * Journal Runner-written entries: save the unchanged state as the next version. The entries do not depend on
 * the state, so a conflict only means reload and save again.
 */
const journal = async (deps: Deps, delivery: DeliveryId, signal: RunnerSignal, info?: string): Promise<void> => {
  for (;;) {
    const { version, state } = await loadExisting(deps.state, delivery);
    const entry: Entry = { delivery, signal, from: state.at, to: state.at, issued: [], ...(info === undefined ? {} : { info }) };
    if (await deps.state.save(delivery, version + 1, state, [stamp(deps, entry)])) return;
  }
};

type Executed = { queued?: Pending; error?: { id: CommandId; info: string }; crashed?: true };

/** Run one command: journal `sent` once its process exists, then map what it did (§5.2, §5.3). */
const execute = async (deps: Deps, planned: Planned, command: Command): Promise<Executed> => {
  const spawned = deps.spawn(planned.state, command);
  const sentThenExit = async ({ pid, started, done }: Extract<Spawned, { spawned: true }>): Promise<Reply> => {
    await journal(deps, planned.delivery, { kind: "sent", id: command.id, pid, host: deps.host, started });
    return done;
  };
  const reply = spawned.spawned ? await sentThenExit(spawned) : spawned.reply; // a spawn error ran nothing: no `sent`

  switch (reply.kind) {
    case "result":
      return { queued: { kind: "signal", delivery: planned.delivery, signal: { kind: "result", id: command.id, result: reply.result } } };
    case "accepted":
      await journal(deps, planned.delivery, { kind: "accepted", id: command.id });
      return {};
    case "crash":
      await journal(deps, planned.delivery, { kind: "adapter_error", id: command.id }, `${reply.reason}\n${reply.stderr}`);
      return { crashed: true };
    case "fire_error":
      return { error: { id: command.id, info: reply.info } };
    case "fired":
      return {};
  }
};

const signalOf = (pending: Pending): Signal | { kind: "start"; workItem: WorkItem } =>
  pending.kind === "start" ? pending : pending.signal;

const cancelsFirst = (commands: Command[]): Command[] => [
  ...commands.filter((c) => c.op === "cancel"),
  ...commands.filter((c) => c.op !== "cancel"),
];

/** Apply `first` and every immediate Result it leads to. Exit 3: CAS never cleared; exit 5: an awaited crash. */
export const apply = async (deps: Deps, first: Pending): Promise<Report> => {
  const queue: Pending[] = [first];
  const issued: CommandId[] = [];
  const errors: { id: CommandId; info: string }[] = [];
  let crashed = false;
  let head: Planned | null = null; // the first application: decides ignored / rejected
  let last: Planned | null = null;

  const output = (): Output => ({
    delivery: last?.delivery ?? null,
    issued,
    awaiting: last?.state.awaiting?.id ?? null,
    ...(head && IGNORED.has(head.entry.note) ? { ignored: true as const } : {}),
    ...(head?.rejected ? { rejected: true as const } : {}),
    ...(errors.length > 0 ? { errors } : {}),
  });

  for (let pending = queue.shift(); pending; pending = queue.shift()) {
    const planned = await applyOnce(deps, pending);
    if (!planned) return { exit: 3, output: { ...output(), unapplied: [pending, ...queue].map(signalOf) } };
    head ??= planned;
    last = planned;
    issued.push(...planned.commands.map((c) => c.id));

    for (const command of cancelsFirst(planned.commands)) {
      const executed = await execute(deps, planned, command);
      if (executed.queued) queue.push(executed.queued);
      if (executed.error) errors.push(executed.error);
      if (executed.crashed) crashed = true;
    }
  }
  return { exit: crashed ? 5 : 0, output: output() };
};
