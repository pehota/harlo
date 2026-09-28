// §4.4 Failure-gate rows.
import type { Finding } from "../../contracts/common";
import {
  type TransitionRow, OPTIONS, answer, awaited, changeset, cmd, criteria, decide, fire, gateEvidence, id, ok,
  runbook, snapshotAt,
} from "./builders.fixture";

const findings: Finding[] = [{ text: "greeting page returns 500", ref: "https://example.test/runs/7" }];
const deploy1 = awaited("deploy-1", "deploy", "run", { changeset }, "deploy", "run");
const verify1 = awaited("verify-1", "verify", "run", { runbook }, "verify", "run");
const failure = (evidence = gateEvidence({ findings })) => decide("failure", 1, OPTIONS.failure, "person", evidence);
const close1 = awaited("close-1", "tracker", "update", { status: "done" }, "close", "run");

export const failureRows: TransitionRow[] = [
  {
    id: "X1", name: "deploy not_live with findings → failure gate",
    state: snapshotAt("deploy", deploy1, { retries: 1 }),
    signal: ok(deploy1, { verdict: "not_live", findings }),
    expect: {
      at: "failure",
      commands: [cmd(failure())],
      state: { findings, retries: 0, awaiting: failure() },
      entry: { from: "deploy", to: "failure", issued: [id("failure-1")] },
    },
  },
  {
    id: "X1", name: "deploy not_live without findings → failure gate, findings cleared",
    state: snapshotAt("deploy", deploy1, { findings: [{ text: "an earlier check finding" }] }),
    signal: ok(deploy1, { verdict: "not_live" }),
    expect: {
      at: "failure",
      commands: [cmd(failure(gateEvidence()))],
      state: { findings: [] },
      entry: { from: "deploy", to: "failure", issued: [id("failure-1")] },
    },
  },
  {
    id: "X2", name: "verify fail → failure gate",
    state: snapshotAt("verify", verify1),
    signal: ok(verify1, { verdict: "fail", findings }),
    expect: {
      at: "failure",
      commands: [cmd(failure())],
      state: { findings, awaiting: failure() },
      entry: { from: "verify", to: "failure", issued: [id("failure-1")] },
    },
  },
  {
    id: "X3", name: "failure fix_forward → implement with the findings, rounds unchanged",
    state: snapshotAt("failure", failure(), { findings, fixRounds: 1, seq: { implement: 2, failure: 1 } }),
    signal: answer(failure(), "fix_forward"),
    expect: {
      at: "implement",
      commands: [cmd(awaited("implement-3", "implement", "run", { criteria, findings }, "implement", "run"))],
      state: { fixRounds: 1, findings },
      entry: { from: "failure", to: "implement", issued: [id("implement-3")], by: "person" },
    },
  },
  {
    id: "X4", name: "failure accept → close with accepted_with_failure, plus its comment",
    state: snapshotAt("failure", failure(), { findings }),
    signal: answer(failure(), "accept"),
    expect: {
      at: "close",
      commands: [cmd(close1), fire("comment-1", "tracker", "comment", { text: "accepted_with_failure" })],
      state: { outcome: "accepted_with_failure", awaiting: close1, lastRun: close1 },
      entry: { from: "failure", to: "close", issued: [close1.id, id("comment-1")], by: "person" },
    },
  },
];
