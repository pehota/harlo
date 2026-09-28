import { describe, expect, test } from "bun:test";
import { commandId, deliveryId, isValidKey, nextId, parseCommandId } from "./ids";

describe("deliveryId", () => {
  test.each([
    ["PROJ-123", 2, "PROJ-123-2"],
    ["k", 1, "k-1"],
  ])("deliveryId(%p, %p) = %p", (key, attempt, expected) => {
    expect(deliveryId(key, attempt)).toBe(expected);
  });
});

describe("nextId", () => {
  test.each([
    ["first id for a name", {}, "land", "land-1", { land: 1 }],
    ["second id for a name", { land: 1 }, "land", "land-2", { land: 2 }],
    ["names count independently", { land: 3 }, "ask", "ask-1", { land: 3, ask: 1 }],
  ])("%s", (_, seq, name, suffix, nextSeq) => {
    const before = structuredClone(seq);
    const out = nextId(seq, name);
    expect(out).toEqual({ suffix, seq: nextSeq });
    expect(seq).toEqual(before); // pure: input seq untouched
  });

  test("commandId joins delivery and suffix", () => {
    expect(commandId("PROJ-123-2", "land-1")).toBe("PROJ-123-2/land-1");
  });
});

describe("key regex", () => {
  test.each([
    ["PROJ-123", true],
    ["a", true],
    ["a.b_c-9", true],
    ["9lives", true],
    ["", false],
    ["-lead", false],
    [".hidden", false],
    ["has/slash", false],
    ["has space", false],
  ])("isValidKey(%p) = %p", (key, expected) => {
    expect(isValidKey(key)).toBe(expected);
  });
});

describe("parseCommandId", () => {
  test.each([
    ["PROJ-123-2/land-1", { delivery: "PROJ-123-2", name: "land", n: 1 }],
    ["k-1/setup-12", { delivery: "k-1", name: "setup", n: 12 }],
    ["a.b_c-3/ask-2", { delivery: "a.b_c-3", name: "ask", n: 2 }],
    ["PROJ-123-2", null], // no name part
    ["PROJ-123-2/land", null], // no counter
    ["PROJ-123-2/land-0", null], // counters start at 1
    ["PROJ/land-1", null], // delivery has no attempt
    ["PROJ-123-2/Land-1", null], // names are lower case
    ["x/y/land-1", null],
  ])("parseCommandId(%p)", (id, expected) => {
    expect(parseCommandId(id)).toEqual(expected);
  });
});
