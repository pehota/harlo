import { expect, test } from "bun:test";
import { STEPS } from "./core/types";

test("core types load", () => {
  expect(STEPS).toHaveLength(9);
});
