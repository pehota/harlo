// A Delivery driven through the REAL terminal Principal, the way a person does: read the paste-ready
// `ship signal …` lines it printed, pick the happy option, run that exact line with bash. `bin/ship` runs as a
// subprocess; tracker, workspace and step ports are the scripted fake, State is the real file adapter.
import { afterAll, describe, expect, test } from "bun:test";
import { D, HAPPY, lifecycle, ok, runbook, workItem } from "../fixtures/lifecycle.fixture";

const TIMEOUT = 60_000;
const MAX_GATES = 20;
const HAPPY_ANSWER = /"answer":"(accept|approve)"/;
type Project = ReturnType<typeof lifecycle>;

const projects: Project[] = [];
afterAll(() => {
  for (const p of projects.splice(0)) p.cleanup();
});
const project = (replies: Record<string, unknown>): Project => {
  const p = lifecycle(replies, {}, { principal: "terminal" });
  projects.push(p);
  return p;
};

/** The one Delivery's position and awaited id, read with `ship status`. */
const status = async (p: Project): Promise<{ at: string; awaiting: string | null }> => {
  const ran = await p.ship("status", D);
  expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: "" });
  const [delivery] = (ran.out as { deliveries: { at: string; awaiting: string | null }[] }).deliveries;
  return delivery!;
};

/** The printed `ship signal` lines answering `id`, leading indent dropped. */
const signalLines = (p: Project, id: string): string[] =>
  p.printed().split("\n").filter((l) => l.startsWith(`  ship signal ${D} ${id} `)).map((l) => l.trimStart());

/** The printed block (`── … ──` header to the next one) that offers answers to `id`. */
const blockFor = (p: Project, id: string): string =>
  p.printed().split("\n── ").find((block) => block.includes(`ship signal ${D} ${id} `)) ?? "";

/** Answer every awaited gate with its printed happy line, run verbatim, until the Delivery is Closed. */
const driveToClosed = async (p: Project): Promise<string[]> => {
  const ran: string[] = [];
  for (let i = 0; i < MAX_GATES; i += 1) {
    const { at, awaiting } = await status(p);
    if (at === "closed") return ran;
    expect(awaiting).not.toBeNull();
    const offered = signalLines(p, awaiting!);
    expect(offered.some((l) => l.includes("…"))).toBe(false);
    const line = offered.find((l) => HAPPY_ANSWER.test(l));
    expect(line).toBeDefined();
    const shell = await p.bash(line!);
    expect({ exit: shell.exit, stderr: shell.stderr }).toEqual({ exit: 0, stderr: "" });
    ran.push(awaiting!.slice(`${D}/`.length));
  }
  throw new Error(`not closed after ${MAX_GATES} gates`);
};

describe("lifecycle through the terminal Principal", () => {
  test.concurrent("happy path: each printed happy line, run verbatim, reaches Closed", async () => {
    const p = project(HAPPY);
    expect((await p.ship("start", "k")).exit).toBe(0);
    expect(await driveToClosed(p)).toEqual(["accept-1", "land-1"]);
  }, TIMEOUT);

  test.concurrent("changed at Accept re-runs Define; the new Accept gate shows the new criteria", async () => {
    const p = project({ ...HAPPY, "define.run": [ok({ criteria: ["greets Ada by name"], runbook })] });
    expect((await p.ship("start", "k")).exit).toBe(0);
    expect(blockFor(p, `${D}/accept-1`)).toContain("  - greets Ada by name");

    const changedItem = { title: "Greet by full name", body: "Say hello with the full name." };
    p.rescript({
      "tracker.read": workItem(changedItem.title, changedItem.body),
      "define.run": ok({ criteria: ["greets Ada Lovelace by full name"], runbook }),
    });
    const changed = await p.ship("changed", D);
    expect({ exit: changed.exit, awaiting: changed.out?.awaiting }).toEqual({ exit: 0, awaiting: `${D}/accept-2` });

    const define2 = p.log().find((s) => s.id === `${D}/define-2`);
    expect(define2?.workItem).toMatchObject(changedItem);
    expect(p.printed()).toContain(`${D}/accept-1 withdrawn`);
    const accept2 = blockFor(p, `${D}/accept-2`);
    expect(accept2).toContain(`WorkItem k: ${changedItem.title}`);
    expect(accept2).toContain("  - greets Ada Lovelace by full name");
    expect(accept2).not.toContain("  - greets Ada by name");
    expect(accept2).not.toContain("Note:");

    expect(await driveToClosed(p)).toEqual(["accept-2", "land-1"]);
    expect((await p.snapshot()).criteria).toEqual(["greets Ada Lovelace by full name"]);
  }, TIMEOUT);
});
