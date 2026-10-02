// M1.14: the queue loop, driven as an executable against the real `bin/ship` CLI (tracker: the real md
// adapter; state: the real file adapter; every other port: the scripted fake), exactly as env/drive.test.ts
// drives env/drive.ts. The test plays the human at the gates (`ship signal` / `ship stop`) from a background
// gatekeeper loop; the queue itself never answers a gate.
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { answer, defined, implemented, lifecycle, ok, verdict } from "../test/fixtures/lifecycle.fixture";

const ROOT = join(import.meta.dir, "..");
const BIN = join(ROOT, "bin", "ship");
const QUEUE = join(import.meta.dir, "queue.ts");

type Project = ReturnType<typeof lifecycle>;
const projects: Project[] = [];
afterAll(() => {
  for (const p of projects.splice(0)) p.cleanup();
});

/** Every step succeeds on every call (single replies, not lists), so any number of Deliveries run through. */
const EVERY_STEP_OK = {
  "workspace.setup": ok({ path: "/ws" }), "define.run": defined, "implement.run": implemented("c1"),
  "check.run": verdict("pass"), "integrate.run": verdict("landed"), "deploy.run": verdict("live"),
  "verify.run": verdict("pass"),
};
/** Entering Define marks the WorkItem in progress, so a picked item leaves `ready`. */
const LEAVES_READY = { tracker: { steps: { define: "in_progress" }, outcomes: {
  delivered: { status: "done" }, accepted_with_failure: { status: "done" },
  rolled_back: { status: "reopened", comment: true }, abandoned: { comment: true },
} } };

const project = (
  items: Record<string, string>, policy: Record<string, unknown> = LEAVES_READY, replies: Record<string, unknown> = {},
): Project => {
  const p = lifecycle({ ...EVERY_STEP_OK, ...replies }, policy, { items });
  projects.push(p);
  return p;
};

const queue = (p: Project, extra = "") =>
  p.bash(`bun ${QUEUE} --ship ${BIN} --interval 20 ${extra} --state ${p.stateArgv.join(" ")}`);

type Open = { deliveries: { delivery: string; at: string; awaiting: string | null }[] };

/** What the human does at a gate of Delivery `d`: answer it, stop it, or leave it alone. */
type Decide = (d: string, gate: string) => "answer" | "stop" | "skip";

/**
 * The human at the gates: polls `ship status` and answers each awaited Accept/Land gate once (accept /
 * approve), or stops the Delivery there, as `decide` says. Runs until `halt()`.
 */
const gatekeeper = (p: Project, decide: Decide = () => "answer") => {
  let running = true;
  const handled = new Set<string>();
  const loop = (async () => {
    while (running) {
      const status = await p.ship("status");
      for (const { delivery, awaiting } of (status.out as Open | null)?.deliveries ?? []) {
        const gate = awaiting?.slice(delivery.length + 1);
        if (!awaiting || handled.has(awaiting) || (gate !== "accept-1" && gate !== "land-1")) continue;
        const choice = decide(delivery, gate);
        if (choice === "skip") continue;
        handled.add(awaiting);
        if (choice === "stop") await p.ship("stop", delivery, "abandoned", "not wanted");
        else await p.ship("signal", delivery, awaiting, answer(gate === "accept-1" ? "accept" : "approve"));
      }
      await Bun.sleep(20);
    }
  })();
  return { halt: async () => { running = false; await loop; } };
};

/**
 * The queue spawned directly (no bash in between), so a signal reaches the queue process itself. Resolves
 * once its first progress line for `delivery` is out: it is then parked at that Delivery's first gate.
 */
const spawnParked = async (p: Project, delivery: string) => {
  const proc = Bun.spawn(
    ["bun", QUEUE, "--ship", BIN, "--interval", "20", "--state", ...p.stateArgv],
    { cwd: p.dir, env: { PATH: process.env.PATH ?? "", HOME: p.dir, SHIP_MACHINE_CONFIG: join(p.dir, "machine.json") },
      stdout: "pipe", stderr: "pipe" },
  );
  const reader = proc.stdout.getReader();
  let seen = "";
  while (!seen.includes(`${delivery} at=`)) {
    const { value, done } = await reader.read();
    if (done) throw new Error(`queue exited before ${delivery}'s first pass:\n${seen}`);
    seen += new TextDecoder().decode(value);
  }
  reader.releaseLock();
  return proc;
};

const trackerFile = (p: Project, key: string) => readFileSync(join(p.trackerDir, `${key}.md`), "utf8");
const doneLines = (stdout: string) => stdout.split("\n").filter((l) => l.includes(": done at="));
const atOf = async (p: Project, d: string) => ((await p.ship("status", d)).out as Open).deliveries[0]?.at;

