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
// its new Delivery stopped as `abandoned` with that reason, and the queue exits 3.
//
// One queue per State: an exclusive lockfile (atomic create) guards the run. It is removed on drain, on error
// and on SIGINT/SIGTERM/SIGHUP — never on SIGKILL, which leaves it stale — and only while it still holds this
// run's token (pid + random id): a lock another run took since is kept.
// A stale one (from a killed process) is left for a person to delete — the queue never guesses.
//
// ponytail: no --concurrency flag — one Delivery at a time, deliberately. Parallel Deliveries are the open
// discovery issue pehota/harlo#50; add it only once that settles what may safely run side by side.
//
// argv: --ship <path to bin/ship> [--interval <ms>] [--grace <ms>] [--max-runtime <ms>] [--lock <path>]
//       --state <state-adapter argv…>
//   Same conventions as drive.ts: `--state` takes the rest of argv; `--grace`/`--max-runtime` are forwarded to
//   `poll/stalled.ts` only when given; `--interval` defaults to 5000ms. `--lock` defaults to `.ship-queue.lock`
//   in the working directory (where `ship.config.json` is).
// exit: 0 queue drained · 1 a `ship` call failed (or bad usage) · 2 lock already held · 3 re-pick guard fired
import { randomUUID } from "node:crypto";
import { closeSync, openSync, readFileSync, rmSync, writeSync } from "node:fs";
import type { DeliveryId } from "../src/contracts/common";
import { type StatusBody, driveDelivery, runShip } from "./drive-loop";

const DEFAULT_INTERVAL_MS = 5000;
const DEFAULT_LOCK = ".ship-queue.lock";

type Options = {
  ship: string; interval: number; grace: string | undefined; maxRuntime: string | undefined;
  lock: string; state: string[];
};

const parseArgs = (args: string[]): Omit<Options, "ship"> & { ship: string | undefined } => {
  const stateAt = args.indexOf("--state");
  const head = stateAt === -1 ? args : args.slice(0, stateAt);
  const state = stateAt === -1 ? [] : args.slice(stateAt + 1);
  const flag = (name: string) => { const at = head.indexOf(name); return at === -1 ? undefined : head[at + 1]; };
  const interval = flag("--interval");
  return {
    ship: flag("--ship"), interval: interval === undefined ? DEFAULT_INTERVAL_MS : Number(interval),
    grace: flag("--grace"), maxRuntime: flag("--max-runtime"), lock: flag("--lock") ?? DEFAULT_LOCK, state,
  };
};

/** A failed `ship` call: the queue stops with exit 1. */
class ShipCallError extends Error {}

/** One `ship <args…>` call whose JSON stdout line is returned; a nonzero exit is a ShipCallError. */
const shipJson = async <T>(ship: string, args: string[]): Promise<T> => {
  const ran = await runShip(ship, args);
  if (ran.exitCode !== 0) throw new ShipCallError(`ship ${args.join(" ")}: exit ${ran.exitCode}\n${ran.stderr}`);
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
  const { ship } = options;
  const handled = new Set<string>();
  const driveToEnd = async (delivery: DeliveryId): Promise<void> => {
    const at = await driveDelivery({ ...options, delivery });
    handled.add(keyOf(delivery));
    console.log(`${delivery}: done at=${at}`);
  };

  const orphans = await shipJson<StatusBody>(ship, ["status"]);
  for (const { delivery } of orphans.deliveries) await driveToEnd(delivery);

  for (;;) {
    const { delivery } = await shipJson<{ delivery: DeliveryId | null }>(ship, ["next"]);
    if (delivery === null) return 0;
    const key = keyOf(delivery);
    if (handled.has(key)) {
      const reason = `${key} still ready after its Delivery ended: check policy.tracker.steps/outcomes`;
      const stopped = await runShip(ship, ["stop", delivery, "abandoned", reason]);
      if (stopped.exitCode !== 0) console.error(`ship stop ${delivery}: exit ${stopped.exitCode}\n${stopped.stderr}`);
      console.error(`${delivery}: ${reason}`);
      return 3;
    }
    await driveToEnd(delivery);
  }
};

const main = async (): Promise<number> => {
  const { ship, ...rest } = parseArgs(process.argv.slice(2));
  if (!ship || rest.state.length === 0) {
    console.error(
      "usage: queue.ts --ship <path to bin/ship> [--interval <ms>] [--grace <ms>] [--max-runtime <ms>] " +
        "[--lock <path>] --state <state-adapter argv…>",
    );
    return 1;
  }
  if (!acquireLock(rest.lock)) {
    console.error(`lock ${rest.lock} exists: another queue holds it; delete it if stale`);
    return 2;
  }
  try {
    return await drain({ ship, ...rest });
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
};

process.exit(await main());
