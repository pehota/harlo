// Port → op → {stdin, payload, result, stdout} schemas (plan §3.2). Each payload and `ok` body is written once as
// a TS type and once as a JSONSchemaType of it; `entry` composes the Result/Stdout variants per kind of call.
import type { JSONSchemaType, SchemaObject } from "ajv";
import type { CommandId, DeliveryId, Finding, GateEvidence, Port, PrincipalKind, Requirements, WorkItem } from "./common";
import {
  PORTS, acceptedSchema, anySchema, decideSchema, failedSchema, findingsSchema, gateEvidenceSchema, okSchema,
  principalKindSchema, questionSchema, runnerStdinSchema, stdinSchema, stringsSchema, workItemSchema, nullSchema,
} from "./common";
import type { Snapshot } from "../core/types";
import { snapshotSchema, timedEntrySchema, type TimedEntry } from "./snapshot";

// ── Step ports (op `run`) ──
// base: the main-line branch the Delivery branched off (SetupBody.base); absent only for a Delivery set up before it.
export type DefinePayload = { base?: string; feedback?: string; answer?: string };
// requirements: whatever the Define adapter emits (harlo-58) — the core carries it unchanged, never interprets it.
export type DefineBody = { requirements: Requirements };
export type ImplementPayload = {
  base?: string; requirements: Requirements; findings: Finding[]; feedback?: string; answer?: string;
};
/** `feedback` is present exactly when the payload carried `feedback`: what the agent did with the Principal's comment. */
export type ImplementFeedback = { outcome: "applied" | "declined"; reason: string };
export type ImplementBody = { changeset: string; feedback?: ImplementFeedback }; // changeset: opaque ref
export type CheckPayload = { base?: string; requirements: Requirements; changeset: string; answer?: string };
export type CheckBody =
  | { verdict: "pass" }
  | { verdict: "fix"; findings: Finding[] }
  | { verdict: "decide"; about: "scope" | "advisory"; findings: Finding[] };
export type IntegratePayload = { changeset: string; answer?: string };
export type IntegrateBody = { verdict: "landed" } | { verdict: "fix"; findings: Finding[] }; // conflict: question{about:"conflict"}
export type DeployPayload = { changeset: string; answer?: string };
export type DeployBody = { verdict: "live" } | { verdict: "not_live"; findings?: Finding[] };
export type VerifyPayload = { requirements: Requirements; answer?: string };
export type VerifyBody = { verdict: "pass" } | { verdict: "fail"; findings: Finding[] };

// ── Service ports ──
export type Empty = Record<string, never>;
export type SetupBody = { path: string; base: string }; // base: the main-line branch `ship/<delivery>` branched off
export type TeardownPayload = { path: string };
export type TrackerUpdatePayload = { status: string }; // opaque, from config
export type TrackerCommentPayload = { text: string };
export type DecideBody = { answer: string; comment?: string; by: PrincipalKind };
export type AskPayload = { prompt: string; min: PrincipalKind; options?: string[]; evidence: GateEvidence };
export type AskBody = { answer: string; by: PrincipalKind };
export type NotifyPayload = { text: string; evidence?: GateEvidence };
export type CancelPayload = { target: CommandId };

// ── Runner-only calls ──
export type TrackerReadPayload = { key: string };
export type TrackerReadBody = { workItem: WorkItem };
export type TrackerNextBody = { key: string | null };
export type StateLoadPayload = { delivery: DeliveryId };
// Plan §3.2 writes this as a union; JSONSchemaType cannot type a `null`-only field, so the schema's
// if/then pairs them instead: version 0 iff state null.
export type StateLoadBody = { version: number; state: Snapshot | null };
export type StateSavePayload = { delivery: DeliveryId; version: number; state: Snapshot; entries: TimedEntry[] };
export type StateSaveBody = { saved: true } | { conflict: true };
export type StateListPayload = { key?: string };
export type StateListBody = { deliveries: DeliveryId[] };
export type StateJournalPayload = { delivery: DeliveryId };
export type StateJournalBody = { entries: TimedEntry[] };

/**
 * step: ok | failed | question, and the adapter may print `accepted`.
 * service: no `question` (only step ports ask back).
 * runner: the Runner waits on it, so no `question` and never `accepted`; its Stdin may lack a Delivery.
 */
type Kind = "step" | "service" | "runner";
export type PortOpSchemas = { stdin: SchemaObject; payload: SchemaObject; result: SchemaObject; stdout: SchemaObject };

