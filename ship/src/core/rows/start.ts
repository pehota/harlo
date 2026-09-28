// §4.1 start rows.
import type { DeliveryId } from "../../contracts/common";
import type { Awaiting, Position, Snapshot } from "../types";
import { type StartRow, cmd, snapshotAt, workItem } from "./fixtures";

const existing = (delivery: DeliveryId, at: Position, key = workItem.key, over: Partial<Snapshot> = {}): Snapshot =>
  snapshotAt(at, null, { delivery, workItem: { ...workItem, key }, ...over });

const setup1 = (delivery: DeliveryId): Awaiting => ({
  id: `${delivery}/setup-1`, port: "workspace", op: "setup", await: true, payload: {}, node: "setup", kind: "run",
});
const setupCmd = (delivery: DeliveryId) => cmd(setup1(delivery));

export const startRows: StartRow[] = [
  {
    id: "S1", name: "no Delivery yet: create k-1 at setup",
    workItem, existing: [],
    expect: {
      kind: "created", delivery: "k-1",
      commands: [setupCmd("k-1")],
      state: {
        v: 1, delivery: "k-1", workItem, at: "setup",
        blockedAt: null, awaiting: setup1("k-1"), lastRun: setup1("k-1"), blockedCmd: null,
        seq: { setup: 1 }, retries: 0, fixRounds: 0,
        workspace: null, criteria: null, runbook: null, changeset: null,
        findings: [], evidence: [], outcome: null, reason: null,
      },
      entry: { from: null, to: "setup", issued: ["k-1/setup-1"] },
    },
  },
  {
    id: "S2", name: "k-1 closed: create k-2",
    workItem, existing: [existing("k-1", "closed")],
    expect: {
      kind: "created", delivery: "k-2",
      commands: [setupCmd("k-2")],
      state: { delivery: "k-2", at: "setup", awaiting: setup1("k-2"), seq: { setup: 1 } },
      entry: { from: null, to: "setup", issued: ["k-2/setup-1"] },
    },
  },
  {
    id: "S3", name: "k-1 abandoned, k-2 closed: create k-3",
    workItem, existing: [existing("k-1", "abandoned"), existing("k-2", "closed")],
    expect: {
      kind: "created", delivery: "k-3",
      commands: [setupCmd("k-3")],
      state: { delivery: "k-3", at: "setup", awaiting: setup1("k-3") },
      entry: { from: null, to: "setup", issued: ["k-3/setup-1"] },
    },
  },
  {
    id: "S4", name: "k-1 at implement: rejected on k-1",
    workItem, existing: [existing("k-1", "implement")],
    expect: {
      kind: "rejected", delivery: "k-1", commands: [],
      entry: { from: "implement", to: "implement", issued: [], note: "rejected_start" },
    },
  },
  {
    id: "S5", name: "k-1 blocked: rejected on k-1",
    workItem, existing: [existing("k-1", "blocked", workItem.key, { blockedAt: "deploy" })],
    expect: {
      kind: "rejected", delivery: "k-1", commands: [],
      entry: { from: "blocked", to: "blocked", issued: [], note: "rejected_start" },
    },
  },
  {
    id: "S6", name: "another key sharing the prefix (k-12-1 for key k-1) is not counted",
    workItem: { ...workItem, key: "k-1" },
    existing: [existing("k-1-1", "closed", "k-1"), existing("k-12-1", "implement", "k-12"), existing("k-12-2", "closed", "k-12")],
    expect: {
      kind: "created", delivery: "k-1-2",
      commands: [setupCmd("k-1-2")],
      state: { delivery: "k-1-2", workItem: { ...workItem, key: "k-1" }, at: "setup" },
      entry: { from: null, to: "setup", issued: ["k-1-2/setup-1"] },
    },
  },
];
