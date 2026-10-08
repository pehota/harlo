// Gate comment routes (harlo-51): every option the core offers at every gate has a COMMENT_ROUTES entry, and
// applying it with a comment does what the entry says — feedback to a step, the Delivery's reason, or dropped.
import { describe, expect, test } from "bun:test";
import type { Decide, DecidePoint } from "../contracts/common";
import { COMMENT_ROUTES, GATE_OPTIONS, commentRoute, enterBlocked, enterDecision, enterGate } from "./gates";
import type { Move } from "./steps";
import { transition } from "./transition";
import { answer, awaited, changeset, policy, requirements, snapshotAt } from "./fixtures/builders.fixture";

const COMMENT = "a comment, verbatim:\n- with a list";
const deploy1 = awaited("deploy-1", "deploy", "run", { changeset }, "deploy", "run");

/** The core's own decide at each gate, entered the way the flow enters it. */
const ENTER: Record<DecidePoint, () => Move> = {
  accept: () => enterGate(policy, snapshotAt("define", null), "accept"),
  decision: () => enterDecision(policy, snapshotAt("check", null), "scope"),
  land: () => enterGate(policy, snapshotAt("check", null), "land"),
  failure: () => enterGate(policy, snapshotAt("verify", null), "failure"),
  blocked: () => enterBlocked(policy, snapshotAt("deploy", null), "deploy", deploy1),
};

const pairs = (Object.keys(ENTER) as DecidePoint[]).flatMap((on) => {
  const gate = ENTER[on]().state;
  const offered = (gate.awaiting!.payload as Decide).options;
  return offered.map((option) => ({ on, option, label: `${on}.${option}`, gate }));
});

/** The answers AC4 classifies, by where their comment goes. */
const byRoute = (goes: string): string[] =>
  pairs.filter((p) => commentRoute(p.on, p.option)?.goes === goes).map((p) => p.label).sort();

describe("COMMENT_ROUTES (harlo-51)", () => {
  test("every gate the core enters is covered, with the options GATE_OPTIONS lists", () => {
    expect(Object.keys(COMMENT_ROUTES).sort()).toEqual(Object.keys(GATE_OPTIONS).sort());
    for (const on of Object.keys(ENTER) as DecidePoint[]) {
      expect(pairs.filter((p) => p.on === on).map((p) => p.option)).toEqual([...GATE_OPTIONS[on]]);
    }
  });

  test("classifies each answer as the WorkItem tables it", () => {
    expect(byRoute("feedback")).toEqual(
      ["accept.accept", "accept.adjust", "decision.keep_going", "failure.fix_forward", "land.rescope", "land.rework"]);
    expect(byRoute("reason")).toEqual(["blocked.stop", "decision.stop", "failure.accept"]);
    expect(byRoute("dropped")).toEqual(["blocked.retry", "decision.accept", "land.approve"]);
  });

  test.each(pairs)("$label with a comment goes where its route says", ({ on, option, gate }) => {
    const route = commentRoute(on, option);
    expect(route).toBeDefined(); // an offered option with no classification fails here
    expect((gate.awaiting!.payload as Decide).comments[option]).toEqual(route!);

    const decide = gate.awaiting!;
    const withComment = transition(policy, gate, answer(decide, option, "person", COMMENT));
    const without = transition(policy, gate, answer(decide, option));

    switch (route!.goes) {
      case "feedback": {
        const step = withComment.commands.find((c) => c.await)!;
        expect(step).toMatchObject({ port: route!.to, op: "run" });
        expect((step.payload as { feedback?: string }).feedback).toBe(COMMENT);
        expect(without.commands.find((c) => c.await)!.payload).not.toHaveProperty("feedback");
        expect(withComment.entry.note).toBeUndefined();
        break;
      }
      case "reason": {
        expect(withComment.state.reason).toBe(COMMENT);
        const texts = withComment.commands
          .filter((c) => c.op === "comment" || c.op === "notify")
          .map((c) => (c.payload as { text: string }).text);
        expect(texts.length).toBeGreaterThan(0); // the default policy comments on both outcomes
        for (const text of texts) expect(text).toEndWith(`: ${COMMENT}`);
        expect(withComment.entry.note).toBeUndefined();
        break;
      }
      case "dropped": {
        expect(withComment.state).toEqual(without.state);
        expect(withComment.commands).toEqual(without.commands);
        expect(withComment.entry.note).toBe("ignored_comment");
        expect(without.entry.note).toBeUndefined();
        break;
      }
    }
  });
});

describe("Blocked at Implement: retry's comment reaches Implement as feedback (harlo-62)", () => {
  const implement1 = awaited("implement-1", "implement", "run", { requirements, findings: [] }, "implement", "run");
  const gate = enterBlocked(policy, snapshotAt("implement", null), "implement", implement1).state;
  const decide = gate.awaiting!;
  const recover = (comment?: string) => ({ kind: "blocked_recovery", action: "retry", ...(comment === undefined ? {} : { comment }) }) as const;

  test("the blocked decide offers retry's comment to Implement; elsewhere it stays dropped", () => {
    expect((decide.payload as Decide).comments).toEqual({ retry: { goes: "feedback", to: "implement" }, stop: { goes: "reason" } });
    expect(commentRoute("blocked", "retry", "implement")).toEqual({ goes: "feedback", to: "implement" });
    expect(commentRoute("blocked", "retry", "deploy")).toEqual({ goes: "dropped" });
    expect(commentRoute("blocked", "retry")).toEqual({ goes: "dropped" });
  });

  test("retry + comment re-issues the saved command with the comment as feedback, otherwise unchanged", () => {
    const out = transition(policy, gate, answer(decide, "retry", "person", COMMENT));
    const step = out.commands.find((c) => c.await)!;
    expect(step).toMatchObject({ port: "implement", op: "run", payload: { ...(implement1.payload as object), feedback: COMMENT } });
    expect(out.state).toMatchObject({ at: "implement", blockedAt: null, blockedCmd: null, retries: 0 });
    expect(out.entry.note).toBeUndefined();
  });

  test("retry without a comment re-issues the saved command exactly as before", () => {
    const step = transition(policy, gate, answer(decide, "retry")).commands.find((c) => c.await)!;
    expect(step.payload).toEqual(implement1.payload);
  });

  test("the guidance joins feedback the saved command already carried", () => {
    const fed = { ...implement1, payload: { ...(implement1.payload as object), feedback: "earlier" } };
    const at = enterBlocked(policy, snapshotAt("implement", null), "implement", fed).state;
    const step = transition(policy, at, answer(at.awaiting!, "retry", "person", COMMENT)).commands.find((c) => c.await)!;
    expect((step.payload as { feedback: string }).feedback).toBe(`earlier\n\n${COMMENT}`);
  });

  test("`ship signal --blocked retry --comment` routes the comment the same way", () => {
    const out = transition(policy, gate, recover(COMMENT));
    expect(out.commands.find((c) => c.await)!.payload).toMatchObject({ feedback: COMMENT });
    expect(out.entry.note).toBeUndefined();
    expect(transition(policy, gate, recover()).commands.find((c) => c.await)!.payload).toEqual(implement1.payload);
  });

  test("a recovery retry comment at a non-Implement block is dropped and journaled as ignored", () => {
    const at = ENTER.blocked().state;
    const withComment = transition(policy, at, recover(COMMENT));
    const without = transition(policy, at, recover());
    expect(withComment.commands).toEqual(without.commands);
    expect(withComment.entry.note).toBe("ignored_comment");
  });
});
