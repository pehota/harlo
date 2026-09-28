// §4.6 retry and Blocked rows. Fixture policy: retryCap.default C = 1.
import {
  type TransitionRow, OPTIONS, answer, ask, awaited, changeset, cmd, decide, failed, fire, gateEvidence, id,
  runbook, snapshotAt, withRetryCap,
} from "./fixtures";

const LOGIN = ["logged in", "give up"];
const deploy = (n: number) => awaited(`deploy-${n}`, "deploy", "run", { changeset }, "deploy", "run");
const verify1 = awaited("verify-1", "verify", "run", { runbook }, "verify", "run");
const land = (n: number) => ({ ...decide("land", 1, OPTIONS.land, "person"), id: id(`land-${n}`) });
const login = (n: number) => ({ ...ask(1, "verify", "login", "Log in, then answer", "person", LOGIN), id: id(`ask-${n}`) });
const blocked = (n: number) => ({ ...decide("blocked", 1, OPTIONS.blocked, "person", gateEvidence()), id: id(`blocked-${n}`) });

/** Blocked at `node` on `cmd`, awaiting the n-th blocked decide. */
const blockedOn = (node: "deploy" | "verify", failedCmd = deploy(1), n = 1) =>
  snapshotAt("blocked", blocked(n), {
    blockedAt: node, blockedCmd: failedCmd, lastRun: node === "deploy" ? deploy(1) : verify1, retries: 1,
    seq: { [node]: 1, blocked: n, ...(failedCmd.kind === "ask" ? { ask: 1 } : {}) },
  });

