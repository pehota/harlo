// §4.2 happy-path rows.
import type { EvidenceItem } from "../../contracts/common";
import {
  type TransitionRow, answer, awaited, changeset, cmd, criteria, decide, fire, gateEvidence, id, ok, policy,
  OPTIONS, runbook, snapshotAt, withTracker, workspace,
} from "./builders.fixture";

const plan: EvidenceItem = { label: "plan", url: "file:///ws/k-1/plan.md" };
const { accept: ACCEPT, land: LAND } = OPTIONS;

const setup1 = awaited("setup-1", "workspace", "setup", {}, "setup", "run");
const define1 = awaited("define-1", "define", "run", {}, "define", "run");
const accept1 = decide("accept", 1, ACCEPT, "person");
const implement1 = awaited("implement-1", "implement", "run", { criteria, findings: [] }, "implement", "run");
const check1 = awaited("check-1", "check", "run", { criteria, changeset }, "check", "run");
const land1 = decide("land", 1, LAND, "person");
const integrate1 = awaited("integrate-1", "integrate", "run", { changeset }, "integrate", "run");
const deploy1 = awaited("deploy-1", "deploy", "run", { changeset }, "deploy", "run");
const verify1 = awaited("verify-1", "verify", "run", { runbook }, "verify", "run");
const close1 = awaited("close-1", "tracker", "update", { status: "done" }, "close", "run");
const teardown1 = awaited("teardown-1", "workspace", "teardown", { path: workspace }, "teardown", "run");

