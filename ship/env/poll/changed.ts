#!/usr/bin/env bun
// WorkItem-change poller (plan §6 M1.4; Bun/TS per the accepted architecture amendment, replacing the plan's
// bash env/poll-changed.sh). For each non-terminal Delivery `ship status` lists, runs `ship changed <delivery>`
// so the core sees the WorkItem's current title/body (W1: unchanged title/body is ignored by the core itself).
// One-shot: a cron or loop invokes this; ship ships no daemon (plan §7).
//
// Runnable directly (`bun env/poll/changed.ts --ship <bin/ship>`) or via cron, from the project directory
// `ship status`/`ship changed` expect (ship.config.json in cwd, machine config from $SHIP_MACHINE_CONFIG or
// ~/.config/ship/<projectId>.json, as `src/runner/config.ts` resolves it).
//
// argv: --ship <path to bin/ship, directly executable>
import type { DeliveryId } from "../../src/contracts/common";

type StatusBody = { deliveries: { delivery: DeliveryId; at: string; awaiting: string | null }[] };

const parseArgs = (args: string[]): { ship: string | undefined } => {
  const at = args.indexOf("--ship");
  return { ship: at === -1 ? undefined : args[at + 1] };
};

/** One `ship <args…>` call, run exactly as a person invoking the binary would. */
const runShip = async (ship: string, args: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> => {
  const proc = Bun.spawn([ship, ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { exitCode, stdout, stderr };
};

const main = async (): Promise<void> => {
  const { ship } = parseArgs(process.argv.slice(2));
  if (!ship) throw new Error("usage: poll/changed.ts --ship <path to bin/ship>");

  const status = await runShip(ship, ["status"]);
  if (status.exitCode !== 0) throw new Error(`ship status: exit ${status.exitCode}\n${status.stderr}`);
  const { deliveries } = JSON.parse(status.stdout) as StatusBody;

  let failures = 0;
  for (const { delivery } of deliveries) {
    const changed = await runShip(ship, ["changed", delivery]);
    if (changed.exitCode !== 0) {
      failures += 1;
      console.error(`ship changed ${delivery}: exit ${changed.exitCode}\n${changed.stderr}`);
    }
  }
  if (failures > 0) process.exitCode = 1; // cron mail: at least one Delivery's change check failed
};

await main();
