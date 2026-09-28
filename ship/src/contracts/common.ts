// Shapes shared by the core, the Runner and every adapter (plan §3.1, §3.2): TS types, then their schemas.
import type { JSONSchemaType } from "ajv";
import { KEY_RE } from "../core/ids";

export type DeliveryId = string; // "<key>-<attempt>", e.g. "PROJ-123-2"
export type CommandId = string; // "<delivery>/<name>-<n>", e.g. "PROJ-123-2/land-1"
export type PrincipalKind = "person" | "model";

export type Port =
  | "define" | "implement" | "check" | "integrate" | "deploy" | "verify"
  | "tracker" | "principal" | "workspace" | "state";

export type WorkItem = { key: string; title: string; body: string; url?: string };
export type Finding = { text: string; ref?: string };
export type EvidenceItem = { label: string; text?: string; url?: string }; // P9: opaque, never read

export type Result<Body = unknown> =
  | { status: "ok"; body: Body; evidence?: EvidenceItem[] }
  | { status: "failed"; info: string } // could not run, changed nothing
  | { status: "question"; prompt: string; about: string; options?: string[]; evidence?: EvidenceItem[] };
export type Stdout<Body = unknown> = Result<Body> | { status: "accepted" };

export type Stdin = {
  id: CommandId;
  delivery: DeliveryId;
  port: Port;
  op: string;
  workItem: WorkItem;
  workspace: string | null;
  payload: unknown;
  tools: string[]; // capability profile tools; secrets go in env only
};

export type DecidePoint = "accept" | "decision" | "land" | "failure" | "blocked"; // blocked is a state, not a Gate
export type GateEvidence = {
  workItem: WorkItem;
  criteria: string[] | null;
  runbook: string[] | null;
  changeset: string | null;
  findings: Finding[];
  evidence: EvidenceItem[];
  note?: string;
};
export type Decide = { on: DecidePoint; options: string[]; min: PrincipalKind; evidence: GateEvidence };

// ── Schemas (ajv, one per type above; JSONSchemaType<T> keeps them in step with the types) ──


export const PORTS = [
  "define", "implement", "check", "integrate", "deploy", "verify", "tracker", "principal", "workspace", "state",
] as const satisfies readonly Port[];
export const PRINCIPAL_KINDS = ["person", "model"] as const satisfies readonly PrincipalKind[];

// JSONSchemaType<unknown> has no plain form ajv's strict mode accepts, so `{}` (any value) is cast once here.
export const anySchema = {} as JSONSchemaType<unknown> & { nullable: true };

export const stringsSchema: JSONSchemaType<string[]> = { type: "array", items: { type: "string" } };

// A required `T | null` field is written `anyOf: [<T>, nullSchema]`; JSONSchemaType rejects `nullable: true` there.
export const nullSchema = { type: "null", nullable: true } as const;

export const principalKindSchema: JSONSchemaType<PrincipalKind> = { type: "string", enum: PRINCIPAL_KINDS };

export const workItemSchema: JSONSchemaType<WorkItem> = {
  type: "object",
  properties: {
    key: { type: "string", pattern: KEY_RE.source },
    title: { type: "string" },
    body: { type: "string" },
    url: { type: "string", nullable: true },
  },
  required: ["key", "title", "body"],
  additionalProperties: false,
};

export const findingSchema: JSONSchemaType<Finding> = {
  type: "object",
  properties: { text: { type: "string" }, ref: { type: "string", nullable: true } },
  required: ["text"],
  additionalProperties: false,
};
export const findingsSchema: JSONSchemaType<Finding[]> = { type: "array", items: findingSchema };

export const evidenceItemSchema: JSONSchemaType<EvidenceItem> = {
  type: "object",
  properties: {
    label: { type: "string" },
    text: { type: "string", nullable: true },
    url: { type: "string", nullable: true },
  },
  required: ["label"],
  additionalProperties: false,
};
export const evidenceSchema: JSONSchemaType<EvidenceItem[]> = { type: "array", items: evidenceItemSchema };

export const gateEvidenceSchema: JSONSchemaType<GateEvidence> = {
  type: "object",
  properties: {
    workItem: workItemSchema,
    criteria: { anyOf: [stringsSchema, nullSchema] },
    runbook: { anyOf: [stringsSchema, nullSchema] },
    changeset: { anyOf: [{ type: "string" }, nullSchema] },
    findings: findingsSchema,
    evidence: evidenceSchema,
    note: { type: "string", nullable: true },
  },
  required: ["workItem", "criteria", "runbook", "changeset", "findings", "evidence"],
  additionalProperties: false,
};

export const decideSchema: JSONSchemaType<Decide> = {
  type: "object",
  properties: {
    on: { type: "string", enum: ["accept", "decision", "land", "failure", "blocked"] },
    options: stringsSchema,
    min: principalKindSchema,
    evidence: gateEvidenceSchema,
  },
  required: ["on", "options", "min", "evidence"],
  additionalProperties: false,
};

export const stdinSchema: JSONSchemaType<Stdin> = {
  type: "object",
  properties: {
    id: { type: "string" },
    delivery: { type: "string" },
    port: { type: "string", enum: PORTS },
    op: { type: "string" },
    workItem: workItemSchema,
    workspace: { anyOf: [{ type: "string" }, nullSchema] },
    payload: anySchema,
    tools: stringsSchema,
  },
  // JSONSchemaType cannot mark an `unknown` field required; the port/op payload schema checks it instead.
  required: ["id", "delivery", "port", "op", "workItem", "workspace", "tools"],
  additionalProperties: false,
};

// Result variants. `ok` is built per body in ports.ts; the others are fixed.
export type Ok<Body> = Extract<Result<Body>, { status: "ok" }>;
export type Failed = Extract<Result, { status: "failed" }>;
export type Question = Extract<Result, { status: "question" }>;
export type Accepted = { status: "accepted" };

export const okSchema = <Body>(body: JSONSchemaType<Body>): JSONSchemaType<Ok<Body>> =>
  ({
    type: "object",
    properties: { status: { type: "string", const: "ok" }, body, evidence: { ...evidenceSchema, nullable: true } },
    required: ["status", "body"],
    additionalProperties: false,
  }) as unknown as JSONSchemaType<Ok<Body>>; // TS cannot check a schema against a generic Body; bodies are checked at each call site

export const failedSchema: JSONSchemaType<Failed> = {
  type: "object",
  properties: { status: { type: "string", const: "failed" }, info: { type: "string" } },
  required: ["status", "info"],
  additionalProperties: false,
};

export const questionSchema: JSONSchemaType<Question> = {
  type: "object",
  properties: {
    status: { type: "string", const: "question" },
    prompt: { type: "string" },
    about: { type: "string" },
    options: { type: "array", items: { type: "string" }, nullable: true },
    evidence: { ...evidenceSchema, nullable: true },
  },
  required: ["status", "prompt", "about"],
  additionalProperties: false,
};

export const acceptedSchema: JSONSchemaType<Accepted> = {
  type: "object",
  properties: { status: { type: "string", const: "accepted" } },
  required: ["status"],
  additionalProperties: false,
};

/** Result with any body: what a `result` Signal carries once its port/op check has passed. */
export const anyResultSchema: JSONSchemaType<Result> = {
  oneOf: [okSchema(anySchema), failedSchema, questionSchema],
} as unknown as JSONSchemaType<Result>;