export const happyRows: TransitionRow[] = [
  {
    id: "H1", name: "setup ok → define",
    state: snapshotAt("setup", setup1, { workspace: null, criteria: null, runbook: null, changeset: null }),
    signal: ok(setup1, { path: workspace }),
    expect: {
      at: "define",
      commands: [cmd(define1)],
      state: { workspace, awaiting: define1, lastRun: define1, seq: { setup: 1, define: 1 } },
      entry: { from: "setup", to: "define", issued: [define1.id] },
    },
  },
  {
    id: "H2", name: "define ok → accept gate, criteria and runbook set, evidence appended",
    state: snapshotAt("define", define1, { criteria: null, runbook: null, changeset: null, retries: 1 }),
    signal: ok(define1, { criteria, runbook }, [plan]),
    expect: {
      at: "accept",
      commands: [cmd(decide("accept", 1, ACCEPT, "person", gateEvidence({ changeset: null, evidence: [plan] })))],
      state: {
        criteria, runbook, evidence: [plan], retries: 0, lastRun: define1,
        awaiting: decide("accept", 1, ACCEPT, "person", gateEvidence({ changeset: null, evidence: [plan] })),
      },
      entry: { from: "define", to: "accept", issued: [id("accept-1")] },
    },
  },
  {
    id: "H3", name: "accept → implement",
    state: snapshotAt("accept", accept1),
    signal: answer(accept1, "accept"),
    expect: {
      at: "implement",
      commands: [cmd(implement1)],
      state: { awaiting: implement1, lastRun: implement1 },
      entry: { from: "accept", to: "implement", issued: [implement1.id], by: "person" },
    },
  },
  {
    id: "H3a", name: "accept → implement fires the configured tracker status",
    policy: withTracker({ steps: { implement: "in_progress" } }),
    state: snapshotAt("accept", accept1),
    signal: answer(accept1, "accept"),
    expect: {
      at: "implement",
      commands: [cmd(implement1), fire("update-1", "tracker", "update", { status: "in_progress" })],
      state: { awaiting: implement1, seq: { accept: 1, implement: 1, update: 1 } },
      entry: { from: "accept", to: "implement", issued: [implement1.id, id("update-1")], by: "person" },
    },
  },
  {
    id: "H3b", name: "accept → implement with no status for implement fires nothing",
    policy: withTracker({ steps: { check: "in_review" } }),
    state: snapshotAt("accept", accept1),
    signal: answer(accept1, "accept", "model"),
    expect: {
      at: "implement",
      commands: [cmd(implement1)],
      state: { awaiting: implement1, seq: { accept: 1, implement: 1 } },
      entry: { from: "accept", to: "implement", issued: [implement1.id], by: "model" },
    },
  },
  {
    id: "H4", name: "adjust + comment → define with feedback",
    state: snapshotAt("accept", accept1, { seq: { setup: 1, define: 1, accept: 1 } }),
    signal: answer(accept1, "adjust", "person", "also greet in German"),
    expect: {
      at: "define",
      commands: [cmd(awaited("define-2", "define", "run", { feedback: "also greet in German" }, "define", "run"))],
      state: {
        awaiting: awaited("define-2", "define", "run", { feedback: "also greet in German" }, "define", "run"),
        seq: { setup: 1, define: 2, accept: 1 },
      },
      entry: { from: "accept", to: "define", issued: [id("define-2")], by: "person" },
    },
  },
  {
    id: "H5", name: "implement ok → check, changeset set",
    state: snapshotAt("implement", implement1, { changeset: null }),
    signal: ok(implement1, { changeset: "cs-2" }),
    expect: {
      at: "check",
      commands: [cmd(awaited("check-1", "check", "run", { criteria, changeset: "cs-2" }, "check", "run"))],
      state: { changeset: "cs-2" },
      entry: { from: "implement", to: "check", issued: [id("check-1")] },
    },
  },
  {
    id: "H6", name: "check pass → land gate, findings cleared",
    state: snapshotAt("check", check1, { findings: [{ text: "name is not trimmed" }] }),
    signal: ok(check1, { verdict: "pass" }),
    expect: {
      at: "land",
      commands: [cmd(decide("land", 1, LAND, "person"))],
      state: { findings: [], awaiting: decide("land", 1, LAND, "person") },
      entry: { from: "check", to: "land", issued: [id("land-1")] },
    },
  },
  {
    id: "H7", name: "land approve → integrate",
    state: snapshotAt("land", land1),
    signal: answer(land1, "approve"),
    expect: {
      at: "integrate",
      commands: [cmd(integrate1)],
      state: { awaiting: integrate1, lastRun: integrate1 },
      entry: { from: "land", to: "integrate", issued: [integrate1.id], by: "person" },
    },
  },
  {
    id: "H8", name: "integrate landed → deploy",
    state: snapshotAt("integrate", integrate1),
    signal: ok(integrate1, { verdict: "landed" }),
    expect: {
      at: "deploy",
      commands: [cmd(deploy1)],
      state: { awaiting: deploy1, lastRun: deploy1 },
      entry: { from: "integrate", to: "deploy", issued: [deploy1.id] },
    },
  },
  {
    id: "H9", name: "deploy live → verify",
    state: snapshotAt("deploy", deploy1),
    signal: ok(deploy1, { verdict: "live" }),
    expect: {
      at: "verify",
      commands: [cmd(verify1)],
      state: { awaiting: verify1, lastRun: verify1 },
      entry: { from: "deploy", to: "verify", issued: [verify1.id] },
    },
  },
  {
    id: "H10", name: "verify pass → close: awaited tracker.update with the delivered status",
    state: snapshotAt("verify", verify1),
    signal: ok(verify1, { verdict: "pass" }),
    expect: {
      at: "close",
      commands: [cmd(close1)],
      state: { outcome: "delivered", awaiting: close1, lastRun: close1 },
      entry: { from: "verify", to: "close", issued: [close1.id] },
    },
  },
  {
    id: "H10c", name: "verify pass → close also fires tracker.comment when delivered has comment",
    policy: withTracker({ outcomes: { ...policy.tracker.outcomes, delivered: { status: "done", comment: true } } }),
    state: snapshotAt("verify", verify1),
    signal: ok(verify1, { verdict: "pass" }),
    expect: {
      at: "close",
      commands: [cmd(close1), fire("comment-1", "tracker", "comment", { text: "delivered" })],
      state: { outcome: "delivered", awaiting: close1 },
      entry: { from: "verify", to: "close", issued: [close1.id, id("comment-1")] },
    },
  },
  {
    id: "H11", name: "close ok → teardown the workspace",
    state: snapshotAt("close", close1, { outcome: "delivered" }),
    signal: ok(close1, {}),
    expect: {
      at: "teardown",
      commands: [cmd(teardown1)],
      state: { outcome: "delivered", awaiting: teardown1, lastRun: teardown1 },
      entry: { from: "close", to: "teardown", issued: [teardown1.id] },
    },
  },
  {
    id: "H12", name: "teardown ok → closed, notify the Principal",
    state: snapshotAt("teardown", teardown1, { outcome: "delivered" }),
    signal: ok(teardown1, {}),
    expect: {
      at: "closed",
      commands: [fire("notify-1", "principal", "notify", { text: "closed: delivered" })],
      state: { outcome: "delivered", awaiting: null },
      entry: { from: "teardown", to: "closed", issued: [id("notify-1")] },
    },
  },
];
