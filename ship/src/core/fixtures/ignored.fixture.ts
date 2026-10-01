// §4.8 ignored rows: the state comes back deep-equal (I5), nothing is issued.
import type { Note, Signal, Snapshot } from "../types";
import { type TransitionRow, awaited, ok, snapshotAt, workItem } from "./builders.fixture";

export const ignored = (id: string, name: string, state: Snapshot, signal: Signal, note: Note): TransitionRow => ({
  id, name, state, signal,
  expect: { at: state.at, commands: [], state, entry: { from: state.at, to: state.at, issued: [], note } },
});

const define1 = awaited("define-1", "define", "run", {}, "define", "run");
const define2 = awaited("define-2", "define", "run", { feedback: "shorter" }, "define", "run");
const teardown1 = awaited("teardown-1", "workspace", "teardown", { path: "/ws/k-1" }, "teardown", "run");

export const ignoredRows: TransitionRow[] = [
  ignored("R1", "result for an earlier command id is stale",
    snapshotAt("define", define2), ok(define1, { criteria: [], runbook: [] }), "ignored_stale"),
  ignored("R1", "result for another Delivery's id is stale",
    snapshotAt("define", define1), { kind: "result", id: "k-2/define-1", result: { status: "ok", body: {} } }, "ignored_stale"),
  ignored("R1", "result while awaiting nothing (blocked after B6) is stale",
    snapshotAt("blocked", null, { blockedAt: "deploy" }), { kind: "result", id: "k-1/blocked-1", result: { status: "failed", info: "x" } }, "ignored_stale"),
  ignored("R2", "result on closed is ignored",
    snapshotAt("closed", null, { outcome: "delivered" }), ok(teardown1, {}), "ignored_terminal"),
  ignored("R2", "stop on abandoned is ignored",
    snapshotAt("abandoned", null, { outcome: "abandoned", reason: "no longer needed" }),
    { kind: "stop", outcome: "rolled_back", reason: "late" }, "ignored_terminal"),
  ignored("R2", "workItem_changed on closed is ignored",
    snapshotAt("closed", null, { outcome: "delivered" }),
    { kind: "workItem_changed", workItem: { ...workItem, title: "Greet everyone" } }, "ignored_terminal"),
];

const recovery: Signal = { kind: "blocked_recovery", action: "retry" };
const land1 = awaited("land-1", "principal", "decide", {}, "land", "decide");

export const recoveryIgnoredRows: TransitionRow[] = [
  ignored("B8", "recovery signal at a step is ignored", snapshotAt("define", define1), recovery, "ignored_not_blocked"),
  ignored("B8", "recovery signal at a gate is ignored", snapshotAt("land", land1), recovery, "ignored_not_blocked"),
  ignored("B8", "recovery signal at a question is ignored",
    snapshotAt("verify", awaited("ask-1", "principal", "decide", {}, "verify", "ask"), { lastRun: awaited("verify-1", "verify", "run", {}, "verify", "run") }),
    recovery, "ignored_not_blocked"),
  ignored("B8", "recovery signal on a stopped Delivery is ignored (terminal)",
    snapshotAt("abandoned", null, { outcome: "abandoned", reason: "x" }), recovery, "ignored_terminal"),
];
