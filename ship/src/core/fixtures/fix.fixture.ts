// §4.3 fix-round and Decision-gate rows (policy fixRounds N = 2).
import type { Finding } from "../../contracts/common";
import {
  type TransitionRow, OPTIONS, answer, awaited, changeset, cmd, criteria, decide, fire, gateEvidence, id, ok,
  snapshotAt,
} from "./builders.fixture";

const findings: Finding[] = [{ text: "empty name is not rejected", ref: "greet.ts:3" }];
const { decision: DECISION, land: LAND } = OPTIONS;

const implementRun = (n: number, extra: Record<string, unknown> = {}) =>
  awaited(`implement-${n}`, "implement", "run", { criteria, findings, ...extra }, "implement", "run");
const check1 = awaited("check-1", "check", "run", { criteria, changeset }, "check", "run");
const integrate1 = awaited("integrate-1", "integrate", "run", { changeset }, "integrate", "run");
const decision1 = decide("decision", 1, DECISION, "person", gateEvidence({ findings }));
const land1 = decide("land", 1, LAND, "person", gateEvidence({ findings }));
const fix = { verdict: "fix", findings };

export const fixRows: TransitionRow[] = [
  {
    id: "F1", name: "check fix with rounds left → implement with the findings",
    state: snapshotAt("check", check1, { seq: { implement: 1, check: 1 } }),
    signal: ok(check1, fix),
    expect: {
      at: "implement",
      commands: [cmd(implementRun(2))],
      state: { fixRounds: 1, findings, awaiting: implementRun(2), lastRun: implementRun(2) },
      entry: { from: "check", to: "implement", issued: [id("implement-2")] },
    },
  },
  {
    id: "F1", name: "check fix on the last round left (1 < 2) → implement",
    state: snapshotAt("check", check1, { fixRounds: 1, seq: { implement: 2, check: 1 } }),
    signal: ok(check1, fix),
    expect: {
      at: "implement",
      commands: [cmd(implementRun(3))],
      state: { fixRounds: 2, findings },
      entry: { from: "check", to: "implement", issued: [id("implement-3")] },
    },
  },
  {
    id: "F2", name: "check fix with N rounds used → decision at decision.scope",
    state: snapshotAt("check", check1, { fixRounds: 2, retries: 1 }),
    signal: ok(check1, fix),
    expect: {
      at: "decision",
      commands: [cmd(decision1)],
      state: { fixRounds: 2, findings, retries: 0, awaiting: decision1 },
      entry: { from: "check", to: "decision", issued: [id("decision-1")] },
    },
  },
  {
    id: "F3", name: "check decide about scope → decision at decision.scope",
    state: snapshotAt("check", check1),
    signal: ok(check1, { verdict: "decide", about: "scope", findings }),
    expect: {
      at: "decision",
      commands: [cmd(decision1)],
      state: { fixRounds: 0, findings, awaiting: decision1 },
      entry: { from: "check", to: "decision", issued: [id("decision-1")] },
    },
  },
  {
    id: "F3", name: "check decide about advisory → decision at decision.advisory",
    state: snapshotAt("check", check1),
    signal: ok(check1, { verdict: "decide", about: "advisory", findings }),
    expect: {
      at: "decision",
      commands: [cmd(decide("decision", 1, DECISION, "model", gateEvidence({ findings })))],
      state: { findings },
      entry: { from: "check", to: "decision", issued: [id("decision-1")] },
    },
  },
  {
    id: "F4", name: "decision keep_going → implement, fix rounds reset",
    state: snapshotAt("decision", decision1, { fixRounds: 2, findings, seq: { implement: 3, decision: 1 } }),
    signal: answer(decision1, "keep_going"),
    expect: {
      at: "implement",
      commands: [cmd(implementRun(4))],
      state: { fixRounds: 0, findings, awaiting: implementRun(4) },
      entry: { from: "decision", to: "implement", issued: [id("implement-4")], by: "person" },
    },
  },
  {
    id: "F5", name: "decision accept → land gate",
    state: snapshotAt("decision", decision1, { fixRounds: 2, findings }),
    signal: answer(decision1, "accept", "model"),
    expect: {
      at: "land",
      commands: [cmd(land1)],
      state: { fixRounds: 2, awaiting: land1 },
      entry: { from: "decision", to: "land", issued: [id("land-1")], by: "model" },
    },
  },
  {
    id: "F6", name: "decision stop + comment → abandoned with the comment as reason, workspace kept",
    state: snapshotAt("decision", decision1, { findings }),
    signal: answer(decision1, "stop", "person", "not worth it"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: not worth it" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: not worth it" }),
      ],
      state: { outcome: "abandoned", reason: "not worth it", awaiting: null, workspace: "/ws/k-1" },
      entry: { from: "decision", to: "abandoned", issued: [id("comment-1"), id("notify-1")], by: "person" },
    },
  },
  {
    id: "F6", name: "decision stop without comment → default reason",
    state: snapshotAt("decision", decision1, { findings }),
    signal: answer(decision1, "stop"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: stopped at decision" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: stopped at decision" }),
      ],
      state: { outcome: "abandoned", reason: "stopped at decision", awaiting: null },
      entry: { from: "decision", to: "abandoned", issued: [id("comment-1"), id("notify-1")], by: "person" },
    },
  },
  {
    id: "F7", name: "land rework + comment → implement with findings and feedback, rounds unchanged",
    state: snapshotAt("land", land1, { fixRounds: 1, findings, seq: { implement: 2, land: 1 } }),
    signal: answer(land1, "rework", "person", "handle an empty name"),
    expect: {
      at: "implement",
      commands: [cmd(implementRun(3, { feedback: "handle an empty name" }))],
      state: { fixRounds: 1, awaiting: implementRun(3, { feedback: "handle an empty name" }) },
      entry: { from: "land", to: "implement", issued: [id("implement-3")], by: "person" },
    },
  },
  {
    id: "F8", name: "land rescope + comment → define with feedback, rounds unchanged",
    state: snapshotAt("land", land1, { fixRounds: 1, findings, seq: { define: 1, land: 1 } }),
    signal: answer(land1, "rescope", "person", "greet in German only"),
    expect: {
      at: "define",
      commands: [cmd(awaited("define-2", "define", "run", { feedback: "greet in German only" }, "define", "run"))],
      state: { fixRounds: 1 },
      entry: { from: "land", to: "define", issued: [id("define-2")], by: "person" },
    },
  },
  {
    id: "F9", name: "integrate fix with rounds left → implement, counted as a round",
    state: snapshotAt("integrate", integrate1, { seq: { implement: 1, integrate: 1 } }),
    signal: ok(integrate1, fix),
    expect: {
      at: "implement",
      commands: [cmd(implementRun(2))],
      state: { fixRounds: 1, findings },
      entry: { from: "integrate", to: "implement", issued: [id("implement-2")] },
    },
  },
  {
    id: "F10", name: "integrate fix with N rounds used → decision at decision.scope",
    state: snapshotAt("integrate", integrate1, { fixRounds: 2 }),
    signal: ok(integrate1, fix),
    expect: {
      at: "decision",
      commands: [cmd(decision1)],
      state: { fixRounds: 2, findings, awaiting: decision1 },
      entry: { from: "integrate", to: "decision", issued: [id("decision-1")] },
    },
  },
];