export const blockedRows: TransitionRow[] = [
  {
    id: "B1", name: "step failed with retries left → re-issue with a new id",
    state: snapshotAt("deploy", deploy(1)),
    signal: failed(deploy(1), "registry unreachable"),
    expect: {
      at: "deploy",
      commands: [cmd(deploy(2))],
      state: { retries: 1, awaiting: deploy(2), lastRun: deploy(2) },
      entry: { from: "deploy", to: "deploy", issued: [id("deploy-2")] },
    },
  },
  {
    id: "B1", name: "gate decide failed with retries left → re-issue the decide",
    state: snapshotAt("land", land(1)),
    signal: failed(land(1), "principal channel down"),
    expect: {
      at: "land",
      commands: [cmd(land(2))],
      state: { retries: 1, awaiting: land(2) },
      entry: { from: "land", to: "land", issued: [id("land-2")] },
    },
  },
  {
    id: "B1", name: "ask failed → re-asked under the asking step's cap (verify 1, default 0)",
    policy: withRetryCap({ default: 0, verify: 1 }),
    state: snapshotAt("verify", login(1), { lastRun: verify1, seq: { verify: 1, ask: 1 } }),
    signal: failed(login(1), "principal channel down"),
    expect: {
      at: "verify",
      commands: [cmd(login(2))],
      state: { retries: 1, awaiting: login(2), lastRun: verify1 },
      entry: { from: "verify", to: "verify", issued: [id("ask-2")] },
    },
  },
  {
    id: "B2", name: "step failed at the cap → blocked, decide retry|stop",
    state: snapshotAt("deploy", deploy(1), { retries: 1 }),
    signal: failed(deploy(1), "registry unreachable"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(1))],
      state: { blockedAt: "deploy", blockedCmd: deploy(1), lastRun: deploy(1), awaiting: blocked(1) },
      entry: { from: "deploy", to: "blocked", issued: [id("blocked-1")] },
    },
  },
  {
    id: "B2", name: "cap 0: the first failed goes straight to blocked",
    policy: withRetryCap({ default: 1, deploy: 0 }),
    state: snapshotAt("deploy", deploy(1)),
    signal: failed(deploy(1), "registry unreachable"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(1))],
      state: { blockedAt: "deploy", blockedCmd: deploy(1), awaiting: blocked(1) },
      entry: { from: "deploy", to: "blocked", issued: [id("blocked-1")] },
    },
  },
  {
    id: "B2", name: "ask failed at the asking step's cap → blocked at that step, lastRun kept",
    state: snapshotAt("verify", login(1), { lastRun: verify1, retries: 1, seq: { verify: 1, ask: 1 } }),
    signal: failed(login(1), "principal channel down"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(1))],
      state: { blockedAt: "verify", blockedCmd: login(1), lastRun: verify1, awaiting: blocked(1) },
      entry: { from: "verify", to: "blocked", issued: [id("blocked-1")] },
    },
  },
  {
    id: "B2", name: "gate failed at the cap → blocked at the gate",
    state: snapshotAt("land", land(1), { retries: 1 }),
    signal: failed(land(1), "principal channel down"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(1))],
      state: { blockedAt: "land", blockedCmd: land(1), awaiting: blocked(1) },
      entry: { from: "land", to: "blocked", issued: [id("blocked-1")] },
    },
  },
  {
    id: "B3", name: "blocked retry → re-issue the failed step command, blocked cleared",
    state: blockedOn("deploy"),
    signal: answer(blocked(1), "retry"),
    expect: {
      at: "deploy",
      commands: [cmd(deploy(2))],
      state: { retries: 0, blockedAt: null, blockedCmd: null, awaiting: deploy(2), lastRun: deploy(2) },
      entry: { from: "blocked", to: "deploy", issued: [id("deploy-2")], by: "person" },
    },
  },
  {
    id: "B3", name: "blocked retry of a failed ask → re-ask at the step, lastRun kept",
    state: blockedOn("verify", login(1)),
    signal: answer(blocked(1), "retry", "model"),
    expect: {
      at: "verify",
      commands: [cmd(login(2))],
      state: { retries: 0, blockedAt: null, blockedCmd: null, awaiting: login(2), lastRun: verify1 },
      entry: { from: "blocked", to: "verify", issued: [id("ask-2")], by: "model" },
    },
  },
  {
    id: "B4", name: "blocked stop + comment → abandoned with the comment as reason",
    state: blockedOn("deploy"),
    signal: answer(blocked(1), "stop", "person", "registry retired"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: registry retired" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: registry retired" }),
      ],
      state: { outcome: "abandoned", reason: "registry retired", awaiting: null, blockedAt: null, blockedCmd: null },
      entry: { from: "blocked", to: "abandoned", issued: [id("comment-1"), id("notify-1")], by: "person" },
    },
  },
  {
    id: "B4", name: "blocked stop without comment → default reason names the node",
    state: blockedOn("deploy"),
    signal: answer(blocked(1), "stop"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: stopped at blocked deploy" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: stopped at blocked deploy" }),
      ],
      state: { outcome: "abandoned", reason: "stopped at blocked deploy" },
      entry: { from: "blocked", to: "abandoned", issued: [id("comment-1"), id("notify-1")], by: "person" },
    },
  },
  {
    id: "B5", name: "blocked answer outside [retry, stop] → re-issue the decide, invalid_answer",
    state: blockedOn("deploy"),
    signal: answer(blocked(1), "later"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(2))],
      state: { blockedAt: "deploy", blockedCmd: deploy(1), retries: 1, awaiting: blocked(2) },
      entry: { from: "blocked", to: "blocked", issued: [id("blocked-2")], by: "person", note: "invalid_answer" },
    },
  },
  {
    id: "B6", name: "blocked decide failed → stay blocked awaiting nothing",
    state: blockedOn("deploy"),
    signal: failed(blocked(1), "principal channel down"),
    expect: {
      at: "blocked",
      commands: [],
      state: { blockedAt: "deploy", blockedCmd: deploy(1), awaiting: null },
      entry: { from: "blocked", to: "blocked", issued: [] },
    },
  },
  {
    id: "B7", name: "gate answer outside its options → re-issue the decide, retries unchanged",
    state: snapshotAt("land", land(1), { retries: 1 }),
    signal: answer(land(1), "ship it"),
    expect: {
      at: "land",
      commands: [cmd(land(2))],
      state: { retries: 1, awaiting: land(2) },
      entry: { from: "land", to: "land", issued: [id("land-2")], by: "person", note: "invalid_answer" },
    },
  },
];
