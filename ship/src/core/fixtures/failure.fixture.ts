// §4.4 Failure-gate rows.
import type { Finding } from "../../contracts/common";
import {
  type TransitionRow, OPTIONS, answer, awaited, changeset, cmd, decide, fire, gateEvidence, id, ok,
  policy, requirements, snapshotAt, withTracker,
} from "./builders.fixture";

const findings: Finding[] = [{ text: "greeting page returns 500", ref: "https://example.test/runs/7" }];
const deploy1 = awaited("deploy-1", "deploy", "run", { changeset }, "deploy", "run");
const verify1 = awaited("verify-1", "verify", "run", { requirements }, "verify", "run");
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
      commands: [cmd(awaited("implement-3", "implement", "run", { requirements, findings }, "implement", "run"))],
      state: { fixRounds: 1, findings },
      entry: { from: "failure", to: "implement", issued: [id("implement-3")], by: "person" },
    },
  },
  {
    id: "X3", name: "failure fix_forward + comment → implement with the findings and feedback, rounds unchanged",
    state: snapshotAt("failure", failure(), { findings, fixRounds: 1, seq: { implement: 2, failure: 1 } }),
    signal: answer(failure(), "fix_forward", "person", "return 503, not 500, while the store warms up"),
    expect: {
      at: "implement",
      commands: [cmd(awaited("implement-3", "implement", "run",
        { requirements, findings, feedback: "return 503, not 500, while the store warms up" }, "implement", "run"))],
      state: { fixRounds: 1, findings },
      entry: { from: "failure", to: "implement", issued: [id("implement-3")], by: "person" },
    },
  },
  {
    id: "X3", name: "failure fix_forward + comment with no findings → implement with [] findings and feedback",
    state: snapshotAt("failure", failure(gateEvidence()), { findings: [], fixRounds: 0, seq: { implement: 1, failure: 1 } }),
    signal: answer(failure(gateEvidence()), "fix_forward", "person", "add the missing env var"),
    expect: {
      at: "implement",
      commands: [cmd(awaited("implement-2", "implement", "run",
        { requirements, findings: [], feedback: "add the missing env var" }, "implement", "run"))],
      state: { fixRounds: 0, findings: [] },
      entry: { from: "failure", to: "implement", issued: [id("implement-2")], by: "person" },
    },
  },
  {
    id: "X4", name: "failure accept → close with accepted_with_failure, plus its comment",
    state: snapshotAt("failure", failure(), { findings }),
    signal: answer(failure(), "accept"),
    expect: {
      at: "close",
      commands: [cmd(close1), fire("comment-1", "tracker", "comment", { text: "accepted_with_failure" })],
      state: { outcome: "accepted_with_failure", reason: null, awaiting: close1, lastRun: close1 },
      entry: { from: "failure", to: "close", issued: [close1.id, id("comment-1")], by: "person" },
    },
  },
  {
    id: "X4", name: "failure accept + comment → close with the comment as reason, in the tracker comment",
    state: snapshotAt("failure", failure(), { findings }),
    signal: answer(failure(), "accept", "person", "known flake, tracked in OPS-12"),
    expect: {
      at: "close",
      commands: [cmd(close1), fire("comment-1", "tracker", "comment", { text: "accepted_with_failure: known flake, tracked in OPS-12" })],
      state: { outcome: "accepted_with_failure", reason: "known flake, tracked in OPS-12", awaiting: close1 },
      entry: { from: "failure", to: "close", issued: [close1.id, id("comment-1")], by: "person" },
    },
  },
  {
    id: "X4", name: "failure accept + comment with the outcome comment off → reason still set, no tracker comment",
    policy: withTracker({ outcomes: { ...policy.tracker.outcomes, accepted_with_failure: { status: "done" } } }),
    state: snapshotAt("failure", failure(), { findings }),
    signal: answer(failure(), "accept", "person", "known flake"),
    expect: {
      at: "close",
      commands: [cmd(close1)],
      state: { outcome: "accepted_with_failure", reason: "known flake", awaiting: close1 },
      entry: { from: "failure", to: "close", issued: [close1.id], by: "person" },
    },
  },
];
