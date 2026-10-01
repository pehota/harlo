// A Delivery driven through the REAL tty Principal, the way a person now does: `ship start` blocks at each gate,
// printed on a real pty, and is answered right there -- no separate `ship signal` invocation. Since apply()'s own
// queue keeps driving on every synchronous `ok` reply, one `ship start` call now walks the whole Delivery to
// Closed, prompting at each gate in turn. `bin/ship` runs as a subprocess; tracker, workspace and step ports are
// the scripted fake, State is the real file adapter.
//
// The old second scenario here ("changed at Accept re-runs Define") relied on a Delivery sitting at an
// unanswered gate while a second `ship` invocation ran concurrently -- a state the synchronous tty adapter can no
// longer be in (the process is blocked reading the reply, not idle). The underlying `changed` core logic it
// exercised is already covered with the fake Principal in test/e2e/lifecycle.test.ts ("changed before Land
// re-runs Define…"); the tty adapter's own evidence formatting is covered directly in
// src/adapters/principal/tty.test.ts.
import { afterAll, describe, expect, test } from "bun:test";
import { D, HAPPY, lifecycle } from "../fixtures/lifecycle.fixture";

const TIMEOUT = 60_000;
type Project = ReturnType<typeof lifecycle>;

const projects: Project[] = [];
afterAll(() => {
  for (const p of projects.splice(0)) p.cleanup();
});
const project = (replies: Record<string, unknown>): Project => {
  const p = lifecycle(replies, {}, { principal: "tty" });
  projects.push(p);
  return p;
};

describe("lifecycle through the tty Principal", () => {
  test.concurrent("happy path: one `ship start` walks Accept and Land to Closed", async () => {
    const p = project(HAPPY);
    const ran = await p.shipPty(["start", "k"], [
      { wait: `${D}: decide accept`, send: "accept\n" },
      { wait: `${D}: decide land`, send: "approve\n" },
    ]);
    expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: "" });
    expect(ran.out).toMatchObject({ delivery: D, awaiting: null });

    const status = await p.ship("status", D);
    expect(status.out).toMatchObject({ deliveries: [{ delivery: D, at: "closed", awaiting: null }] });
  }, TIMEOUT);
});
