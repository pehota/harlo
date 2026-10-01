// Every core row table (test data), registered once. start.test.ts, transition.test.ts and invariants.test.ts
// run these; a new batch adds its <name>.fixture.ts file and appends it to `transitionRows`.
import { start } from "../start";
import { transition } from "../transition";
import type { StartOutput, TransitionOutput } from "../types";
import { type StartRow, type TransitionRow, policy } from "./builders.fixture";
import { blockedRows, recoveryRows } from "./blocked.fixture";
import { deliveryRows } from "./delivery.fixture";
import { failureRows } from "./failure.fixture";
import { fixRows } from "./fix.fixture";
import { happyRows } from "./happy.fixture";
import { ignoredRows, recoveryIgnoredRows } from "./ignored.fixture";
import { questionRows } from "./questions.fixture";
import { startRows } from "./start.fixture";

export { ignoredRows, startRows };
export const transitionRows: TransitionRow[] = [...happyRows, ...ignoredRows, ...recoveryIgnoredRows, ...fixRows, ...failureRows, ...questionRows, ...blockedRows, ...recoveryRows, ...deliveryRows];

export const applyStart = (row: StartRow): StartOutput => start(row.policy ?? policy, row.workItem, row.existing);
export const applyTransition = (row: TransitionRow): TransitionOutput =>
  transition(row.policy ?? policy, row.state, row.signal);
