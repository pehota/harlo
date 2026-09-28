// §4.7 Delivery-signal rows: stop (D1–D3) and workItem_changed (W1–W6).
import type { Finding, WorkItem } from "../../contracts/common";
import {
  type TransitionRow, OPTIONS, ask, awaited, cancel, changed, changeset, cmd, criteria, decide, fire, gateEvidence,
  id, snapshotAt, stop, workItem, workspace,
} from "./builders.fixture";
import { ignored } from "./ignored.fixture";

const findings: Finding[] = [{ text: "empty name is not rejected" }];
const edited: WorkItem = { ...workItem, body: "Say hello to the given name, in German too." };
const edit = changed({ body: edited.body });
const LATE = { text: "WorkItem changed after Land; flow unchanged" };

const setup1 = awaited("setup-1", "workspace", "setup", {}, "setup", "run");
const define = (n: number) => awaited(`define-${n}`, "define", "run", {}, "define", "run");
const implement1 = awaited("implement-1", "implement", "run", { criteria, findings }, "implement", "run");
const check1 = awaited("check-1", "check", "run", { criteria, changeset }, "check", "run");
const close1 = awaited("close-1", "tracker", "update", { status: "done" }, "close", "run");
const teardown1 = awaited("teardown-1", "workspace", "teardown", { path: workspace }, "teardown", "run");
const accept1 = decide("accept", 1, OPTIONS.accept, "person");
const land1 = decide("land", 1, OPTIONS.land, "person");
const decision1 = decide("decision", 1, OPTIONS.decision, "person", gateEvidence({ findings }));
const blocked1 = decide("blocked", 1, OPTIONS.blocked, "person");
const clarify1 = ask(1, "define", "clarify", "Greet by first or full name?", "model");
const locale1 = ask(1, "check", "clarify", "Which locale?", "model");

/** Blocked at `node`, awaiting the blocked decide (or nothing, after B6). */
const blockedAt = (node: "setup" | "define" | "accept" | "check" | "deploy", awaiting: typeof blocked1 | null = blocked1) =>
  snapshotAt("blocked", awaiting, { blockedAt: node, blockedCmd: setup1, seq: { blocked: 1 } });

/** abandon(o, r) fires per the fixture policy: rolled_back → status reopened + comment; abandoned → comment. */
const abandonFires = (outcome: "rolled_back" | "abandoned", reason: string) => [
  ...(outcome === "rolled_back" ? [fire("update-1", "tracker", "update", { status: "reopened" })] : []),
  fire("comment-1", "tracker", "comment", { text: `${outcome}: ${reason}` }),
  fire("notify-1", "principal", "notify", { text: `abandoned: ${outcome}: ${reason}` }),
];
const ids = (commands: { id: string }[]) => commands.map((c) => c.id);

const stopped = (
  rowId: string, name: string, state: ReturnType<typeof snapshotAt>, outcome: "rolled_back" | "abandoned",
  reason: string,
): TransitionRow => {
  const commands = [...(state.awaiting ? [cancel(1, state.awaiting)] : []), ...abandonFires(outcome, reason)];
  return {
    id: rowId, name, state, signal: stop(outcome, reason),
    expect: {
      at: "abandoned",
      commands,
      state: { outcome, reason, awaiting: null, blockedAt: null, blockedCmd: null, workspace },
      entry: { from: state.at, to: "abandoned", issued: ids(commands) },
    },
  };
};

