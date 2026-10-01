// M1.13: the driver loop, driven as an executable against the real `bin/ship` CLI (state: the real file
// adapter; every other port: the scripted fake), exactly as test/e2e/lifecycle.test.ts drives `ship`. Mirrors
// env/poll/changed.test.ts's pattern: a project() from the lifecycle fixture, `p.bash(...)` to run the driver
// as a real subprocess, scripted fake adapter replies to reach a gate, and `ship signal` played by the test to
// stand in for the human answering — the driver itself must never call it.
import { afterAll, describe, expect, test } from "bun:test";
import { join } from "node:path";
import { D, HAPPY, answer, coreSequence, lifecycle } from "../test/fixtures/lifecycle.fixture";

const ROOT = join(import.meta.dir, "..");
const BIN = join(ROOT, "bin", "ship");
const DRIVE = join(import.meta.dir, "drive.ts");

type Project = ReturnType<typeof lifecycle>;
const projects: Project[] = [];
afterAll(() => {
  for (const p of projects.splice(0)) p.cleanup();
});
const project = (...args: Parameters<typeof lifecycle>): Project => {
  const p = lifecycle(...args);
  projects.push(p);
  return p;
};

type StatusOut = { deliveries: { awaiting: string | null }[] };

/** `ship status <D>` read directly by the test, independent of the driver's own loop. */
const awaiting = async (p: Project): Promise<string | null> => {
  const status = await p.ship("status", D);
  return (status.out as StatusOut | null)?.deliveries[0]?.awaiting ?? null;
};

/** Poll `ship status <D>` until it awaits `id`. */
const waitForAwaiting = async (p: Project, id: string, timeoutMs = 5_000): Promise<void> => {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const at = await awaiting(p);
    if (at === `${D}/${id}`) return;
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${id}; last awaiting=${at}`);
    await Bun.sleep(10);
  }
};

/** The full happy-path journal (plan §6 M0.9's HAPPY chain), whoever drives `start`/`signal`. */
const FULL_SEQUENCE = [
  "start: ∅→setup", "result setup-1: setup→define", "result define-1: define→accept",
  "result accept-1: accept→implement", "result implement-1: implement→check", "result check-1: check→land",
  "result land-1: land→integrate", "result integrate-1: integrate→deploy", "result deploy-1: deploy→verify",
  "result verify-1: verify→close", "result close-1: close→teardown", "result teardown-1: teardown→closed",
];

describe("drive", () => {
  test("--key: loops through the gates the test answers, exits 0 on closed, never signals itself", async () => {
    const p = project(HAPPY);

    const driven = p.bash(`bun ${DRIVE} --ship ${BIN} --key k --interval 20 --state ${p.stateArgv.join(" ")}`);

    // The human answers each gate by hand (`ship signal`, played here by the test) while the driver keeps
    // polling in the background; a real sleep between answers spans several of the driver's 20ms passes.
    await waitForAwaiting(p, "accept-1");
    await Bun.sleep(300); // several driver passes at this gate — it must not advance it itself
    expect(await awaiting(p)).toBe(`${D}/accept-1`);
    await p.ship("signal", D, `${D}/accept-1`, answer("accept"));

    await waitForAwaiting(p, "land-1");
    await Bun.sleep(300); // several more passes at the next gate — same guarantee
    expect(await awaiting(p)).toBe(`${D}/land-1`);
    await p.ship("signal", D, `${D}/land-1`, answer("approve"));

    const ran = await driven;
    expect(ran.exit).toBe(0);

    const lines = ran.stdout.trim().split("\n").filter(Boolean);
    const progress = lines.filter((l) => l.startsWith(`${D} at=`));
    // Proves real looping, not a single pass: several progress lines came from several distinct passes
    // (the two 300ms holds above each span many of the driver's 20ms-interval iterations).
    expect(progress.length).toBeGreaterThanOrEqual(3);
    expect(lines.at(-1)).toBe(`${D}: done at=closed`);

    // The core's own transitions are exactly the happy-path chain the test's two `ship signal` calls drove —
    // the driver never applied a gate's result on its own. Interleaved `changed:` entries (W1, unchanged
    // WorkItem) are the driver's own repeated `poll/changed.ts` calls: further proof it kept looping.
    const core = coreSequence(await p.journal());
    expect(core.filter((line) => line.startsWith("start:") || line.startsWith("result "))).toEqual(FULL_SEQUENCE);
    expect(core.some((line) => line.startsWith("changed:"))).toBe(true);
  }, 30_000);

  test("--delivery: does not call `ship start` again, still detects termination", async () => {
    const p = project(HAPPY);

    const start = await p.ship("start", "k");
    expect(start.out).toMatchObject({ awaiting: `${D}/accept-1` });
    await p.ship("signal", D, `${D}/accept-1`, answer("accept"));
    await p.ship("signal", D, `${D}/land-1`, answer("approve"));

    const before = p.log().filter((s) => s.port === "tracker" && s.op === "read" && s.delivery === null);
    expect(before).toHaveLength(1); // only this test's own `ship start`

    const ran = await p.bash(`bun ${DRIVE} --ship ${BIN} --delivery ${D} --interval 20 --state ${p.stateArgv.join(" ")}`);
    expect(ran.exit).toBe(0);
    expect(ran.stdout.trim().split("\n").at(-1)).toBe(`${D}: done at=closed`);

    const after = p.log().filter((s) => s.port === "tracker" && s.op === "read" && s.delivery === null);
    expect(after).toHaveLength(1); // no second `ship start`/`next` call from the driver

    // Already closed by the test's own two signals before the driver ever ran — it added nothing.
    expect(coreSequence(await p.journal())).toEqual(FULL_SEQUENCE);
  }, 30_000);

});