const entry = <P, B>(kind: Kind, payload: JSONSchemaType<P>, body: JSONSchemaType<B>): PortOpSchemas => {
  const resultVariants = kind === "step"
    ? [okSchema(body), failedSchema, questionSchema]
    : [okSchema(body), failedSchema];
  const stdoutVariants = kind === "runner" ? resultVariants : [...resultVariants, acceptedSchema];
  const stdin = kind === "runner" ? runnerStdinSchema : stdinSchema;
  return { stdin, payload, result: { oneOf: resultVariants }, stdout: { oneOf: stdoutVariants } };
};

// ── Payload and body schemas ──
const str = { type: "string" } as const;
const answer = { type: "string", nullable: true } as const;
const emptySchema: JSONSchemaType<Empty> = { type: "object", properties: {}, required: [], additionalProperties: false };

const definePayload: JSONSchemaType<DefinePayload> = { type: "object", additionalProperties: false,
  properties: { base: answer, feedback: answer, answer }, required: [],
};
// JSONSchemaType cannot mark an `unknown` field required (see stdinSchema's `payload`); `requirements` is left
// out of `required` below for the same reason even though it is not optional at the TS level.
const defineBody: JSONSchemaType<DefineBody> = { type: "object", additionalProperties: false,
  properties: { requirements: anySchema }, required: [],
};
const implementPayload: JSONSchemaType<ImplementPayload> = { type: "object", additionalProperties: false,
  properties: { base: answer, requirements: anySchema, findings: findingsSchema, feedback: answer, answer },
  required: ["findings"],
};
const implementBody: JSONSchemaType<ImplementBody> = { type: "object", additionalProperties: false,
  properties: {
    changeset: str,
    feedback: { type: "object", additionalProperties: false, nullable: true,
      properties: { outcome: { type: "string", enum: ["applied", "declined"] }, reason: { type: "string", minLength: 1 } },
      required: ["outcome", "reason"],
    },
  },
  required: ["changeset"],
};
const checkPayload: JSONSchemaType<CheckPayload> = { type: "object", additionalProperties: false,
  properties: { base: answer, requirements: anySchema, changeset: str, answer }, required: ["changeset"],
};
const checkBody: JSONSchemaType<CheckBody> = {
  oneOf: [
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "pass" } }, required: ["verdict"] },
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "fix" }, findings: findingsSchema }, required: ["verdict", "findings"] },
    { type: "object", additionalProperties: false,
      properties: {
        verdict: { type: "string", const: "decide" },
        about: { type: "string", enum: ["scope", "advisory"] },
        findings: findingsSchema,
      },
      required: ["verdict", "about", "findings"],
    },
  ],
};
const changesetPayload: JSONSchemaType<IntegratePayload & DeployPayload> = { type: "object", additionalProperties: false,
  properties: { changeset: str, answer }, required: ["changeset"],
};
const integrateBody: JSONSchemaType<IntegrateBody> = {
  oneOf: [
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "landed" } }, required: ["verdict"] },
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "fix" }, findings: findingsSchema }, required: ["verdict", "findings"] },
  ],
};
const deployBody: JSONSchemaType<DeployBody> = {
  oneOf: [
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "live" } }, required: ["verdict"] },
    { type: "object", additionalProperties: false,
      properties: { verdict: { type: "string", const: "not_live" }, findings: { ...findingsSchema, nullable: true } },
      required: ["verdict"],
    },
  ],
};
const verifyPayload: JSONSchemaType<VerifyPayload> = { type: "object", additionalProperties: false,
  properties: { requirements: anySchema, answer }, required: [],
};
const verifyBody: JSONSchemaType<VerifyBody> = {
  oneOf: [
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "pass" } }, required: ["verdict"] },
    { type: "object", additionalProperties: false, properties: { verdict: { type: "string", const: "fail" }, findings: findingsSchema }, required: ["verdict", "findings"] },
  ],
};

const setupBody: JSONSchemaType<SetupBody> = { type: "object", additionalProperties: false,
  properties: { path: str, base: str }, required: ["path", "base"],
};
const teardownPayload: JSONSchemaType<TeardownPayload> = { type: "object", additionalProperties: false, properties: { path: str }, required: ["path"] };
const trackerUpdatePayload: JSONSchemaType<TrackerUpdatePayload> = { type: "object", additionalProperties: false, properties: { status: str }, required: ["status"] };
const textPayload: JSONSchemaType<TrackerCommentPayload> = { type: "object", additionalProperties: false, properties: { text: str }, required: ["text"] };
const decideBody: JSONSchemaType<DecideBody> = { type: "object", additionalProperties: false,
  properties: { answer: str, comment: answer, by: principalKindSchema }, required: ["answer", "by"],
};
const askPayload: JSONSchemaType<AskPayload> = { type: "object", additionalProperties: false,
  properties: {
    prompt: str, min: principalKindSchema, options: { ...stringsSchema, nullable: true }, evidence: gateEvidenceSchema,
  },
  required: ["prompt", "min", "evidence"],
};
const askBody: JSONSchemaType<AskBody> = { type: "object", additionalProperties: false, properties: { answer: str, by: principalKindSchema }, required: ["answer", "by"] };
const notifyPayload: JSONSchemaType<NotifyPayload> = { type: "object", additionalProperties: false,
  properties: { text: str, evidence: { ...gateEvidenceSchema, nullable: true } }, required: ["text"],
};
const cancelPayload: JSONSchemaType<CancelPayload> = { type: "object", additionalProperties: false, properties: { target: str }, required: ["target"] };

