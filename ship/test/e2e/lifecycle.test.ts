// M0.21: full lifecycle scenarios through `bin/ship` as a subprocess: CLI + Runner + core, with the real file
// State adapter and the scripted fake adapter on every other port. Step adapters reply at once; the Principal
// (the fake, unscripted) prints `accepted`, and each answer is delivered with `ship signal`, as a person would.
// Each scenario asserts the final Snapshot.at, the journal (read through `state journal`) and the fake's stdin log.
import { afterAll, describe, expect, test } from "bun:test";
import {
  D, HAPPY, answer, calls, coreSequence, criteria, defined, failed, implemented, issuedAndSent, lifecycle, ok, payloadOf,
  question, runbook, verdict, workItem,
} from "../fixtures/lifecycle.fixture";
import type { Position } from "../../src/core/types";

const TIMEOUT = 60_000;
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

/** Run one CLI call and require exit 0 and the expected awaited id (null when nothing is awaited). */
const step = async (p: Project, awaiting: string | null, ...args: string[]) => {
  const ran = await p.ship(...args);
  expect({ exit: ran.exit, awaiting: ran.out?.awaiting, stderr: ran.stderr }).toEqual({
    exit: 0, awaiting: awaiting === null ? null : `${D}/${awaiting}`, stderr: "",
  });
  return ran;
};
const start = (p: Project, awaiting: string) => step(p, awaiting, "start", "k");
const signal = (p: Project, id: string, json: string, awaiting: string | null) => step(p, awaiting, "signal", D, `${D}/${id}`, json);

/** The final position, the core's journal sequence, `sent` for every issued command, and the fake's calls. */
const expectFinal = async (p: Project, at: Position, core: string[], fakeCalls: string[]) => {
  expect((await p.snapshot()).at).toBe(at);
  const entries = await p.journal();
  expect(coreSequence(entries)).toEqual(core);
  const { issued, sent } = issuedAndSent(entries);
  expect(sent).toEqual(issued);
  expect(calls(p.log())).toEqual(fakeCalls);
};

// ── Shared stretches of the happy path ──
const TO_ACCEPT = {
  core: ["start: ∅→setup", "result setup-1: setup→define", "result define-1: define→accept"],
  calls: ["tracker.read -", "workspace.setup setup-1", "define.run define-1", "principal.decide accept-1"],
};
const TO_LAND = {
  core: ["result accept-1: accept→implement", "result implement-1: implement→check", "result check-1: check→land"],
  calls: ["implement.run implement-1", "check.run check-1", "principal.decide land-1"],
};
const CLOSE = {
  core: ["result close-1: close→teardown", "result teardown-1: teardown→closed"],
  calls: ["tracker.update close-1", "workspace.teardown teardown-1", "principal.notify notify-1"],
};
const toLand = async (p: Project) => {
  await start(p, "accept-1");
  await signal(p, "accept-1", answer("accept"), "land-1");
};
const findings = [{ text: "no test for an empty name" }];

