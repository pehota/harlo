import { describe, expect, test } from "bun:test";
import { applyTransition, ignoredRows, transitionRows } from "./rows";

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