const trackerReadPayload: JSONSchemaType<TrackerReadPayload> = { type: "object", additionalProperties: false, properties: { key: str }, required: ["key"] };
const trackerReadBody: JSONSchemaType<TrackerReadBody> = { type: "object", additionalProperties: false, properties: { workItem: workItemSchema }, required: ["workItem"] };
const trackerNextBody: JSONSchemaType<TrackerNextBody> = { type: "object", additionalProperties: false,
  properties: { key: { anyOf: [str, nullSchema] } }, required: ["key"],
};
const deliveryPayload: JSONSchemaType<StateLoadPayload & StateJournalPayload> = { type: "object", additionalProperties: false,
  properties: { delivery: str }, required: ["delivery"],
};
const stateLoadBody: JSONSchemaType<StateLoadBody> = {
  type: "object", additionalProperties: false,
  properties: { version: { type: "integer", minimum: 0 }, state: { anyOf: [snapshotSchema, nullSchema] } },
  required: ["version", "state"],
  if: { properties: { version: { const: 0 } } },
  then: { properties: { state: { type: "null" } } },
  else: { properties: { state: { type: "object" } } },
};
const stateSavePayload: JSONSchemaType<StateSavePayload> = { type: "object", additionalProperties: false,
  properties: {
    delivery: str, version: { type: "integer", minimum: 1 }, state: snapshotSchema,
    entries: { type: "array", items: timedEntrySchema },
  },
  required: ["delivery", "version", "state", "entries"],
};
const stateSaveBody: JSONSchemaType<StateSaveBody> = {
  oneOf: [
    { type: "object", additionalProperties: false, properties: { saved: { type: "boolean", const: true } }, required: ["saved"] },
    { type: "object", additionalProperties: false, properties: { conflict: { type: "boolean", const: true } }, required: ["conflict"] },
  ],
};
const stateListPayload: JSONSchemaType<StateListPayload> = { type: "object", additionalProperties: false, properties: { key: answer }, required: [] };
const stateListBody: JSONSchemaType<StateListBody> = { type: "object", additionalProperties: false, properties: { deliveries: stringsSchema }, required: ["deliveries"] };
const stateJournalBody: JSONSchemaType<StateJournalBody> = { type: "object", additionalProperties: false,
  properties: { entries: { type: "array", items: timedEntrySchema } }, required: ["entries"],
};

// ── Registry ──
const cancel = entry("service", cancelPayload, emptySchema); // every adapter accepts `cancel`; fire, exit 0 if nothing to cancel

const registry: Record<Port, Record<string, PortOpSchemas>> = {
  define: { run: entry("step", definePayload, defineBody) },
  implement: { run: entry("step", implementPayload, implementBody) },
  check: { run: entry("step", checkPayload, checkBody) },
  integrate: { run: entry("step", changesetPayload, integrateBody) },
  deploy: { run: entry("step", changesetPayload, deployBody) },
  verify: { run: entry("step", verifyPayload, verifyBody) },
  workspace: {
    setup: entry("service", emptySchema, setupBody),
    teardown: entry("service", teardownPayload, emptySchema),
  },
  tracker: {
    update: entry("service", trackerUpdatePayload, emptySchema),
    comment: entry("service", textPayload, emptySchema),
    read: entry("runner", trackerReadPayload, trackerReadBody),
    next: entry("runner", emptySchema, trackerNextBody),
  },
  principal: {
    decide: entry("service", decideSchema, decideBody),
    ask: entry("service", askPayload, askBody),
    notify: entry("service", notifyPayload, emptySchema),
  },
  state: {
    load: entry("runner", deliveryPayload, stateLoadBody),
    save: entry("runner", stateSavePayload, stateSaveBody),
    list: entry("runner", stateListPayload, stateListBody),
    journal: entry("runner", deliveryPayload, stateJournalBody),
  },
};
for (const port of PORTS) registry[port].cancel = cancel;

/** The schemas for one port/op, or undefined when the port has no such op. */
export const schemaFor = (port: Port, op: string): PortOpSchemas | undefined =>
  Object.hasOwn(registry[port], op) ? registry[port][op] : undefined;
