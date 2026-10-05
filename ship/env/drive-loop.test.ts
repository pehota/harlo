// driveDelivery's stall recovery (this fix): `onStalled: "stop"` must stop a Delivery whose awaited step
// poll/stalled.ts confirms "dead" (process gone, no outcome ever journaled) instead of polling forever —
// the unattended queue has no human to notice, unlike env/drive.ts which leaves onStalled unset. Runs the
// real poll/changed.ts and poll/stalled.ts against a real State journal (as poll/stalled.test.ts seeds it);
// `ship` itself is a fake script recording its calls, since only driveDelivery's reaction to a real "dead"
// flag is under test here, not the full apply/crash chain (see env/queue.test.ts for that boundary).
import { describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import type { RunnerStdin } from "../src/contracts/common";
import { D, awaited, snapshotAt, workItem } from "../src/core/fixtures/builders.fixture";
import type { Snapshot } from "../src/core/types";
import type { TimedEntry } from "../src/contracts/snapshot";
import { driveDelivery } from "./drive-loop";

const ROOT = join(import.meta.dir, "..");
const STATE = join(ROOT, "src", "adapters", "state", "files.ts");

const A = awaited("check-1", "check", "run", {}, "check", "run");
const S = snapshotAt("check", A);

/** `state save` on the real file adapter, as poll/stalled.test.ts seeds it. */
const seed = async (stateDir: string, state: Snapshot, entries: TimedEntry[], version = 1): Promise<void> => {
  const stdin: RunnerStdin = {
    id: null, delivery: state.delivery, port: "state", op: "save", workItem: null, workspace: null,
    payload: { delivery: state.delivery, version, state, entries }, tools: [],
  };
  const proc = Bun.spawn(["bun", STATE, "--dir", stateDir, "state", "save"], { stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe" });
  const [stdout, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const reply = JSON.parse(stdout) as { status: string; body?: { saved?: true } };
  if (exitCode !== 0 || reply.status !== "ok" || !reply.body?.saved) throw new Error(`seed failed: ${stdout}`);
};

const iso = (msAgo: number): string => new Date(Date.now() - msAgo).toISOString();
const startEntry = (msAgo: number): TimedEntry => ({ delivery: D, signal: { kind: "start", workItem }, from: null, to: "setup", issued: [], time: iso(msAgo) });
const HOST = hostname();
const sentEntry = (pid: number, started: string): TimedEntry =>
  ({ delivery: D, signal: { kind: "sent", id: A.id, pid, host: HOST, started }, from: "check", to: "check", issued: [], time: iso(0) });

/** A pid guaranteed already gone. */
const deadPid = async (): Promise<number> => {
  const proc = Bun.spawn(["true"], { stdout: "ignore", stderr: "ignore" });
  const pid = proc.pid;
  await proc.exited;
  return pid;
};

/**
 * A fake `bin/ship` recording every call to `<dir>/calls.jsonl`: `status [<delivery>]` replies with
 * `<dir>/status.json`'s current contents, re-read fresh on every call (the test may rewrite it between
 * passes); `stop <delivery> <outcome> <reason>` replies `{}` and records the call, same shape `env/queue.ts`'s
 * re-pick guard relies on.
 */
const fakeShip = (dir: string, initialStatus: { deliveries: { delivery: string; at: string; awaiting: string | null }[] }): string => {
  const path = join(dir, "fake-ship.ts");
  const statusPath = join(dir, "status.json");
  const script = `#!/usr/bin/env bun
import { appendFileSync, readFileSync } from "node:fs";
const args = process.argv.slice(2);
appendFileSync(${JSON.stringify(join(dir, "calls.jsonl"))}, JSON.stringify(args) + "\\n");
if (args[0] === "status") { console.log(readFileSync(${JSON.stringify(statusPath)}, "utf8")); process.exit(0); }
if (args[0] === "stop") { console.log(JSON.stringify({})); process.exit(0); }
console.error("unsupported"); process.exit(1);
`;
  writeFileSync(path, script);
  chmodSync(path, 0o755);
  writeFileSync(statusPath, JSON.stringify(initialStatus));
  return path;
};

const calls = (dir: string): string[][] => {
  try {
    return readFileSync(join(dir, "calls.jsonl"), "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as string[]);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
    throw error;
  }
};

describe("driveDelivery stall recovery", () => {
  test('onStalled "stop": "dead" on two consecutive passes stops the Delivery instead of polling forever', async () => {
    const dir = mkdtempSync(join(tmpdir(), "ship-drive-loop-"));
    try {
      const stateDir = join(dir, "state");
      await seed(stateDir, S, [startEntry(20_000), sentEntry(await deadPid(), "Mon Jan  1 00:00:00 2024")]);
      const ship = fakeShip(dir, { deliveries: [{ delivery: D, at: "check", awaiting: A.id }] });

      const at = await driveDelivery({
        ship, delivery: D, interval: 20, grace: "1", maxRuntime: String(3_600_000),
        state: ["bun", STATE, "--dir", stateDir], onStalled: "stop",
      });

      expect(at).toBe("abandoned");
      const logged = calls(dir);
      const stop = logged.find((c) => c[0] === "stop");
      expect(stop).toEqual(["stop", D, "abandoned", `${A.id}: dead (stalled, no outcome entry)`]);
      // debounced, not immediate: driveDelivery's own `ship status <delivery>` call happened at least
      // twice before the stop (poll/stalled.ts's separate `ship status` call is interleaved in the same log)
      expect(logged.filter((c) => c[0] === "status" && c[1] === D).length).toBeGreaterThanOrEqual(2);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  test('onStalled "stop": "dead" on only one pass (the race: a fast adapter\'s outcome write still in flight) does not stop the Delivery', async () => {
    const dir = mkdtempSync(join(tmpdir(), "ship-drive-loop-"));
    try {
      const stateDir = join(dir, "state");
      await seed(stateDir, S, [startEntry(20_000), sentEntry(await deadPid(), "Mon Jan  1 00:00:00 2024")]);
      const statusPath = join(dir, "status.json");
      const ship = fakeShip(dir, { deliveries: [{ delivery: D, at: "check", awaiting: A.id }] });
      // after exactly one "dead" pass, journal the outcome (clearing the real flag) and flip status to
      // terminal: proves a single dead reading alone never triggers the stop call.
      const resolveAfterOnePass = (async () => {
        while (calls(dir).filter((c) => c[0] === "status").length < 2) await Bun.sleep(5);
        const accepted: TimedEntry = { delivery: D, signal: { kind: "accepted", id: A.id }, from: "check", to: "check", issued: [], time: iso(0) };
        await seed(stateDir, S, [accepted], 2); // appends to the version-1 journal already seeded above
        writeFileSync(statusPath, JSON.stringify({ deliveries: [{ delivery: D, at: "closed", awaiting: null }] }));
      })();

      const at = await driveDelivery({
        ship, delivery: D, interval: 20, grace: "1", maxRuntime: String(3_600_000),
        state: ["bun", STATE, "--dir", stateDir], onStalled: "stop",
      });
      await resolveAfterOnePass;

      expect(at).toBe("closed");
      expect(calls(dir).some((c) => c[0] === "stop")).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);

  test("onStalled unset (env/drive.ts): a dead flag is printed, but the Delivery is left running for a human", async () => {
    const dir = mkdtempSync(join(tmpdir(), "ship-drive-loop-"));
    try {
      const stateDir = join(dir, "state");
      await seed(stateDir, S, [startEntry(20_000), sentEntry(await deadPid(), "Mon Jan  1 00:00:00 2024")]);
      const statusPath = join(dir, "status.json");
      const ship = fakeShip(dir, { deliveries: [{ delivery: D, at: "check", awaiting: A.id }] });
      // flips to terminal only once a full pass has run (poll/stalled.ts's own `ship status`, then
      // driveDelivery's `ship status <delivery>`): proves the loop kept polling on "dead" (onStalled unset)
      // rather than stopping itself, the same as env/drive.ts's human-watched behavior.
      const flipOnce = (async () => {
        while (calls(dir).filter((c) => c[0] === "status").length < 2) await Bun.sleep(5);
        writeFileSync(statusPath, JSON.stringify({ deliveries: [{ delivery: D, at: "closed", awaiting: null }] }));
      })();

      const at = await driveDelivery({
        ship, delivery: D, interval: 10, grace: "1", maxRuntime: String(3_600_000),
        state: ["bun", STATE, "--dir", stateDir],
      });
      await flipOnce;

      expect(at).toBe("closed");
      expect(calls(dir).some((c) => c[0] === "stop")).toBe(false);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }, 30_000);
});
