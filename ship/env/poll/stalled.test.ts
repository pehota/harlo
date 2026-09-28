// M1.4: the stall poller, driven as an executable. `ship status` is a fake stand-in (its own JSON is the
// thing under test's control), State is the real file adapter seeded directly (as adapters/state/files.test.ts
// seeds it), so the liveness rules run against a real journal and real pids/process-start-times.
import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import type { RunnerStdin } from "../../src/contracts/common";
import type { TimedEntry } from "../../src/contracts/snapshot";
import { D, awaited, snapshotAt, workItem } from "../../src/core/fixtures/builders.fixture";
import type { Snapshot } from "../../src/core/types";

const ROOT = join(import.meta.dir, "..", "..");
const STATE = join(ROOT, "adapters", "state", "files.ts");
const STALLED = join(import.meta.dir, "stalled.ts");

const A = awaited("check-1", "check", "run", {}, "check", "run"); // the one awaited command every row shares
const S = snapshotAt("check", A);
const HOST = hostname();
const REAL_STARTED = Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(process.pid)]).stdout.toString().trim();

/** A subprocess that has already exited: a pid guaranteed gone, for the "dead" rows. */
const deadPid = async (): Promise<number> => {
  const proc = Bun.spawn(["true"], { stdout: "ignore", stderr: "ignore" });
  const pid = proc.pid;
  await proc.exited;
  return pid;
};

const iso = (msAgo: number): string => new Date(Date.now() - msAgo).toISOString();
const startEntry = (msAgo: number): TimedEntry => ({ delivery: D, signal: { kind: "start", workItem }, from: null, to: "setup", issued: [], time: iso(msAgo) });
const sentEntry = (pid: number, host: string, started: string): TimedEntry =>
  ({ delivery: D, signal: { kind: "sent", id: A.id, pid, host, started }, from: "check", to: "check", issued: [], time: iso(0) });

/** `state save` on the real file adapter, exactly as adapters/state/files.test.ts seeds it. */
const seed = async (stateDir: string, state: Snapshot, entries: TimedEntry[]): Promise<void> => {
  const stdin: RunnerStdin = {
    id: null, delivery: state.delivery, port: "state", op: "save", workItem: null, workspace: null,
    payload: { delivery: state.delivery, version: 1, state, entries }, tools: [],
  };
  const proc = Bun.spawn(["bun", STATE, "--dir", stateDir, "state", "save"], { stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe" });
  const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const reply = JSON.parse(stdout) as { status: string; body?: { saved?: true } };
  if (exitCode !== 0 || reply.status !== "ok" || !reply.body?.saved) throw new Error(`seed failed: ${stdout}`);
};

/** A fake `ship status` reporting exactly one Delivery, awaiting `A`. */
const fakeShip = (dir: string): string => {
  const path = join(dir, "fake-ship.ts");
  const body = { deliveries: [{ delivery: D, at: "check", awaiting: A.id }] };
  writeFileSync(path, `#!/usr/bin/env bun\nif (process.argv[2] === "status") { console.log(${JSON.stringify(JSON.stringify(body))}); process.exit(0); }\nconsole.error("unsupported"); process.exit(1);\n`);
  chmodSync(path, 0o755);
  return path;
};

const run = async (ship: string, stateDir: string, grace: number, maxRuntime: number) => {
  const proc = Bun.spawn(
    ["bun", STALLED, "--ship", ship, "--grace", String(grace), "--max-runtime", String(maxRuntime), "--state", "bun", STATE, "--dir", stateDir],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  return { exitCode, stdout: stdout.trim(), stderr };
};

type Row = { name: string; entries: (ctx: { dead: number }) => TimedEntry[]; grace: number; maxRuntime: number; flag: string | null };

const HOUR = 3_600_000;

const rows: Row[] = [
  { name: "never sent: last entry past the grace period", entries: () => [startEntry(10_000)], grace: 1_000, maxRuntime: HOUR, flag: "never sent" },
  { name: "never sent: within the grace period is not flagged", entries: () => [startEntry(100)], grace: 10_000, maxRuntime: HOUR, flag: null },
  { name: "dead: sent, process gone, no outcome entry", entries: ({ dead }) => [startEntry(20_000), sentEntry(dead, HOST, "Mon Jan  1 00:00:00 2024")], grace: 1_000, maxRuntime: HOUR, flag: "dead" },
  { name: "hung?: sent, alive, past maxRuntime", entries: () => [startEntry(20_000), sentEntry(process.pid, HOST, REAL_STARTED)], grace: 1_000, maxRuntime: 1, flag: "hung?" },
  { name: "sent, alive, within maxRuntime is not flagged", entries: () => [startEntry(20_000), sentEntry(process.pid, HOST, REAL_STARTED)], grace: 1_000, maxRuntime: HOUR, flag: null },
];

describe("poll/stalled", () => {
  test.each(rows)("$name", async ({ entries, grace, maxRuntime, flag }) => {
    const dir = mkdtempSync(join(tmpdir(), "ship-poll-stalled-"));
    try {
      const stateDir = join(dir, "state");
      await seed(stateDir, S, entries({ dead: await deadPid() }));
      const ship = fakeShip(dir);
      const ran = await run(ship, stateDir, grace, maxRuntime);
      expect(ran.stderr).toBe("");
      expect(ran.exitCode).toBe(0);
      expect(ran.stdout).toBe(flag ? `${D} ${A.id}: ${flag}` : "");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  test("no awaited command: no flag, no journal read", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ship-poll-stalled-"));
    try {
      const path = join(dir, "fake-ship.ts");
      writeFileSync(path, `#!/usr/bin/env bun\nconsole.log(${JSON.stringify(JSON.stringify({ deliveries: [{ delivery: D, at: "check", awaiting: null }] }))});\n`);
      chmodSync(path, 0o755);
      const ran = await run(path, join(dir, "state"), 1_000, HOUR);
      expect({ exitCode: ran.exitCode, stdout: ran.stdout, stderr: ran.stderr }).toEqual({ exitCode: 0, stdout: "", stderr: "" });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});
