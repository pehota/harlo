#!/usr/bin/env bun
// Queue loop (plan §6 M1.14; Bun/TS, environment code). The environment-owned loop that drains the tracker,
// one Delivery at a time: `ship next` picks the next ready WorkItem and starts its Delivery, `driveDelivery`
// (`env/drive-loop.ts`, the same per-pass loop `env/drive.ts` runs) drives it until `at` is closed or abandoned,
// then the next one is picked — until `ship next` says `delivery: null`. Like drive.ts it never answers a gate
// itself: a human (or the Principal adapter) does, while the loop waits. Closed and abandoned are both "move on":
// an abandoned item is already marked by the tracker mapping (its reason is a tracker comment); the queue makes
// no decision about it.
//
// Before the first `ship next` it drives every already-open Delivery (`ship status`, no arg) to terminal:
// orphans of an earlier, interrupted run go first, so the queue never starts a second Delivery alongside one.
//
// Re-pick guard: a WorkItem whose status never leaves `ready` (no `policy.tracker.steps` entry moves it, and
// its outcome mapping sets no status) would be picked again forever. A key picked a second time in one run gets
// its new Delivery stopped as `abandoned` with that reason, and the queue exits 3 (1 if that stop fails: the
// Delivery then stays open).
//
// One queue per State: an exclusive lockfile (atomic create) guards the run. It is removed on every exit (drain,
// errors, exit 3, SIGINT/SIGTERM/SIGHUP) except SIGKILL, which leaves it stale — and only while it still holds this
// run's token (pid + random id): a lock another run took since is kept.
// A stale one (from a killed process) is left for a person to delete — the queue never guesses.
//
// ponytail: no --concurrency flag — one Delivery at a time, deliberately. Parallel Deliveries are the open
// discovery issue pehota/harlo#50; add it only once that settles what may safely run side by side.
//
// argv: [--repo <path>] [--interval <ms>] [--grace <ms>] [--max-runtime <ms>] [--lock <path>]
//       [--ship <path to bin/ship>] [--state <state-adapter argv…>]
//   The repo is `--repo`'s git root (default: the cwd's). `ship` and the pollers run with the repo root as their
//   cwd, since `ship` reads `ship.config.json` from its working directory. `--ship` defaults to this checkout's
//   `bin/ship`; `--state` defaults to the repo's machine config's `state` argv, found as `ship` finds it
//   (env/repo-config.ts). Both are overrides: given both and no `--repo`, nothing is resolved and every call
//   inherits this process's cwd, as before. `--state` takes the rest of argv; `--grace`/`--max-runtime` are
//   forwarded to `poll/stalled.ts` only when given; `--interval` defaults to 5000ms. `--lock` defaults to
//   `.ship-queue.lock` in the repo root (in the cwd under the bare override).
// exit: 0 queue drained · 1 a `ship` call failed, or the repo/config cannot be resolved · 2 lock already held ·
//   3 re-pick guard fired
import { randomUUID } from "node:crypto";
import { closeSync, openSync, readFileSync, rmSync, writeSync } from "node:fs";
import { join, resolve } from "node:path";
import type { DeliveryId } from "../src/contracts/common";
import { type StatusBody, driveDelivery, runShip } from "./drive-loop";
import { RepoConfigError, SHIP_BIN, gitRoot, repoConfig } from "./repo-config";

const DEFAULT_INTERVAL_MS = 5000;
const DEFAULT_LOCK = ".ship-queue.lock";

type Options = {
  ship: string; interval: number; grace: string | undefined; maxRuntime: string | undefined;
  lock: string; state: string[]; cwd: string | undefined;
};

const parseArgs = (args: string[]) => {
  const stateAt = args.indexOf("--state");
  const head = stateAt === -1 ? args : args.slice(0, stateAt);
  const state = stateAt === -1 ? [] : args.slice(stateAt + 1);
  const flag = (name: string) => { const at = head.indexOf(name); return at === -1 ? undefined : head[at + 1]; };
  const interval = flag("--interval");
  return {
    repo: flag("--repo"), ship: flag("--ship"), interval: interval === undefined ? DEFAULT_INTERVAL_MS : Number(interval),
    grace: flag("--grace"), maxRuntime: flag("--max-runtime"), lock: flag("--lock"), state,
  };
};