export const deliveryRows: TransitionRow[] = [
  stopped("D1", "stop while a step runs → cancel it, abandon; workspace kept",
    snapshotAt("implement", implement1), "rolled_back", "reverted by ops"),
  stopped("D1", "stop at a gate → cancel the decide at the principal port",
    snapshotAt("land", land1), "abandoned", "no longer needed"),
  stopped("D1", "stop while blocked → cancel the blocked decide, blockedAt cleared",
    blockedAt("deploy"), "abandoned", "registry retired"),
  stopped("D2", "stop while blocked awaiting nothing (after B6) → abandon only",
    blockedAt("deploy", null), "abandoned", "no answer"),
  stopped("D3", "stop at close → cancel the close update; stop's outcome overwrites delivered",
    snapshotAt("close", close1, { outcome: "delivered" }), "rolled_back", "bad release"),
  stopped("D3", "stop at teardown → cancel teardown; outcome overwritten, no teardown re-issued",
    snapshotAt("teardown", teardown1, { outcome: "delivered" }), "rolled_back", "bad release"),

  ignored("W1", "changed with equal title and body (url differs) is unchanged",
    snapshotAt("implement", implement1), changed({ url: "https://example.test/k" }), "workitem_unchanged"),
  ignored("W1", "changed with equal title and body while blocked is unchanged",
    blockedAt("check"), changed({}), "workitem_unchanged"),
  {
    id: "W2", name: "changed at setup → stay, WorkItem updated",
    state: snapshotAt("setup", setup1, { criteria: null, runbook: null, changeset: null, workspace: null }),
    signal: edit,
    expect: {
      at: "setup", commands: [],
      state: { workItem: edited, awaiting: setup1 },
      entry: { from: "setup", to: "setup", issued: [] },
    },
  },
  {
    id: "W2", name: "changed while blocked at setup → stay blocked, blockedAt kept",
    state: blockedAt("setup"),
    signal: edit,
    expect: {
      at: "blocked", commands: [],
      state: { workItem: edited, blockedAt: "setup", blockedCmd: setup1, awaiting: blocked1 },
      entry: { from: "blocked", to: "blocked", issued: [] },
    },
  },
  {
    id: "W3", name: "changed at define → cancel define, run define again",
    state: snapshotAt("define", define(1), { seq: { define: 1 } }),
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, define(1)), cmd(define(2))],
      state: { workItem: edited, awaiting: define(2), lastRun: define(2) },
      entry: { from: "define", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W3", name: "changed while define awaits an ask → cancel the ask, run define again",
    state: snapshotAt("define", clarify1, { lastRun: define(1), seq: { define: 1, ask: 1 } }),
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, clarify1), cmd(define(2))],
      state: { workItem: edited, awaiting: define(2) },
      entry: { from: "define", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W3", name: "changed while blocked at define → cancel the blocked decide, define, blockedAt = null",
    state: { ...blockedAt("define"), blockedCmd: define(1), seq: { define: 1, blocked: 1 } },
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, blocked1), cmd(define(2))],
      state: { workItem: edited, blockedAt: null, blockedCmd: null, retries: 0, awaiting: define(2) },
      entry: { from: "blocked", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W3", name: "changed while blocked at define awaiting nothing → define, no cancel",
    state: { ...blockedAt("define", null), blockedCmd: define(1), seq: { define: 1, blocked: 1 } },
    signal: edit,
    expect: {
      at: "define",
      commands: [cmd(define(2))],
      state: { blockedAt: null, blockedCmd: null, awaiting: define(2) },
      entry: { from: "blocked", to: "define", issued: [id("define-2")] },
    },
  },
  {
    id: "W4", name: "changed at accept → cancel the decide, run define again",
    state: snapshotAt("accept", accept1, { changeset: null, seq: { define: 1, accept: 1 } }),
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, accept1), cmd(define(2))],
      state: { workItem: edited, awaiting: define(2), lastRun: define(2) },
      entry: { from: "accept", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W4", name: "changed while blocked at accept → define, blockedAt = null",
    state: { ...blockedAt("accept"), blockedCmd: accept1, seq: { define: 1, accept: 1, blocked: 1 } },
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, blocked1), cmd(define(2))],
      state: { workItem: edited, blockedAt: null, blockedCmd: null, awaiting: define(2) },
      entry: { from: "blocked", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W5", name: "changed at implement → cancel, back to define; fix rounds and findings unchanged",
    state: snapshotAt("implement", implement1, { fixRounds: 1, findings, seq: { define: 1, accept: 1, implement: 1 } }),
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, implement1), cmd(define(2))],
      state: { workItem: edited, fixRounds: 1, findings, awaiting: define(2), lastRun: define(2) },
      entry: { from: "implement", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W5", name: "changed while check awaits an ask → cancel the ask, back to define",
    state: snapshotAt("check", locale1, { lastRun: check1, seq: { define: 1, accept: 1, check: 1, ask: 1 } }),
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, locale1), cmd(define(2))],
      state: { workItem: edited, awaiting: define(2), lastRun: define(2) },
      entry: { from: "check", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W5", name: "changed at decision → cancel the decide, back to define; fix rounds and findings unchanged",
    state: snapshotAt("decision", decision1, { fixRounds: 2, findings, seq: { define: 1, accept: 1, decision: 1 } }),
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, decision1), cmd(define(2))],
      state: { workItem: edited, fixRounds: 2, findings, awaiting: define(2) },
      entry: { from: "decision", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W5", name: "changed while blocked at check → define, blockedAt = null",
    state: { ...blockedAt("check"), blockedCmd: check1, seq: { define: 1, check: 1, blocked: 1 } },
    signal: edit,
    expect: {
      at: "define",
      commands: [cancel(1, blocked1), cmd(define(2))],
      state: { workItem: edited, blockedAt: null, blockedCmd: null, retries: 0, awaiting: define(2) },
      entry: { from: "blocked", to: "define", issued: [id("cancel-1"), id("define-2")] },
    },
  },
  {
    id: "W6", name: "changed at land → notify, flow unchanged",
    state: snapshotAt("land", land1),
    signal: edit,
    expect: {
      at: "land",
      commands: [fire("notify-1", "principal", "notify", LATE)],
      state: { workItem: edited, awaiting: land1 },
      entry: { from: "land", to: "land", issued: [id("notify-1")], note: "workitem_changed_late" },
    },
  },
  {
    id: "W6", name: "changed at teardown → notify, flow unchanged",
    state: snapshotAt("teardown", teardown1, { outcome: "delivered" }),
    signal: edit,
    expect: {
      at: "teardown",
      commands: [fire("notify-1", "principal", "notify", LATE)],
      state: { workItem: edited, awaiting: teardown1, outcome: "delivered" },
      entry: { from: "teardown", to: "teardown", issued: [id("notify-1")], note: "workitem_changed_late" },
    },
  },
  {
    id: "W6", name: "changed while blocked at deploy → notify, stay blocked",
    state: blockedAt("deploy"),
    signal: edit,
    expect: {
      at: "blocked",
      commands: [fire("notify-1", "principal", "notify", LATE)],
      state: { workItem: edited, blockedAt: "deploy", awaiting: blocked1 },
      entry: { from: "blocked", to: "blocked", issued: [id("notify-1")], note: "workitem_changed_late" },
    },
  },
];
