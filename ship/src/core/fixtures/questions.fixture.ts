// §4.5 question rows (step ports only). Fixture policy maps question about `clarify` to model; others → person.
import type { EvidenceItem, Finding } from "../../contracts/common";
import {
  type TransitionRow, OPTIONS, answer, ask, awaited, changeset, cmd, criteria, gateEvidence, id, question,
  runbook, snapshotAt,
} from "./builders.fixture";

const early = { criteria: null, runbook: null, changeset: null }; // Define has not produced anything yet
const shot: EvidenceItem = { label: "login page", url: "file:///ws/k-1/login.png" };
const findings: Finding[] = [{ text: "an earlier check finding" }];
const LOGIN = ["logged in", "give up"];

const define1 = awaited("define-1", "define", "run", {}, "define", "run");
const verify1 = awaited("verify-1", "verify", "run", { runbook }, "verify", "run");
const check1 = awaited("check-1", "check", "run", { criteria, changeset }, "check", "run");
const integrate1 = awaited("integrate-1", "integrate", "run", { changeset }, "integrate", "run");

const clarify1 = ask(1, "define", "clarify", "Greet by first or full name?", "model", undefined,
  gateEvidence({ ...early }));
const login1 = ask(1, "verify", "login", "Log in to the staging app, then answer", "person", LOGIN,
  gateEvidence({ evidence: [shot] }));
const conflict1 = ask(1, "integrate", "conflict", "greet.ts conflicts with the main line", "person", OPTIONS.conflict);

export const questionRows: TransitionRow[] = [
  {
    id: "Q1", name: "define question → ask at the about's minimum, lastRun is the define command",
    state: snapshotAt("define", define1, { ...early, retries: 1 }),
    signal: question(define1, "Greet by first or full name?", "clarify"),
    expect: {
      at: "define",
      commands: [cmd(clarify1)],
      state: { awaiting: clarify1, lastRun: define1, retries: 0, seq: { define: 1, ask: 1 } },
      entry: { from: "define", to: "define", issued: [id("ask-1")] },
    },
  },
  {
    id: "Q1", name: "verify question with options and evidence → ask carries both; unknown about → person",
    state: snapshotAt("verify", verify1),
    signal: question(verify1, "Log in to the staging app, then answer", "login", LOGIN, [shot]),
    expect: {
      at: "verify",
      commands: [cmd(login1)],
      state: { awaiting: login1, lastRun: verify1, evidence: [shot] },
      entry: { from: "verify", to: "verify", issued: [id("ask-1")] },
    },
  },
  {
    id: "Q1", name: "an about named like an object property is still unknown → person",
    state: snapshotAt("check", check1),
    signal: question(check1, "Which locale?", "toString"),
    expect: {
      at: "check",
      commands: [cmd(ask(1, "check", "toString", "Which locale?", "person"))],
      state: { awaiting: ask(1, "check", "toString", "Which locale?", "person"), lastRun: check1 },
      entry: { from: "check", to: "check", issued: [id("ask-1")] },
    },
  },
  {
    id: "Q2", name: "integrate conflict → ask with options forced to [resolved, rework]",
    state: snapshotAt("integrate", integrate1),
    signal: question(integrate1, "greet.ts conflicts with the main line", "conflict", ["merge", "skip"]),
    expect: {
      at: "integrate",
      commands: [cmd(conflict1)],
      state: { awaiting: conflict1, lastRun: integrate1 },
      entry: { from: "integrate", to: "integrate", issued: [id("ask-1")] },
    },
  },
  {
    id: "Q3", name: "answer to an ask without options → re-issue define with the answer",
    state: snapshotAt("define", clarify1, { ...early, lastRun: define1, retries: 1, seq: { define: 1, ask: 1 } }),
    signal: answer(clarify1, "full name", "model"),
    expect: {
      at: "define",
      commands: [cmd(awaited("define-2", "define", "run", { answer: "full name" }, "define", "run"))],
      state: {
        retries: 0,
        awaiting: awaited("define-2", "define", "run", { answer: "full name" }, "define", "run"),
        lastRun: awaited("define-2", "define", "run", { answer: "full name" }, "define", "run"),
      },
      entry: { from: "define", to: "define", issued: [id("define-2")], by: "model" },
    },
  },
  {
    id: "Q3", name: "answer within the ask's options → re-issue verify with the answer",
    state: snapshotAt("verify", login1, { lastRun: verify1, seq: { verify: 1, ask: 1 } }),
    signal: answer(login1, "logged in"),
    expect: {
      at: "verify",
      commands: [cmd(awaited("verify-2", "verify", "run", { runbook, answer: "logged in" }, "verify", "run"))],
      state: { retries: 0 },
      entry: { from: "verify", to: "verify", issued: [id("verify-2")], by: "person" },
    },
  },
  {
    id: "Q4", name: "conflict resolved → re-issue integrate with answer resolved",
    state: snapshotAt("integrate", conflict1, { lastRun: integrate1, seq: { integrate: 1, ask: 1 } }),
    signal: answer(conflict1, "resolved"),
    expect: {
      at: "integrate",
      commands: [cmd(awaited("integrate-2", "integrate", "run", { changeset, answer: "resolved" }, "integrate", "run"))],
      state: { retries: 0 },
      entry: { from: "integrate", to: "integrate", issued: [id("integrate-2")], by: "person" },
    },
  },
  {
    id: "Q5", name: "conflict rework → implement, fix rounds unchanged",
    state: snapshotAt("integrate", conflict1, { lastRun: integrate1, fixRounds: 1, findings, seq: { implement: 1, ask: 1 } }),
    signal: answer(conflict1, "rework"),
    expect: {
      at: "implement",
      commands: [cmd(awaited("implement-2", "implement", "run", { criteria, findings }, "implement", "run"))],
      state: { fixRounds: 1 },
      entry: { from: "integrate", to: "implement", issued: [id("implement-2")], by: "person" },
    },
  },
  {
    id: "Q6", name: "answer outside the ask's options → re-ask with a new id, invalid_answer",
    state: snapshotAt("verify", login1, { lastRun: verify1, retries: 1, seq: { verify: 1, ask: 1 } }),
    signal: answer(login1, "maybe"),
    expect: {
      at: "verify",
      commands: [cmd({ ...login1, id: id("ask-2") })],
      state: { retries: 1, awaiting: { ...login1, id: id("ask-2") }, lastRun: verify1 },
      entry: { from: "verify", to: "verify", issued: [id("ask-2")], by: "person", note: "invalid_answer" },
    },
  },
];
