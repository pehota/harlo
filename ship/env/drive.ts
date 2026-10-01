#!/usr/bin/env bun
// Driver loop (plan §6 M1.13; Bun/TS, environment code). Automates the manual dogfooding cycle a person
// otherwise runs by hand: repeatedly calling `ship next`/`ship changed` and the pollers, watching `ship status`
// for a Delivery to finish. Unlike `env/poll/changed.ts` and `env/poll/stalled.ts` — one-shot scripts a cron or
// loop is expected to invoke — this file IS that "cron or loop" harness plan.md §7 leaves to the environment:
// it loops itself, sleeping `--interval` between passes, and calls both pollers each pass rather than being
// called by something else. It never itself answers a Principal gate — it has no `ship signal` call anywhere —
// but the Principal adapter (`src/adapters/principal/tty.ts`) answers gates synchronously, blocking on `/dev/tty`
// for a typed reply. So whichever `ship start`/`ship next`/`ship changed` call this driver makes (via `runShip`)
// happens to reach a gate will itself block right there until a human types a reply at that same terminal —
// this loop simply pauses mid-pass while that happens, then continues once the call returns.
//
// A Delivery is terminal once `at` is "closed" or "abandoned" — the same two literals `src/core/types.ts`'s
// `isTerminal` checks. This is environment code (it must not import `src/core`), so it re-checks those literals
// locally, matching how the pollers avoid importing runner internals.
//
// argv: --ship <path to bin/ship> (--key <workItem-key> | --delivery <id>) [--interval <ms>]
//       [--grace <ms>] [--max-runtime <ms>] --state <state-adapter argv…>
//   `--key` starts a new Delivery via `ship start <key>`; `--delivery` drives an already-started one (no
//   `ship start` call). `--state` takes the rest of argv, passed straight through to `poll/stalled.ts`: the
//   state adapter's own spawn argv, exactly as the machine config's `state` entry does. `--grace`/`--max-runtime`
//   are forwarded to `poll/stalled.ts` only when given (it supplies its own defaults otherwise). `--interval`
//   defaults to 5000ms.
import { join } from "node:path";
import type { DeliveryId } from "../src/contracts/common";

const DEFAULT_INTERVAL_MS = 5000;
const TERMINAL_POSITIONS = new Set(["closed", "abandoned"]);

const CHANGED = join(import.meta.dir, "poll", "changed.ts");
const STALLED = join(import.meta.dir, "poll", "stalled.ts");

type StatusBody = { deliveries: { delivery: DeliveryId; at: string; awaiting: string | null }[] };

const parseArgs = (
  args: string[],
): {
  ship: string | undefined; key: string | undefined; delivery: DeliveryId | undefined;
  interval: number; grace: string | undefined; maxRuntime: string | undefined; state: string[];
} => {
  const stateAt = args.indexOf("--state");
  const head = stateAt === -1 ? args : args.slice(0, stateAt);
  const state = stateAt === -1 ? [] : args.slice(stateAt + 1);
  const flag = (name: string) => { const at = head.indexOf(name); return at === -1 ? undefined : head[at + 1]; };
  const num = (name: string, fallback: number) => { const v = flag(name); return v === undefined ? fallback : Number(v); };
  return {
    ship: flag("--ship"), key: flag("--key"), delivery: flag("--delivery"),
    interval: num("--interval", DEFAULT_INTERVAL_MS), grace: flag("--grace"), maxRuntime: flag("--max-runtime"),
    state,
  };
};

/** One `ship <args…>` call, run exactly as a person invoking the binary would. */
const runShip = async (ship: string, args: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> => {
  const proc = Bun.spawn([ship, ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { exitCode, stdout, stderr };
};

/** One `bun <args…>` call: the pollers this driver invokes each pass. */
const runBun = async (args: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> => {
  const proc = Bun.spawn(["bun", ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { exitCode, stdout, stderr };
};

/** `--delivery` drives it directly; `--key` starts a fresh one. A failed or delivery-less start is fatal. */
const resolveDelivery = async (ship: string, key: string | undefined, delivery: DeliveryId | undefined): Promise<DeliveryId> => {
  if (delivery !== undefined) return delivery;
  const started = await runShip(ship, ["start", key!]);
  const out = started.exitCode === 0 ? (JSON.parse(started.stdout) as { delivery: DeliveryId | null }) : null;
  if (!out?.delivery) {
    console.error(started.stderr);
    process.exit(1);
  }
  return out.delivery;
};

const main = async (): Promise<void> => {
  const { ship, key, delivery: deliveryArg, interval, grace, maxRuntime, state } = parseArgs(process.argv.slice(2));
  if (!ship || (!key && !deliveryArg) || state.length === 0) {
    throw new Error(
      "usage: drive.ts --ship <path to bin/ship> (--key <workItem-key> | --delivery <id>) " +
        "[--interval <ms>] [--grace <ms>] [--max-runtime <ms>] --state <state-adapter argv…>",
    );
  }

  const delivery = await resolveDelivery(ship, key, deliveryArg);

  for (;;) {
    await runBun([CHANGED, "--ship", ship]); // covers every open Delivery, not just this one

    const stalledArgs = [
      STALLED, "--ship", ship,
      ...(grace !== undefined ? ["--grace", grace] : []),
      ...(maxRuntime !== undefined ? ["--max-runtime", maxRuntime] : []),
      "--state", ...state,
    ];
    const stalled = await runBun(stalledArgs);
    if (stalled.stdout) process.stdout.write(stalled.stdout); // stall flags: for a human watching

    const status = await runShip(ship, ["status", delivery]);
    if (status.exitCode !== 0) throw new Error(`ship status ${delivery}: exit ${status.exitCode}\n${status.stderr}`);
    const { deliveries } = JSON.parse(status.stdout) as StatusBody;
    const [current] = deliveries; // exactly one: we asked for a specific delivery
    if (!current) throw new Error(`ship status ${delivery}: no Delivery returned`);

    console.log(`${current.delivery} at=${current.at} awaiting=${current.awaiting}`);
    if (TERMINAL_POSITIONS.has(current.at)) {
      console.log(`${current.delivery}: done at=${current.at}`);
      process.exit(0);
    }
    await Bun.sleep(interval);
  }
};

await main();
