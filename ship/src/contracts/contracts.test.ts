import { describe, expect, test } from "bun:test";
import Ajv, { type JSONSchemaType, type SchemaObject } from "ajv";
import type { Port } from "./common";
import { decideSchema, stdinSchema, type Finding } from "./common";
import { schemaFor } from "./ports";
import { snapshotSchema } from "./snapshot";

const ajv = new Ajv();
const valid = (schema: SchemaObject, data: unknown): boolean => ajv.validate(schema, data);
const must = <T>(x: T | undefined): T => {
  if (x === undefined) throw new Error("missing schema");
  return x;
};

const workItem = { key: "PROJ-1", title: "Add a greeting", body: "Say hello." };
const gateEvidence = {
  workItem, criteria: ["greets"], runbook: null, changeset: null, findings: [], evidence: [],
};

describe("every port/op in §3.2 has a schema", () => {
  const allPorts: Port[] = [
    "define", "implement", "check", "integrate", "deploy", "verify", "tracker", "principal", "workspace", "state",
  ];
  const listed: [Port, string][] = [
    ["define", "run"], ["implement", "run"], ["check", "run"], ["integrate", "run"], ["deploy", "run"], ["verify", "run"],
    ["workspace", "setup"], ["workspace", "teardown"],
    ["tracker", "update"], ["tracker", "comment"], ["tracker", "read"], ["tracker", "next"],
    ["principal", "decide"], ["principal", "ask"], ["principal", "notify"],
    ["state", "load"], ["state", "save"], ["state", "list"], ["state", "journal"],
    ...allPorts.map((port): [Port, string] => [port, "cancel"]),
  ];
  test.each(listed)("%s.%s", (port, op) => {
    const entry = must(schemaFor(port, op));
    expect(Object.keys(entry).sort()).toEqual(["payload", "result", "stdout"]);
  });
  test.each([
    ["define", "setup"],
    ["state", "run"],
    ["tracker", "toString"],
  ] as [Port, string][])("%s.%s has none", (port, op) => {
    expect(schemaFor(port, op)).toBeUndefined();
  });
});

describe("Result", () => {
  const step = must(schemaFor("define", "run"));
  const service = must(schemaFor("workspace", "setup"));
  const runnerOnly = must(schemaFor("state", "list"));
  const okDefine = { status: "ok", body: { criteria: ["greets"], runbook: ["run it"] } };
  const question = { status: "question", prompt: "Which greeting?", about: "clarify", options: ["hi", "hello"] };
  const accepted = { status: "accepted" };
  const failed = { status: "failed", info: "no network" };

  const rows: [string, SchemaObject, unknown, boolean][] = [
    ["step ok", step.result, okDefine, true],
    ["step ok with evidence", step.result, { ...okDefine, evidence: [{ label: "log", url: "file:///x" }] }, true],
    ["step failed", step.result, failed, true],
    ["step question", step.result, question, true],
    ["step question without options", step.result, { status: "question", prompt: "p", about: "login" }, true],
    ["step question without about", step.result, { status: "question", prompt: "p" }, false],
    ["step accepted is not a Result", step.result, accepted, false],
    ["step stdout accepted", step.stdout, accepted, true],
    ["step stdout question", step.stdout, question, true],
    ["ok without body", step.result, { status: "ok" }, false],
    ["ok with a body outside the port's schema", step.result, { status: "ok", body: { criteria: "x" } }, false],
    ["failed without info", step.result, { status: "failed" }, false],
    ["unknown status", step.result, { status: "done" }, false],
    ["no status", step.result, { body: {} }, false],
    ["extra top-level field", step.result, { ...failed, extra: 1 }, false],
    ["service ok", service.result, { status: "ok", body: { path: "/w" } }, true],
    ["service failed", service.result, failed, true],
    ["service question rejected", service.result, question, false],
    ["service stdout question rejected", service.stdout, question, false],
    ["service stdout accepted", service.stdout, accepted, true],
    ["runner-only ok", runnerOnly.result, { status: "ok", body: { deliveries: ["PROJ-1-1"] } }, true],
    ["runner-only question rejected", runnerOnly.result, question, false],
    ["runner-only stdout accepted rejected", runnerOnly.stdout, accepted, false],
    ["runner-only stdout question rejected", runnerOnly.stdout, question, false],
  ];
  test.each(rows)("%s", (_, schema, data, expected) => {
    expect(valid(schema, data)).toBe(expected);
  });
});

describe("check ok union", () => {
  const check = must(schemaFor("check", "run")).result;
  const findings: Finding[] = [{ text: "missing test", ref: "src/a.ts:3" }];
  test.each([
    ["pass", { verdict: "pass" }, true],
    ["fix", { verdict: "fix", findings }, true],
    ["decide scope", { verdict: "decide", about: "scope", findings }, true],
    ["decide advisory", { verdict: "decide", about: "advisory", findings: [] }, true],
    ["fix without findings", { verdict: "fix" }, false],
    ["decide without about", { verdict: "decide", findings }, false],
    ["decide with unknown about", { verdict: "decide", about: "style", findings }, false],
    ["verdict from another port", { verdict: "landed" }, false],
    ["pass with extra field", { verdict: "pass", findings }, false],
    ["finding without text", { verdict: "fix", findings: [{ ref: "x" }] }, false],
  ])("%s", (_, body, expected) => {
    expect(valid(check, { status: "ok", body })).toBe(expected);
  });
});

