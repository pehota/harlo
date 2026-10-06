// §4.6 retry and Blocked rows. Fixture policy: retryCap.default C = 1.
import type { Signal, Snapshot } from "../types";
import {
  type TransitionRow, OPTIONS, answer, ask, awaited, changeset, cmd, decide, failed, fire, gateEvidence, id,
  ok, runbook, snapshotAt, withMaxBlockedRetries, withRetryCap,
} from "./builders.fixture";

const LOGIN = ["logged in", "give up"];
const deploy = (n: number) => awaited(`deploy-${n}`, "deploy", "run", { changeset }, "deploy", "run");
const verify1 = awaited("verify-1", "verify", "run", { runbook }, "verify", "run");
const land = (n: number) => ({ ...decide("land", 1, OPTIONS.land, "person"), id: id(`land-${n}`) });
const login = (n: number) => ({ ...ask(1, "verify", "login", "Log in, then answer", "person", LOGIN), id: id(`ask-${n}`) });
const blocked = (n: number, note?: string) =>
  ({ ...decide("blocked", 1, OPTIONS.blocked, "person", gateEvidence(note ? { note } : {})), id: id(`blocked-${n}`) });

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
    id: "B2", name: "step failed at the cap → blocked, decide retry|stop, blockedCount starts at 1",
    state: snapshotAt("deploy", deploy(1), { retries: 1 }),
    signal: failed(deploy(1), "registry unreachable"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(1))],
      state: { blockedAt: "deploy", blockedCmd: deploy(1), lastRun: deploy(1), awaiting: blocked(1), blockedCount: 1 },
      entry: { from: "deploy", to: "blocked", issued: [id("blocked-1")] },
    },
  },
  {
    id: "B2", name: "a node blocked a second time in a row → blockedCount 2, Principal sees a retry-attempt note",
    state: snapshotAt("deploy", deploy(2), { retries: 1, blockedCount: 1, seq: { deploy: 2, blocked: 1 } }),
    signal: failed(deploy(2), "registry unreachable"),
    expect: {
      at: "blocked",
      commands: [cmd(blocked(2, "This is retry attempt 2 at this gate."))],
      state: { blockedAt: "deploy", blockedCmd: deploy(2), blockedCount: 2 },
      entry: { from: "deploy", to: "blocked", issued: [id("blocked-2")] },
    },
  },
  {
    id: "B2", name: "blockedCount past maxBlockedRetries → auto-abandon, the Principal is never asked again",
    policy: withMaxBlockedRetries(2),
    state: snapshotAt("deploy", deploy(3), { retries: 1, blockedCount: 2 }),
    signal: failed(deploy(3), "registry unreachable"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: deploy blocked 3 times in a row (maxBlockedRetries 2)" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: deploy blocked 3 times in a row (maxBlockedRetries 2)" }),
      ],
      state: { outcome: "abandoned", reason: "deploy blocked 3 times in a row (maxBlockedRetries 2)", blockedAt: null, blockedCmd: null, awaiting: null },
      entry: { from: "deploy", to: "abandoned", issued: [id("comment-1"), id("notify-1")] },
    },
  },
  {
    id: "B2", name: "a node succeeds after a prior blocked cycle → blockedCount resets to 0 entering the next step",
    state: snapshotAt("deploy", deploy(2), { blockedCount: 2 }),
    signal: ok(deploy(2), { verdict: "live" }),
    expect: {
      at: "verify",
      commands: [cmd(verify1)],
      state: { blockedCount: 0 },
      entry: { from: "deploy", to: "verify", issued: [id("verify-1")] },
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
    id: "B3", name: "blocked retry does NOT reset blockedCount — it must keep counting toward the cap",
    state: { ...blockedOn("deploy"), blockedCount: 1 },
    signal: answer(blocked(1), "retry"),
    expect: {
      at: "deploy",
      commands: [cmd(deploy(2))],
      state: { retries: 0, blockedAt: null, blockedCmd: null, blockedCount: 1 },
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

const recover = (action: "retry" | "stop", comment?: string): Signal => ({
  kind: "blocked_recovery", action, ...(comment === undefined ? {} : { comment }),
});

/** Blocked after its own decide failed: awaiting nothing (B6). */
const stranded = (): Snapshot => ({ ...blockedOn("deploy"), awaiting: null });

export const recoveryRows: TransitionRow[] = [
  {
    id: "B8", name: "stranded blocked + recovery retry → re-issue the failed step, blocked cleared",
    state: stranded(),
    signal: recover("retry"),
    expect: {
      at: "deploy",
      commands: [cmd(deploy(2))],
      state: { retries: 0, blockedAt: null, blockedCmd: null, awaiting: deploy(2), lastRun: deploy(2) },
      entry: { from: "blocked", to: "deploy", issued: [id("deploy-2")] },
    },
  },
  {
    id: "B8", name: "stranded blocked + recovery stop + comment → abandoned with the comment",
    state: stranded(),
    signal: recover("stop", "registry retired"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: registry retired" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: registry retired" }),
      ],
      state: { outcome: "abandoned", reason: "registry retired", awaiting: null, blockedAt: null, blockedCmd: null },
      entry: { from: "blocked", to: "abandoned", issued: [id("comment-1"), id("notify-1")] },
    },
  },
  {
    id: "B8", name: "recovery stop without comment → default reason names the node",
    state: stranded(),
    signal: recover("stop"),
    expect: {
      at: "abandoned",
      commands: [
        fire("comment-1", "tracker", "comment", { text: "abandoned: stopped at blocked deploy" }),
        fire("notify-1", "principal", "notify", { text: "abandoned: abandoned: stopped at blocked deploy" }),
      ],
      state: { outcome: "abandoned", reason: "stopped at blocked deploy" },
      entry: { from: "blocked", to: "abandoned", issued: [id("comment-1"), id("notify-1")] },
    },
  },
  {
    id: "B8", name: "recovery retry while the blocked decide is still awaited → cancel it, then re-issue",
    state: blockedOn("deploy"),
    signal: recover("retry"),
    expect: {
      at: "deploy",
      commands: [fire("cancel-1", "principal", "cancel", { target: id("blocked-1") }), cmd(deploy(2))],
      state: { retries: 0, blockedAt: null, blockedCmd: null, awaiting: deploy(2) },
      entry: { from: "blocked", to: "deploy", issued: [id("cancel-1"), id("deploy-2")] },
    },
  },
];
