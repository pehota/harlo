// The CLI (plan §5.1): one verb per call, one JSON line on stdout, exit codes 0–5.
// Config: `ship.config.json` in the working directory plus the machine layer (runner/config.ts).
import { hostname } from "node:os";
import type { DeliveryId, Result, WorkItem } from "./contracts/common";
import { anyResultSchema } from "./contracts/common";
import type { TrackerNextBody, TrackerReadBody } from "./contracts/ports";
import { schemaFor } from "./contracts/ports";
import { check } from "./contracts/validate";
import { isDeliveryId, isValidKey, parseCommandId } from "./core/ids";
import { isTerminal, type Snapshot } from "./core/types";
import { type Deps, type Pending, apply } from "./runner/apply";
import { type Config, ConfigError, loadConfig } from "./runner/config";
import { RunnerCallError, callRunnerOnly, spawnCommand } from "./runner/spawn";
import { stateClient } from "./runner/state";

const USAGE = `usage:
  ship start <key>
  ship next
  ship signal <delivery> <id> <result-json>
  ship signal <delivery> --blocked retry|stop [--comment <text>]
  ship stop <delivery> <outcome> <reason>
  ship changed <delivery>
  ship status [<delivery>]`;

/** Invalid CLI input (exit 1): nothing has been applied. */
class UsageError extends Error {
  override name = "UsageError";
}

type Ran = { exit: number; line: unknown };
type Ctx = { config: Config; deps: Deps };

const applied = async (ctx: Ctx, pending: Pending): Promise<Ran> => {
  const report = await apply(ctx.deps, pending);
  return { exit: report.exit, line: report.output };
};

/** `tracker.read{key}`; a WorkItem for another key is a failed read (exit 4). */
const readWorkItem = async (ctx: Ctx, key: string, delivery: DeliveryId | null): Promise<WorkItem> => {
  const { workItem } = await callRunnerOnly<TrackerReadBody>(ctx.config.adapters.tracker, "tracker", "read", { key }, delivery);
  if (workItem.key !== key) throw new RunnerCallError(`tracker.read ${key}: returned WorkItem ${workItem.key}`);
  return workItem;
};

const deliveryArg = (delivery: string): DeliveryId => {
  if (!isDeliveryId(delivery)) throw new UsageError(`not a Delivery id: ${delivery}`);
  return delivery;
};

/** The saved snapshot of a Delivery named on the command line; an unknown one is invalid input. */
const loadArg = async (ctx: Ctx, delivery: string): Promise<Snapshot> => {
  const { state } = await ctx.deps.state.load(deliveryArg(delivery));
  if (!state) throw new UsageError(`no Delivery ${delivery}`);
  return state;
};

const startKey = async (ctx: Ctx, key: string): Promise<Ran> => {
  if (!isValidKey(key)) throw new UsageError(`not a WorkItem key: ${key}`);
  const workItem = await readWorkItem(ctx, key, null); // a failed read: exit 4, the core is not called
  return applied(ctx, { kind: "start", workItem });
};

const next = async (ctx: Ctx): Promise<Ran> => {
  const { key } = await callRunnerOnly<TrackerNextBody>(ctx.config.adapters.tracker, "tracker", "next", {});
  return key === null ? { exit: 0, line: { delivery: null, issued: [], awaiting: null } } : startKey(ctx, key);
};

const parseJson = (text: string): unknown => {
  try {
    return JSON.parse(text);
  } catch {
    throw new UsageError("result-json is not JSON");
  }
};

const signal = async (ctx: Ctx, delivery: string, id: string, json: string): Promise<Ran> => {
  if (parseCommandId(id)?.delivery !== delivery) throw new UsageError(`id ${id} is not a command of ${delivery}`);
  const result = parseJson(json);
  const { awaiting } = await loadArg(ctx, delivery);
  // Awaited: the port/op's Result schema. Not awaited: the core ignores it, but its journal entry needs a Result.
  const schema = awaiting?.id === id ? schemaFor(awaiting.port, awaiting.op)?.result : anyResultSchema;
  const invalid = check(schema ?? anyResultSchema, result);
  if (invalid) throw new UsageError(`result-json: ${invalid}`);
  return applied(ctx, { kind: "signal", delivery, signal: { kind: "result", id, result: result as Result } });
};

