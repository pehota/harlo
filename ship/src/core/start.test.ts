import { describe, expect, test } from "bun:test";
import { applyStart, startRows } from "./fixtures/rows.fixture";
import type { StartRow } from "./fixtures/builders.fixture";

describe("start (§4.1)", () => {
  test.each(startRows)("$id $name", (row) => {
    const out = applyStart(row);
    const got: Pick<StartRow["expect"], "kind" | "delivery" | "commands"> = out.kind === "created"
      ? { kind: out.kind, delivery: out.state.delivery, commands: out.commands }
      : { kind: out.kind, delivery: out.delivery, commands: [] };

    expect(got).toEqual({ kind: row.expect.kind, delivery: row.expect.delivery, commands: row.expect.commands });
    if (out.kind === "created") expect(out.state).toMatchObject(row.expect.state ?? {});
    expect(out.entry).toEqual({
      delivery: row.expect.delivery,
      signal: { kind: "start", workItem: row.workItem },
      ...row.expect.entry,
    });
  });
});