describe("queue", () => {
  test("two ready items: both reach closed, exit 0, the queue is then empty, the lock is released", async () => {
    const p = project({ a: "ready", b: "ready" });
    const human = gatekeeper(p);
    const ran = await queue(p);
    await human.halt();

    expect(ran.exit).toBe(0);
    expect(doneLines(ran.stdout)).toEqual(["a-1: done at=closed", "b-1: done at=closed"]);
    expect(trackerFile(p, "a")).toContain("status: done");
    expect(trackerFile(p, "b")).toContain("status: done");
    expect((await p.ship("next")).out).toMatchObject({ delivery: null });
    expect(existsSync(join(p.dir, ".ship-queue.lock"))).toBe(false);
  }, 60_000);

  test("an item abandoned at a gate: the queue moves on to the next and exits 0", async () => {
    const p = project({ a: "ready", b: "ready" });
    const human = gatekeeper(p, (d) => (d === "a-1" ? "stop" : "answer"));
    const ran = await queue(p);
    await human.halt();

    expect(ran.exit).toBe(0);
    expect(doneLines(ran.stdout)).toEqual(["a-1: done at=abandoned", "b-1: done at=closed"]);
    expect(trackerFile(p, "a")).toContain("abandoned: not wanted"); // the stop reason, kept as a comment
  }, 60_000);

  test("a lock already present: exit 2 naming it, nothing started, the lock left in place", async () => {
    const p = project({ a: "ready" });
    const lock = join(p.dir, "held.lock");
    writeFileSync(lock, "someone else");

    const ran = await queue(p, `--lock ${lock}`);

    expect(ran.exit).toBe(2);
    expect(ran.stderr).toContain(lock);
    expect((await p.ship("status")).out).toEqual({ deliveries: [] });
    expect(trackerFile(p, "a")).toContain("status: ready");
    expect(readFileSync(lock, "utf8")).toBe("someone else");
  }, 30_000);

  test("a lock replaced by another run mid-run survives this queue's exit", async () => {
    const p = project({ a: "ready" });
    const lock = join(p.dir, ".ship-queue.lock");
    const ran = queue(p); // parks at a-1's Accept gate: nobody answers yet
    for (let i = 0; i < 500 && !(existsSync(lock) && readFileSync(lock, "utf8") !== ""); i++) await Bun.sleep(10); // token is written after the file is created
    writeFileSync(lock, "another run's token"); // A's lock deleted as stale, B took it

    const human = gatekeeper(p);
    const done = await ran;
    await human.halt();

    expect(done.exit).toBe(0);
    expect(readFileSync(lock, "utf8")).toBe("another run's token");
  }, 60_000);

  test("re-pick guard whose own `ship stop` fails: exit 1, the second Delivery stays open", async () => {
    // `abandoned` is not a stop outcome here, so the guard's stop is rejected; delivered sets `ready` again.
    const p = project({ k: "ready" }, { outcomes: ["rolled_back"], tracker: { outcomes: {
      delivered: { status: "ready" }, accepted_with_failure: { status: "done" },
      rolled_back: { status: "reopened", comment: true },
    } } });
    const human = gatekeeper(p, (d) => (d === "k-1" ? "answer" : "skip"));
    const ran = await queue(p);
    await human.halt();

    expect(ran.exit).toBe(1);
    expect(doneLines(ran.stdout)).toEqual(["k-1: done at=closed"]);
    expect(ran.stderr).toContain("k-2 stays open");
    expect(await atOf(p, "k-2")).not.toBe("abandoned");
    expect(existsSync(join(p.dir, ".ship-queue.lock"))).toBe(false);
  }, 60_000);

  test("a failing `ship next` that started a Delivery: exit 1, stderr names it", async () => {
    // Setup's adapter crashes: `ship next` exits 5, its output line still naming the Delivery it created.
    const p = project({ a: "ready" }, LEAVES_READY, { "workspace.setup": { exit: 1, stderr: "boom" } });
    const ran = await queue(p);

    expect(ran.exit).toBe(1);
    expect(ran.stderr).toContain("ship next: exit 5 (Delivery a-1)");
    expect(existsSync(join(p.dir, ".ship-queue.lock"))).toBe(false);
  }, 30_000);

  test.each([
    { signal: "SIGTERM", exit: 143 }, { signal: "SIGINT", exit: 130 }, { signal: "SIGHUP", exit: 129 },
  ] as const)("$signal while parked at a gate: exit $exit, the lock released", async ({ signal, exit }) => {
    const p = project({ a: "ready" });
    const proc = await spawnParked(p, "a-1");
    expect(existsSync(join(p.dir, ".ship-queue.lock"))).toBe(true);

    proc.kill(signal);

    expect(await proc.exited).toBe(exit);
    expect(existsSync(join(p.dir, ".ship-queue.lock"))).toBe(false);
  }, 30_000);

  test("an already-open Delivery is driven first, then `ship next`", async () => {
    const p = project({ a: "ready", b: "ready" });
    expect((await p.ship("start", "b")).out).toMatchObject({ delivery: "b-1", awaiting: "b-1/accept-1" });

    const human = gatekeeper(p);
    const ran = await queue(p);
    await human.halt();

    expect(ran.exit).toBe(0);
    expect(doneLines(ran.stdout)).toEqual(["b-1: done at=closed", "a-1: done at=closed"]);
  }, 60_000);

  test("re-pick guard: an item that stays ready → its second Delivery is stopped, exit 3", async () => {
    // No tracker.steps and no status for abandoned: once k-1 is stopped, `k` is still `ready`.
    const p = project({ k: "ready" }, {});
    const human = gatekeeper(p, (d) => (d === "k-1" ? "stop" : "skip"));
    const ran = await queue(p);
    await human.halt();

    expect(ran.exit).toBe(3);
    expect(doneLines(ran.stdout)).toEqual(["k-1: done at=abandoned"]);
    expect(ran.stderr).toContain("k still ready after its Delivery ended");
    expect(await atOf(p, "k-2")).toBe("abandoned");
    expect(trackerFile(p, "k")).toContain("abandoned: k still ready after its Delivery ended");
    expect(existsSync(join(p.dir, ".ship-queue.lock"))).toBe(false);
  }, 60_000);
});