describe("lifecycle on fakes", () => {
  test.concurrent("happy path to Closed", async () => {
    const p = project(HAPPY);
    await toLand(p);
    await signal(p, "land-1", answer("approve"), null);
    await expectFinal(p, "closed", [
      ...TO_ACCEPT.core, ...TO_LAND.core,
      "result land-1: land→integrate", "result integrate-1: integrate→deploy", "result deploy-1: deploy→verify",
      "result verify-1: verify→close", ...CLOSE.core,
    ], [
      ...TO_ACCEPT.calls, ...TO_LAND.calls,
      "integrate.run integrate-1", "deploy.run deploy-1", "verify.run verify-1", ...CLOSE.calls,
    ]);
    expect(payloadOf(p.log(), "close-1")).toEqual({ status: "done" });
    expect((await p.snapshot()).outcome).toBe("delivered");
  }, TIMEOUT);

  test.concurrent("fix round: Check fix → Implement with the findings → Check pass → Land", async () => {
    const p = project({ ...HAPPY, "implement.run": [implemented("c1"), implemented("c2")], "check.run": [verdict("fix", findings), verdict("pass")] });
    await start(p, "accept-1");
    await signal(p, "accept-1", answer("accept"), "land-1");
    await expectFinal(p, "land", [
      ...TO_ACCEPT.core,
      "result accept-1: accept→implement", "result implement-1: implement→check", "result check-1: check→implement",
      "result implement-2: implement→check", "result check-2: check→land",
    ], [
      ...TO_ACCEPT.calls,
      "implement.run implement-1", "check.run check-1", "implement.run implement-2", "check.run check-2", "principal.decide land-1",
    ]);
    expect(payloadOf(p.log(), "implement-2")).toEqual({ base: "trunk", criteria, findings });
    expect(payloadOf(p.log(), "check-2")).toEqual({ base: "trunk", criteria, changeset: "c2" });
  }, TIMEOUT);

  test.concurrent("N fix rounds reach Decision; keep_going resets the rounds", async () => {
    const fix = verdict("fix", findings);
    const p = project(
      { ...HAPPY, "implement.run": ["c1", "c2", "c3"].map(implemented), "check.run": [fix, fix, verdict("pass")] },
      { fixRounds: 1 },
    );
    await start(p, "accept-1");
    await signal(p, "accept-1", answer("accept"), "decision-1");
    expect((await p.snapshot()).fixRounds).toBe(1);
    await signal(p, "decision-1", answer("keep_going"), "land-1");
    await expectFinal(p, "land", [
      ...TO_ACCEPT.core,
      "result accept-1: accept→implement", "result implement-1: implement→check", "result check-1: check→implement",
      "result implement-2: implement→check", "result check-2: check→decision",
      "result decision-1: decision→implement", "result implement-3: implement→check", "result check-3: check→land",
    ], [
      ...TO_ACCEPT.calls,
      "implement.run implement-1", "check.run check-1", "implement.run implement-2", "check.run check-2",
      "principal.decide decision-1", "implement.run implement-3", "check.run check-3", "principal.decide land-1",
    ]);
    expect((await p.snapshot()).fixRounds).toBe(0);
    expect(payloadOf(p.log(), "decision-1")).toMatchObject({ on: "decision", options: ["keep_going", "accept", "stop"] });
  }, TIMEOUT);

  test.concurrent("Land rework → Implement with feedback; Land rescope → Define with feedback", async () => {
    const p = project({
      ...HAPPY, "define.run": [defined, defined], "implement.run": [implemented("c1"), implemented("c2")],
      "check.run": [verdict("pass"), verdict("pass")],
    });
    await toLand(p);
    await signal(p, "land-1", answer("rework", "shorter greeting"), "land-2");
    await signal(p, "land-2", answer("rescope", "split off the farewell"), "accept-2");
    await expectFinal(p, "accept", [
      ...TO_ACCEPT.core, ...TO_LAND.core,
      "result land-1: land→implement", "result implement-2: implement→check", "result check-2: check→land",
      "result land-2: land→define", "result define-2: define→accept",
    ], [
      ...TO_ACCEPT.calls, ...TO_LAND.calls,
      "implement.run implement-2", "check.run check-2", "principal.decide land-2", "define.run define-2", "principal.decide accept-2",
    ]);
    expect(payloadOf(p.log(), "implement-2")).toEqual({ base: "trunk", criteria, findings: [], feedback: "shorter greeting" });
    expect(payloadOf(p.log(), "define-2")).toEqual({ base: "trunk", feedback: "split off the farewell" });
  }, TIMEOUT);

  // harlo-38: a comment on keep_going / fix_forward reaches Implement verbatim, and Implement's answer to it
  // lands in the journal — the comment on the `sent` entry, the outcome on the implement result's entry.
  const directive = "Reject an empty name with a 400.\n```diff\n-  return greet(name);\n+  if (!name) return bad();\n```";
  const applied = { outcome: "applied", reason: "added the empty-name guard" };
  const journaledRound = async (p: Project, implementId: string) => {
    const entries = await p.journal();
    const sent = entries.find((e) => e.signal.kind === "sent" && e.signal.id === `${D}/${implementId}`);
    const result = entries.find((e) => e.signal.kind === "result" && e.signal.id === `${D}/${implementId}`);
    return {
      sent: sent?.signal.kind === "sent" ? (sent.signal.payload as { feedback?: string }) : undefined,
      body: result?.signal.kind === "result" ? (result.signal.result as { body?: unknown }).body : undefined,
    };
  };

  test.concurrent("Decision keep_going + comment → Implement with feedback; the outcome is journaled", async () => {
    const fix = verdict("fix", findings);
    const p = project(
      {
        ...HAPPY, "check.run": [fix, fix, verdict("pass")],
        "implement.run": [implemented("c1"), implemented("c2"), ok({ changeset: "c3", feedback: applied })],
      },
      { fixRounds: 1 },
    );
    await start(p, "accept-1");
    await signal(p, "accept-1", answer("accept"), "decision-1");
    await signal(p, "decision-1", answer("keep_going", directive), "land-1");
    expect(payloadOf(p.log(), "implement-3")).toEqual({ base: "trunk", criteria, findings, feedback: directive });
    const { sent, body } = await journaledRound(p, "implement-3");
    expect(sent?.feedback).toBe(directive);
    expect(body).toEqual({ changeset: "c3", feedback: applied });
    expect((await p.snapshot()).fixRounds).toBe(0);
  }, TIMEOUT);

  test.concurrent("Failure fix_forward + comment → Implement with feedback; the outcome is journaled", async () => {
    const declined = { outcome: "declined", reason: "the 500 is the store, not this change" };
    const p = project({
      ...HAPPY, "deploy.run": [verdict("not_live"), verdict("live")],
      "implement.run": [implemented("c1"), ok({ changeset: "c1", feedback: declined })],
      "check.run": [verdict("pass"), verdict("pass")],
    });
    await toLand(p);
    await signal(p, "land-1", answer("approve"), "failure-1");
    await signal(p, "failure-1", answer("fix_forward", directive), "land-2");
    expect(payloadOf(p.log(), "implement-2")).toEqual({ base: "trunk", criteria, findings: [], feedback: directive });
    const { sent, body } = await journaledRound(p, "implement-2");
    expect(sent?.feedback).toBe(directive);
    expect(body).toEqual({ changeset: "c1", feedback: declined });
  }, TIMEOUT);

  // harlo-51: the Define gate's accept takes the same directive path to Implement.
  test.concurrent("Accept accept + comment → Implement with feedback; the outcome is journaled", async () => {
    const p = project({ ...HAPPY, "implement.run": [ok({ changeset: "c1", feedback: applied })] });
    await start(p, "accept-1");
    await signal(p, "accept-1", answer("accept", directive), "land-1");
    expect(payloadOf(p.log(), "implement-1")).toEqual({ base: "trunk", criteria, findings: [], feedback: directive });
    const { sent, body } = await journaledRound(p, "implement-1");
    expect(sent?.feedback).toBe(directive);
    expect(body).toEqual({ changeset: "c1", feedback: applied });
  }, TIMEOUT);

  test.concurrent("a step's question goes to the Principal; the answer re-runs the step with it", async () => {
    const p = project({ ...HAPPY, "define.run": [question("Greet in which language?", "clarify"), defined] });
    await start(p, "ask-1");
    await signal(p, "ask-1", answer("English"), "accept-1");
    await expectFinal(p, "accept", [
      "start: ∅→setup", "result setup-1: setup→define", "result define-1: define→define",
      "result ask-1: define→define", "result define-2: define→accept",
    ], [
      "tracker.read -", "workspace.setup setup-1", "define.run define-1", "principal.ask ask-1", "define.run define-2",
      "principal.decide accept-1",
    ]);
    expect(payloadOf(p.log(), "ask-1")).toMatchObject({ prompt: "Greet in which language?", min: "person" });
    expect(payloadOf(p.log(), "define-2")).toEqual({ base: "trunk", answer: "English" });
  }, TIMEOUT);

  test.concurrent("an integrate conflict: resolved re-runs Integrate; rework goes back to Implement", async () => {
    const conflict = question("Rebase conflict in greet.ts", "conflict");
    const p = project({
      ...HAPPY, "integrate.run": [conflict, conflict], "implement.run": [implemented("c1"), implemented("c2")],
      "check.run": [verdict("pass"), verdict("pass")],
    });
    await toLand(p);
    await signal(p, "land-1", answer("approve"), "ask-1");
    await signal(p, "ask-1", answer("resolved"), "ask-2");
    await signal(p, "ask-2", answer("rework"), "land-2");
    await expectFinal(p, "land", [
      ...TO_ACCEPT.core, ...TO_LAND.core,
      "result land-1: land→integrate", "result integrate-1: integrate→integrate",
      "result ask-1: integrate→integrate", "result integrate-2: integrate→integrate",
      "result ask-2: integrate→implement", "result implement-2: implement→check", "result check-2: check→land",
    ], [
      ...TO_ACCEPT.calls, ...TO_LAND.calls,
      "integrate.run integrate-1", "principal.ask ask-1", "integrate.run integrate-2", "principal.ask ask-2",
      "implement.run implement-2", "check.run check-2", "principal.decide land-2",
    ]);
    expect(payloadOf(p.log(), "ask-1")).toMatchObject({ options: ["resolved", "rework"] });
    expect(payloadOf(p.log(), "integrate-2")).toEqual({ changeset: "c1", answer: "resolved" });
  }, TIMEOUT);

  test.concurrent("failed past the retry cap → Blocked; retry re-runs the failed command", async () => {
    const p = project({ ...HAPPY, "workspace.setup": [failed("disk full"), failed("disk full"), ok({ path: "/ws/k-1", base: "trunk" })] });
    await start(p, "blocked-1");
    expect((await p.snapshot())).toMatchObject({ at: "blocked", blockedAt: "setup" });
    await signal(p, "blocked-1", answer("retry"), "accept-1");
    await expectFinal(p, "accept", [
      "start: ∅→setup", "result setup-1: setup→setup", "result setup-2: setup→blocked",
      "result blocked-1: blocked→setup", "result setup-3: setup→define", "result define-1: define→accept",
    ], [
      "tracker.read -", "workspace.setup setup-1", "workspace.setup setup-2", "principal.decide blocked-1",
      "workspace.setup setup-3", "define.run define-1", "principal.decide accept-1",
    ]);
    expect(payloadOf(p.log(), "blocked-1")).toMatchObject({ on: "blocked", options: ["retry", "stop"] });
  }, TIMEOUT);

  test.concurrent("Failure gate accept closes with accepted_with_failure", async () => {
    const p = project({ ...HAPPY, "deploy.run": [verdict("not_live", [{ text: "health check red" }])] });
    await toLand(p);
    await signal(p, "land-1", answer("approve"), "failure-1");
    await signal(p, "failure-1", answer("accept"), null);
    await expectFinal(p, "closed", [
      ...TO_ACCEPT.core, ...TO_LAND.core,
      "result land-1: land→integrate", "result integrate-1: integrate→deploy", "result deploy-1: deploy→failure",
      "result failure-1: failure→close", ...CLOSE.core,
    ], [
      ...TO_ACCEPT.calls, ...TO_LAND.calls,
      "integrate.run integrate-1", "deploy.run deploy-1", "principal.decide failure-1", ...CLOSE.calls,
    ]);
    expect(payloadOf(p.log(), "close-1")).toEqual({ status: "done-with-failure" });
    expect((await p.snapshot()).outcome).toBe("accepted_with_failure");
  }, TIMEOUT);

  test.concurrent("stop mid-step cancels the running step and keeps the workspace (no Teardown)", async () => {
    const p = project({ ...HAPPY, "define.run": [] }); // define accepts: it is still running when stop arrives
    await start(p, "define-1");
    await step(p, null, "stop", D, "abandoned", "not needed");
    await expectFinal(p, "abandoned", ["start: ∅→setup", "result setup-1: setup→define", "stop: define→abandoned"], [
      "tracker.read -", "workspace.setup setup-1", "define.run define-1",
      "define.cancel cancel-1", "tracker.comment comment-1", "principal.notify notify-1",
    ]);
    expect(payloadOf(p.log(), "cancel-1")).toEqual({ target: `${D}/define-1` });
    expect(payloadOf(p.log(), "comment-1")).toEqual({ text: "abandoned: not needed" });
    expect((await p.snapshot())).toMatchObject({ outcome: "abandoned", reason: "not needed", workspace: "/ws/k-1" });
  }, TIMEOUT);

  test.concurrent("changed before Land re-runs Define; changed after Land only notifies", async () => {
    const p = project({
      ...HAPPY, "integrate.run": [], // integrate accepts: still running when the second change arrives
      "define.run": [defined, ok({ criteria: ["greets Ada by full name"], runbook })],
      "tracker.read": [workItem(), workItem("Greet by full name"), workItem("Greet by nickname")],
    });
    await start(p, "accept-1");
    await step(p, "accept-2", "changed", D);
    await signal(p, "accept-2", answer("accept"), "land-1");
    await signal(p, "land-1", answer("approve"), "integrate-1");
    await step(p, "integrate-1", "changed", D);
    await expectFinal(p, "integrate", [
      ...TO_ACCEPT.core, "changed: accept→define", "result define-2: define→accept",
      "result accept-2: accept→implement", "result implement-1: implement→check", "result check-1: check→land",
      "result land-1: land→integrate", "changed: integrate→integrate [workitem_changed_late]",
    ], [
      ...TO_ACCEPT.calls, "tracker.read -", "principal.cancel cancel-1", "define.run define-2", "principal.decide accept-2",
      "implement.run implement-1", "check.run check-1", "principal.decide land-1", "integrate.run integrate-1",
      "tracker.read -", "principal.notify notify-1",
    ]);
    expect(payloadOf(p.log(), "cancel-1")).toEqual({ target: `${D}/accept-1` });
    expect(p.log().find((s) => s.id === `${D}/define-2`)?.workItem).toMatchObject({ title: "Greet by full name" });
    const accept2 = payloadOf(p.log(), "accept-2") as { evidence: Record<string, unknown> };
    expect(accept2.evidence).toMatchObject({ workItem: { title: "Greet by full name" }, criteria: ["greets Ada by full name"] });
    expect(accept2.evidence).not.toHaveProperty("note");
    expect(payloadOf(p.log(), "notify-1")).toEqual({ text: "WorkItem changed after Land; flow unchanged" });
    expect((await p.snapshot()).workItem.title).toBe("Greet by nickname");
  }, TIMEOUT);

  test.concurrent("a stale duplicate Result is ignored and journaled", async () => {
    const p = project(HAPPY);
    await toLand(p);
    const ran = await signal(p, "accept-1", answer("accept"), "land-1");
    expect(ran.out).toMatchObject({ issued: [], ignored: true });
    await expectFinal(p, "land", [...TO_ACCEPT.core, ...TO_LAND.core, "result accept-1: land→land [ignored_stale]"], [
      ...TO_ACCEPT.calls, ...TO_LAND.calls,
    ]);
  }, TIMEOUT);

  test.concurrent("a duplicate start is rejected on the open Delivery", async () => {
    const p = project(HAPPY);
    await start(p, "accept-1");
    const ran = await start(p, "accept-1");
    expect(ran.out).toMatchObject({ delivery: D, issued: [], rejected: true });
    await expectFinal(p, "accept", [...TO_ACCEPT.core, "start: accept→accept [rejected_start]"], [
      ...TO_ACCEPT.calls, "tracker.read -",
    ]);
  }, TIMEOUT);
});
