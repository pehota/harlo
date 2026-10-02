// Snapshot and journal Entry schemas: validated on State load (plan §5.2) and in state.* results.
import type { JSONSchemaType } from "ajv";
import { GATES, STEPS } from "../core/types";
import type { Awaiting, Entry, Node, Position, Snapshot } from "../core/types";
import {
  PORTS, anyResultSchema, anySchema, evidenceSchema, findingsSchema, nullSchema, principalKindSchema,
  stringsSchema, workItemSchema,
} from "./common";

/** A journal entry as stored: the Runner stamps `time`, the core has no clock. */
export type TimedEntry = Entry & { time: string };

const NODES: readonly Node[] = [...STEPS, ...GATES];
const POSITIONS: readonly Position[] = [...NODES, "blocked", "closed", "abandoned"];

const positionSchema: JSONSchemaType<Position> = { type: "string", enum: POSITIONS };
const nodeSchema: JSONSchemaType<Node> = { type: "string", enum: NODES };

const awaitingSchema: JSONSchemaType<Awaiting> = {
  type: "object",
  properties: {
    id: { type: "string" },
    port: { type: "string", enum: PORTS },
    op: { type: "string" },
    await: { type: "boolean" },
    payload: anySchema,
    node: { type: "string", enum: [...NODES, "blocked"] },
    kind: { type: "string", enum: ["run", "decide", "ask"] },
    options: { ...stringsSchema, nullable: true },
    about: { type: "string", nullable: true },
  },
  required: ["id", "port", "op", "await", "node", "kind"], // payload: see stdinSchema
  additionalProperties: false,
};
const maybeAwaiting = { anyOf: [awaitingSchema, nullSchema] };

export const snapshotSchema: JSONSchemaType<Snapshot> = {
  type: "object",
  properties: {
    v: { type: "integer", const: 1 },
    delivery: { type: "string" },
    workItem: workItemSchema,
    at: positionSchema,
    blockedAt: { anyOf: [nodeSchema, nullSchema] },
    awaiting: maybeAwaiting,
    lastRun: maybeAwaiting,
    blockedCmd: maybeAwaiting,
    seq: { type: "object", additionalProperties: { type: "integer" }, required: [] },
    retries: { type: "integer" },
    fixRounds: { type: "integer" },
    workspace: { anyOf: [{ type: "string" }, nullSchema] },
    criteria: { anyOf: [stringsSchema, nullSchema] },
    runbook: { anyOf: [stringsSchema, nullSchema] },
    changeset: { anyOf: [{ type: "string" }, nullSchema] },
    findings: findingsSchema,
    evidence: evidenceSchema,
    outcome: { anyOf: [{ type: "string" }, nullSchema] },
    reason: { anyOf: [{ type: "string" }, nullSchema] },
  },
  required: [
    "v", "delivery", "workItem", "at", "blockedAt", "awaiting", "lastRun", "blockedCmd", "seq", "retries",
    "fixRounds", "workspace", "criteria", "runbook", "changeset", "findings", "evidence", "outcome", "reason",
  ],
  additionalProperties: false,
};

const signalSchema: JSONSchemaType<Entry["signal"]> = {
  oneOf: [
    {
      type: "object",
      properties: { kind: { type: "string", const: "result" }, id: { type: "string" }, result: anyResultSchema },
      required: ["kind", "id", "result"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: { kind: { type: "string", const: "stop" }, outcome: { type: "string" }, reason: { type: "string" } },
      required: ["kind", "outcome", "reason"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: { kind: { type: "string", const: "workItem_changed" }, workItem: workItemSchema },
      required: ["kind", "workItem"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: {
        kind: { type: "string", const: "blocked_recovery" },
        action: { type: "string", enum: ["retry", "stop"] },
        comment: { type: "string", nullable: true },
      },
      required: ["kind", "action"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: { kind: { type: "string", const: "start" }, workItem: workItemSchema },
      required: ["kind", "workItem"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: {
        kind: { type: "string", const: "sent" },
        id: { type: "string" },
        pid: { type: "integer" },
        host: { type: "string" },
        started: { type: "string" },
        payload: anySchema,
      },
      required: ["kind", "id", "pid", "host", "started"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: { kind: { type: "string", const: "accepted" }, id: { type: "string" } },
      required: ["kind", "id"],
      additionalProperties: false,
    },
    {
      type: "object",
      properties: { kind: { type: "string", const: "adapter_error" }, id: { type: "string" } },
      required: ["kind", "id"],
      additionalProperties: false,
    },
  ],
};

export const timedEntrySchema: JSONSchemaType<TimedEntry> = {
  type: "object",
  properties: {
    delivery: { type: "string" },
    signal: signalSchema,
    from: { anyOf: [positionSchema, nullSchema] },
    to: positionSchema,
    issued: stringsSchema,
    by: { ...principalKindSchema, nullable: true },
    note: {
      type: "string",
      nullable: true,
      enum: [
        "ignored_stale", "ignored_terminal", "invalid_answer", "rejected_start",
        "workitem_changed_late", "workitem_unchanged", "ignored_not_blocked", "ignored_comment",
      ],
    },
    info: { type: "string", nullable: true },
    time: { type: "string" },
  },
  required: ["delivery", "signal", "from", "to", "issued", "time"],
  additionalProperties: false,
};