describe("Decide", () => {
  const decide = { on: "land", options: ["approve", "rework", "rescope"], min: "person", evidence: gateEvidence };
  test.each([
    ["valid", decide, true],
    ["blocked is a decide point", { ...decide, on: "blocked", options: ["retry", "stop"] }, true],
    ["evidence with note", { ...decide, evidence: { ...gateEvidence, note: "workItem changed" } }, true],
    ["unknown point", { ...decide, on: "merge" }, false],
    ["unknown principal kind", { ...decide, min: "robot" }, false],
    ["missing evidence", { on: "land", options: [], min: "model" }, false],
    ["evidence missing workItem", { ...decide, evidence: { ...gateEvidence, workItem: undefined } }, false],
  ])("%s", (_, data, expected) => {
    expect(valid(decideSchema, data)).toBe(expected);
    expect(valid(must(schemaFor("principal", "decide")).payload, data)).toBe(expected);
  });
});

describe("Stdin", () => {
  const stdin = {
    id: "PROJ-1-1/define-1", delivery: "PROJ-1-1", port: "define", op: "run",
    workItem, workspace: "/w/PROJ-1-1", payload: {}, tools: [],
  };
  test.each([
    ["valid", stdin, true],
    ["workspace null", { ...stdin, workspace: null }, true],
    ["any payload", { ...stdin, payload: ["x", 1] }, true],
    ["unknown port", { ...stdin, port: "deployer" }, false],
    ["workItem key breaks the key regex", { ...stdin, workItem: { ...workItem, key: "-bad" } }, false],
    ["missing tools", { ...stdin, tools: undefined }, false],
    ["missing payload (left to the port/op payload schema)", { ...stdin, payload: undefined }, true],
    ["extra field", { ...stdin, secret: "x" }, false],
  ])("%s", (_, data, expected) => {
    expect(valid(stdinSchema, JSON.parse(JSON.stringify(data)))).toBe(expected);
  });
});

describe("Snapshot", () => {
  const snapshot = {
    v: 1, delivery: "PROJ-1-1", workItem, at: "setup", blockedAt: null,
    awaiting: { id: "PROJ-1-1/setup-1", port: "workspace", op: "setup", await: true, payload: {}, node: "setup", kind: "run" },
    lastRun: null, blockedCmd: null, seq: { setup: 1 }, retries: 0, fixRounds: 0, workspace: null,
    criteria: null, runbook: null, changeset: null, findings: [], evidence: [], outcome: null, reason: null,
  };
  test.each([
    ["valid", snapshot, true],
    ["blocked", { ...snapshot, at: "blocked", blockedAt: "setup" }, true],
    ["wrong version", { ...snapshot, v: 2 }, false],
    ["unknown position", { ...snapshot, at: "nowhere" }, false],
    ["blockedAt not a node", { ...snapshot, blockedAt: "closed" }, false],
    ["seq not numbers", { ...snapshot, seq: { setup: "1" } }, false],
    ["missing field", { ...snapshot, reason: undefined }, false],
  ])("%s", (_, data, expected) => {
    expect(valid(snapshotSchema, JSON.parse(JSON.stringify(data)))).toBe(expected);
  });
});

describe("state ops carry snapshots and timed entries", () => {
  const entry = {
    delivery: "PROJ-1-1", signal: { kind: "start", workItem }, from: null, to: "setup",
    issued: ["PROJ-1-1/setup-1"], time: "2026-09-28T10:00:00.000Z",
  };
  test.each([
    ["load empty", "load", { status: "ok", body: { version: 0, state: null } }, true],
    ["load version without state", "load", { status: "ok", body: { version: 3, state: null } }, false],
    ["save saved", "save", { status: "ok", body: { saved: true } }, true],
    ["save conflict", "save", { status: "ok", body: { conflict: true } }, true],
    ["save neither", "save", { status: "ok", body: {} }, false],
    ["journal", "journal", { status: "ok", body: { entries: [entry] } }, true],
    ["journal entry without time", "journal", { status: "ok", body: { entries: [{ ...entry, time: undefined }] } }, false],
    ["journal sent entry", "journal", {
      status: "ok",
      body: { entries: [{ ...entry, signal: { kind: "sent", id: "PROJ-1-1/setup-1", pid: 42, host: "h", started: "Mon" }, issued: [] }] },
    }, true],
  ])("%s", (_, op, data, expected) => {
    expect(valid(must(schemaFor("state", op)).result, JSON.parse(JSON.stringify(data)))).toBe(expected);
  });
});

test("type test: JSONSchemaType<T> rejects a schema that does not match T", () => {
  // @ts-expect-error the schema says number, the type says string
  const wrong: JSONSchemaType<{ text: string }> = {
    type: "object", properties: { text: { type: "number" } }, required: ["text"],
  };
  expect(wrong).toBeDefined();
});