/** The repo root (the calls' cwd), `bin/ship`, the State argv and the lock: flags first, the repo's config otherwise. */
const resolveOptions = (args: ReturnType<typeof parseArgs>): Options => {
  const { repo, ship, lock, state, ...rest } = args;
  const bareOverride = repo === undefined && ship !== undefined && state.length > 0;
  const root = bareOverride ? undefined : gitRoot(repo ?? process.cwd());
  return {
    ...rest,
    cwd: root,
    ship: ship === undefined ? SHIP_BIN : ship.includes("/") ? resolve(ship) : ship, // a relative path, from here
    state: state.length > 0 ? state : repoConfig(root!).state,
    lock: lock ?? (root === undefined ? DEFAULT_LOCK : join(root, DEFAULT_LOCK)),
  };
};

/** A failed `ship` call: the queue stops with exit 1. */
class ShipCallError extends Error {}

/** The `delivery` a `ship` output line names, if it is JSON and names one. */
const deliveryIn = (stdout: string): string | undefined => {
  try {
    const { delivery } = JSON.parse(stdout) as { delivery?: unknown };
    return typeof delivery === "string" ? delivery : undefined;
  } catch {
    return undefined;
  }
};

/** One `ship <args…>` call whose JSON stdout line is returned; a nonzero exit is a ShipCallError. */
const shipJson = async <T>(options: Options, args: string[]): Promise<T> => {
  const ran = await runShip(options.ship, args, options.cwd);
  if (ran.exitCode !== 0) {
    const delivery = deliveryIn(ran.stdout); // e.g. exit 5: the Delivery was created, then an adapter crashed
    const named = delivery === undefined ? "" : ` (Delivery ${delivery})`;
    throw new ShipCallError(`ship ${args.join(" ")}: exit ${ran.exitCode}${named}\n${ran.stderr}`);
  }
  return JSON.parse(ran.stdout) as T;
};

/** Removes the lockfile only while it still holds this run's token: never another run's lock. */
const releaseLock = (lock: string, token: string): void => {
  try {
    if (readFileSync(lock, "utf8") === token) rmSync(lock);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
};

/** Atomically create the lockfile with a per-run token; false when it already exists. Released on any exit. */
const acquireLock = (lock: string): boolean => {
  const token = `${process.pid} ${randomUUID()}\n`;
  try {
    const fd = openSync(lock, "wx");
    writeSync(fd, token);
    closeSync(fd);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") return false;
    throw error;
  }
  process.on("exit", () => releaseLock(lock, token));
  process.on("SIGINT", () => process.exit(130));
  process.on("SIGTERM", () => process.exit(143));
  process.on("SIGHUP", () => process.exit(129)); // the terminal closed
  return true;
};

/** `<key>-<attempt>` → `<key>`. */
const keyOf = (delivery: DeliveryId): string => delivery.replace(/-\d+$/, "");

/** Orphans first, then `ship next` until empty. Returns the exit code. */
const drain = async (options: Options): Promise<number> => {
  const { ship, cwd } = options;
  const handled = new Set<string>();
  const driveToEnd = async (delivery: DeliveryId): Promise<void> => {
    const at = await driveDelivery({ ...options, delivery });
    handled.add(keyOf(delivery));
    console.log(`${delivery}: done at=${at}`);
  };

  const orphans = await shipJson<StatusBody>(options, ["status"]);
  for (const { delivery } of orphans.deliveries) await driveToEnd(delivery);

  for (;;) {
    const { delivery } = await shipJson<{ delivery: DeliveryId | null }>(options, ["next"]);
    if (delivery === null) return 0;
    const key = keyOf(delivery);
    if (handled.has(key)) {
      const reason = `${key} still ready after its Delivery ended: check policy.tracker.steps/outcomes`;
      console.error(`${delivery}: ${reason}`);
      const stopped = await runShip(ship, ["stop", delivery, "abandoned", reason], cwd);
      if (stopped.exitCode === 0) return 3;
      console.error(`ship stop ${delivery}: exit ${stopped.exitCode}; ${delivery} stays open\n${stopped.stderr}`);
      return 1;
    }
    await driveToEnd(delivery);
  }
};

const main = async (): Promise<number> => {
  let options: Options;
  try {
    options = resolveOptions(parseArgs(process.argv.slice(2)));
  } catch (error) {
    if (!(error instanceof RepoConfigError)) throw error;
    console.error(error.message);
    return 1;
  }
  if (!acquireLock(options.lock)) {
    console.error(`lock ${options.lock} exists: another queue holds it; delete it if stale`);
    return 2;
  }
  try {
    return await drain(options);
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
};

process.exit(await main());
