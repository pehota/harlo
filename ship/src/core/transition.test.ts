import { describe, expect, test } from "bun:test";
import { transition } from "./transition";
import { policy } from "./fixtures/builders.fixture";
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
