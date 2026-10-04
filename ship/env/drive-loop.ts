// The per-pass loop shared by `env/drive.ts` and `env/queue.ts` (environment code: it must not import
// `src/core` or runner internals). Each pass runs both pollers — `poll/changed.ts` (every open Delivery) and
// `poll/stalled.ts` (its flags echoed for a human watching) — then reads `ship status <delivery>`, prints one
// progress line, and sleeps `interval` until the Delivery's `at` is terminal. It never answers a gate itself.
//
// `cwd` (optional) is where `ship` and both pollers run: `ship` reads `ship.config.json` from its working
// directory, so env/queue.ts passes the repo root; omitted, they inherit this process's cwd (env/drive.ts).
//
// A Delivery is terminal once `at` is "closed" or "abandoned" — the same two literals `src/core/types.ts`'s
// `isTerminal` checks, re-checked here because environment code does not import the core.
import { join } from "node:path";
import type { DeliveryId } from "../src/contracts/common";

const TERMINAL_POSITIONS = new Set(["closed", "abandoned"]);

const CHANGED = join(import.meta.dir, "poll", "changed.ts");
const STALLED = join(import.meta.dir, "poll", "stalled.ts");

export type Ran = { exitCode: number; stdout: string; stderr: string };
export type StatusBody = { deliveries: { delivery: DeliveryId; at: string; awaiting: string | null }[] };

const run = async (argv: string[], cwd: string | undefined): Promise<Ran> => {
  const proc = Bun.spawn(argv, { cwd, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { exitCode, stdout, stderr };
};

/** One `ship <args…>` call from `cwd`, run exactly as a person invoking the binary there would. */
export const runShip = (ship: string, args: string[], cwd?: string): Promise<Ran> => run([ship, ...args], cwd);

/** One `bun <args…>` call from `cwd`: the pollers each pass invokes. */
const runBun = (args: string[], cwd: string | undefined): Promise<Ran> => run(["bun", ...args], cwd);

export type DriveOptions = {
  ship: string; delivery: DeliveryId; interval: number;
  grace: string | undefined; maxRuntime: string | undefined; state: string[]; cwd?: string;
};

/** Drive one known Delivery until its `at` is closed/abandoned; returns that final position. */
export const driveDelivery = async (options: DriveOptions): Promise<string> => {
  const { ship, delivery, interval, grace, maxRuntime, state, cwd } = options;
  const stalledArgs = [
    STALLED, "--ship", ship,
    ...(grace !== undefined ? ["--grace", grace] : []),
    ...(maxRuntime !== undefined ? ["--max-runtime", maxRuntime] : []),
    "--state", ...state,
  ];

  for (;;) {
    await runBun([CHANGED, "--ship", ship], cwd); // covers every open Delivery, not just this one

    const stalled = await runBun(stalledArgs, cwd);
    if (stalled.stdout) process.stdout.write(stalled.stdout); // stall flags: for a human watching

    const status = await runShip(ship, ["status", delivery], cwd);
    if (status.exitCode !== 0) throw new Error(`ship status ${delivery}: exit ${status.exitCode}\n${status.stderr}`);
    const { deliveries } = JSON.parse(status.stdout) as StatusBody;
    const [current] = deliveries; // exactly one: we asked for a specific delivery
    if (!current) throw new Error(`ship status ${delivery}: no Delivery returned`);

    console.log(`${current.delivery} at=${current.at} awaiting=${current.awaiting}`);
    if (TERMINAL_POSITIONS.has(current.at)) return current.at;
    await Bun.sleep(interval);
  }
};