/** `--blocked retry|stop [--comment ...]`: the recovery signal; the core ignores it unless the Delivery is blocked. */
const recover = async (ctx: Ctx, delivery: string, args: string[]): Promise<Ran> => {
  const [flag, action, ...rest] = args;
  if (flag !== "--blocked" || (action !== "retry" && action !== "stop")) throw new UsageError("--blocked takes retry or stop");
  if (rest.length !== 0 && !(rest.length === 2 && rest[0] === "--comment")) throw new UsageError("only --comment <text> may follow");
  await loadArg(ctx, delivery);
  const comment = rest[1];
  return applied(ctx, {
    kind: "signal", delivery, signal: { kind: "blocked_recovery", action, ...(comment === undefined ? {} : { comment }) },
  });
};

const stop = async (ctx: Ctx, delivery: string, outcome: string, reason: string): Promise<Ran> => {
  if (!ctx.config.policy.outcomes.includes(outcome)) throw new UsageError(`outcome ${outcome} is not in policy.outcomes`);
  await loadArg(ctx, delivery);
  return applied(ctx, { kind: "signal", delivery, signal: { kind: "stop", outcome, reason } });
};

const changed = async (ctx: Ctx, delivery: string): Promise<Ran> => {
  const { workItem: saved } = await loadArg(ctx, delivery);
  const workItem = await readWorkItem(ctx, saved.key, delivery);
  return applied(ctx, { kind: "signal", delivery, signal: { kind: "workItem_changed", workItem } });
};

/** Read-only: no core call, no save, no commands. */
const status = async (ctx: Ctx, delivery?: string): Promise<Ran> => {
  const summary = (s: Snapshot) => ({ delivery: s.delivery, at: s.at, awaiting: s.awaiting?.id ?? null });
  if (delivery !== undefined) return { exit: 0, line: { deliveries: [summary(await loadArg(ctx, delivery))] } };
  const ids = await ctx.deps.state.list();
  const loaded = await Promise.all(ids.map((d) => ctx.deps.state.load(d)));
  const open = loaded.flatMap(({ state }) => (state && !isTerminal(state.at) ? [summary(state)] : []));
  return { exit: 0, line: { deliveries: open } };
};

/** Verb → [min args, max args, run]. */
const VERBS: Record<string, [number, number, (ctx: Ctx, ...args: string[]) => Promise<Ran>]> = {
  start: [1, 1, (ctx, key) => startKey(ctx, key!)],
  next: [0, 0, next],
  signal: [3, 5, (ctx, d, ...rest) => {
    if (rest[0] === "--blocked") return recover(ctx, d!, rest);
    if (rest.length !== 2) throw new UsageError("signal: wrong number of arguments");
    return signal(ctx, d!, rest[0]!, rest[1]!);
  }],
  stop: [3, 3, (ctx, d, outcome, reason) => stop(ctx, d!, outcome!, reason!)],
  changed: [1, 1, (ctx, d) => changed(ctx, d!)],
  status: [0, 1, (ctx, d) => status(ctx, d)],
};

const run = async (argv: string[]): Promise<Ran> => {
  const [verb, ...args] = argv;
  const found = verb !== undefined && Object.hasOwn(VERBS, verb) ? VERBS[verb] : undefined;
  if (!found) throw new UsageError(verb === undefined ? "no verb" : `unknown verb ${verb}`);
  const [min, max, handler] = found;
  if (args.length < min || args.length > max) throw new UsageError(`${verb}: wrong number of arguments`);

  const config = loadConfig(process.cwd());
  const deps: Deps = {
    policy: config.policy,
    state: stateClient(config.adapters.state),
    spawn: (snap, command) => spawnCommand(config.adapters, snap, command),
    host: hostname(),
    now: () => new Date().toISOString(),
  };
  return handler({ config, deps }, ...args);
};

/** Errors that end the call before anything is applied, by exit code. */
const exitFor = (error: unknown): number | undefined =>
  error instanceof UsageError ? 1 : error instanceof ConfigError ? 2 : error instanceof RunnerCallError ? 4 : undefined;

try {
  const { exit, line } = await run(process.argv.slice(2));
  console.log(JSON.stringify(line));
  process.exit(exit);
} catch (error) {
  const exit = exitFor(error);
  if (exit === undefined) throw error;
  console.error(error instanceof Error ? error.message : String(error));
  if (exit === 1) console.error(USAGE);
  process.exit(exit);
}
