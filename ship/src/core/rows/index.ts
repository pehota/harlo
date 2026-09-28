// Every core row table, registered once. start.test.ts, transition.test.ts and invariants.test.ts
// run these; a new batch adds its table file and appends it to `transitionRows`.
import { start } from "../start";
import { transition } from "../transition";
import type { StartOutput, TransitionOutput } from "../types";
import { type StartRow, type TransitionRow, policy } from "./fixtures";
import { blockedRows } from "./blocked";
import { failureRows } from "./failure";
import { fixRows } from "./fix";
import { happyRows } from "./happy";
import { ignoredRows } from "./ignored";
import { questionRows } from "./questions";
import { startRows } from "./start";

export { ignoredRows, startRows };
export const transitionRows: TransitionRow[] = [...happyRows, ...ignoredRows, ...fixRows, ...failureRows, ...questionRows, ...blockedRows];

export const applyStart = (row: StartRow): StartOutput => start(row.policy ?? policy, row.workItem, row.existing);
export const applyTransition = (row: TransitionRow): TransitionOutput =>
  transition(row.policy ?? policy, row.state, row.signal);
