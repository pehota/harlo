// Every core row table, registered once. start.test.ts, transition.test.ts and invariants.test.ts
// run these; a new batch adds its table file here.
import { start } from "../start";
import type { StartOutput } from "../types";
import { type StartRow, policy } from "./fixtures";
import { startRows } from "./start";

export { startRows };

export const applyStart = (row: StartRow): StartOutput => start(row.policy ?? policy, row.workItem, row.existing);
