import { describe, expect, test } from "bun:test";
import { start } from "./start";
import { transition } from "./transition";
import type { Command, Snapshot } from "./types";
import { awaited, changeset, policy, requirements, snapshotAt, workItem } from "./fixtures/builders.fixture";
import { applyTransition, ignoredRows, transitionRows } from "./fixtures/rows.fixture";

describe("transition (§4)", () => {
  test.each(transitionRows)("$id $name", (row) => {
    const before = structuredClone(row.state);
    const out = applyTransition(row);

    expect(out.state.at).toBe(row.expect.at);
    expect(out.commands).toEqual(row.expect.commands);
    expect(out.state).toMatchObject(row.expect.state);
    expect(out.entry).toEqual({ delivery: row.state.delivery, signal: row.signal, ...row.expect.entry });
    expect(row.state).toEqual(before); // pure: the input snapshot is untouched
  });
});

describe("ignored signals return the state deep-equal (I5)", () => {
  test.each(ignoredRows)("$id $name", (row) => {
    expect(applyTransition(row).state).toEqual(row.state);
  });
});

describe("Blocked recovery signal (B8)", () => {
  const stranded = () => {
    const blocked = transitionRows.find((r) => r.id === "B6")!;
    return applyTransition(blocked).state; // the blocked decide failed: awaiting nothing, no commands
  };

  test("a failed blocked decide leaves nothing awaited and issues nothing (AC6)", () => {
    const out = applyTransition(transitionRows.find((r) => r.id === "B6")!);
    expect(out.state.awaiting).toBeNull();
    expect(out.commands).toEqual([]);
  });

  test("retry resumes at the blocked step, and a second retry is ignored (AC5, AC7)", () => {
    const first = transition(policy, stranded(), { kind: "blocked_recovery", action: "retry" });
    expect(first.state.at).toBe("deploy");
    expect(first.commands).toHaveLength(1);
    const again = transition(policy, first.state, { kind: "blocked_recovery", action: "retry" });
    expect(again.state).toEqual(first.state);
    expect(again.commands).toEqual([]);
  });

  test("stop abandons, and a second stop is ignored (AC5, AC7)", () => {
    const first = transition(policy, stranded(), { kind: "blocked_recovery", action: "stop" });
    expect(first.state.at).toBe("abandoned");
    const again = transition(policy, first.state, { kind: "blocked_recovery", action: "stop" });
    expect(again.state).toEqual(first.state);
    expect(again.commands).toEqual([]);
  });
});

describe("the main-line base flows from workspace.setup into every agent step (harlo-52)", () => {
  type Out = { state: Snapshot; commands: Command[] };
  const run = (out: Out): Command => out.commands.find((c) => c.await)!;
  const reply = (out: Out, body: unknown): Out =>
    transition(policy, out.state, { kind: "result", id: out.state.awaiting!.id, result: { status: "ok", body } });
  const asked = (out: Out): Out => transition(policy, out.state, {
    kind: "result", id: out.state.awaiting!.id, result: { status: "question", prompt: "which?", about: "clarify" },
  });
  const decided = (out: Out, value: string, comment?: string): Out =>
    reply(out, { answer: value, by: "person", ...(comment === undefined ? {} : { comment }) });

  test("fresh runs and feedback/answer/findings re-runs all carry base", () => {
    const created = start(policy, workItem, []);
    if (created.kind !== "created") throw new Error("not created");
    const defined1 = reply(created, { path: "/ws/k-1", base: "dogfood" });
    expect(defined1.state.base).toBe("dogfood");
    expect(run(defined1)).toMatchObject({ port: "define", payload: { base: "dogfood" } });

    const answeredDefine = decided(asked(defined1), "hi"); // a question's answer re-runs Define
    expect(run(answeredDefine)).toMatchObject({ port: "define", payload: { base: "dogfood", answer: "hi" } });

    const accept = reply(answeredDefine, { requirements });
    const implement1 = decided(accept, "accept", "keep it short"); // Define-gate comment → Implement feedback
    expect(run(implement1)).toMatchObject({ port: "implement", payload: { base: "dogfood", feedback: "keep it short" } });

    const answeredImplement = decided(asked(implement1), "yes");
    expect(run(answeredImplement)).toMatchObject({ port: "implement", payload: { base: "dogfood", answer: "yes" } });

    const check1 = reply(answeredImplement, { changeset });
    expect(run(check1)).toMatchObject({ port: "check", payload: { base: "dogfood", changeset } });

    const findings = [{ text: "missing test" }];
    const implement2 = reply(check1, { verdict: "fix", findings }); // a fix round
    expect(run(implement2)).toMatchObject({ port: "implement", payload: { base: "dogfood", findings } });

    const answeredCheck = decided(asked(reply(implement2, { changeset })), "ok");
    expect(run(answeredCheck)).toMatchObject({ port: "check", payload: { base: "dogfood", answer: "ok" } });

    const land = reply(answeredCheck, { verdict: "pass" });
    const rescoped = decided(land, "rescope", "narrower"); // Land rescope → Define with feedback
    expect(run(rescoped)).toMatchObject({ port: "define", payload: { base: "dogfood", feedback: "narrower" } });
  });

  test("a Delivery persisted before harlo-52 has no base: its payloads omit it and nothing throws", () => {
    const implement1 = awaited("implement-1", "implement", "run", { requirements, findings: [] }, "implement", "run");
    const legacy = snapshotAt("implement", implement1);
    expect("base" in legacy).toBe(false);
    const check1 = reply({ state: legacy, commands: [] }, { changeset });
    expect(run(check1).payload).toEqual({ requirements, changeset });
    const implement2 = reply(check1, { verdict: "fix", findings: [{ text: "f" }] });
    expect(run(implement2).payload).toEqual({ requirements, findings: [{ text: "f" }] });
  });
});
