// Project and machine config layers (plan §3.5). The layers have disjoint keys, and each schema rejects the
// other layer's keys (additionalProperties: false). Rules that span fields are checked in runner/config.ts.
import type { JSONSchemaType } from "ajv";
import { KEY_RE } from "../core/ids";
import { GATES, STEPS, type Node, type Step } from "../core/types";
import type { Port, PrincipalKind } from "./common";
import { PORTS, principalKindSchema, stringsSchema } from "./common";

/** Ports served from the repo; Principal and State are machine-specific (plan decision 10). */
export const PROJECT_PORTS = [
  "tracker", "workspace", "define", "implement", "check", "integrate", "deploy", "verify",
] as const satisfies readonly Port[];
export type ProjectPort = (typeof PROJECT_PORTS)[number];

export type TrackerOutcome = { status?: string; comment?: boolean };

/** `policy` as written: everything but the tracker outcome statuses has a default. */
export type PolicyConfig = {
  fixRounds?: number;
  retryCap?: { default?: number } & Partial<Record<Node, number>>;
  maxBlockedRetries?: number;
  minimum?: {
    accept?: PrincipalKind;
    land?: PrincipalKind;
    failure?: PrincipalKind;
    blocked?: PrincipalKind;
    decision?: { scope?: PrincipalKind; advisory?: PrincipalKind };
    question?: Record<string, PrincipalKind>;
  };
  outcomes?: string[];
  tracker: { steps?: Partial<Record<Step, string>>; outcomes: Record<string, TrackerOutcome> };
};

export type ProjectConfig = {
  projectId: string;
  adapters: Record<ProjectPort, string[]>; // argv prefix; the Runner appends <port> <op>
  policy: PolicyConfig;
};

export type CapabilityProfile = { env?: Record<string, string>; tools?: string[] }; // env values may be `$secrets.X`
export type MachineConfig = {
  principal: string[];
  state: string[];
  telemetry?: string[]; // optional: a Delivery lifecycle event sink (harlo-55), never required
  secrets?: Record<string, { env: string }>; // secret name → the Runner env var holding it
  capabilities?: Partial<Record<Port, CapabilityProfile>>;
};

const argvSchema: JSONSchemaType<string[]> = { type: "array", items: { type: "string" }, minItems: 1 };
const count = { type: "integer", minimum: 0, nullable: true } as const;
const kind = { ...principalKindSchema, nullable: true } as const;

/** An object with exactly the given optional keys, each of one schema. */
const optionalKeys = <K extends string, S>(keys: readonly K[], schema: S) =>
  Object.fromEntries(keys.map((key) => [key, schema])) as Record<K, S>;

const policySchema: JSONSchemaType<PolicyConfig> = {
  type: "object",
  properties: {
    fixRounds: count,
    retryCap: {
      type: "object",
      properties: { default: count, ...optionalKeys([...STEPS, ...GATES], count) },
      required: [],
      additionalProperties: false,
      nullable: true,
    },
    maxBlockedRetries: count,
    minimum: {
      type: "object",
      properties: {
        accept: kind, land: kind, failure: kind, blocked: kind,
        decision: {
          type: "object", properties: { scope: kind, advisory: kind }, required: [], additionalProperties: false,
          nullable: true,
        },
        question: { type: "object", additionalProperties: principalKindSchema, required: [], nullable: true },
      },
      required: [],
      additionalProperties: false,
      nullable: true,
    },
    outcomes: { ...stringsSchema, nullable: true },
    tracker: {
      type: "object",
      properties: {
        steps: {
          type: "object", properties: optionalKeys(STEPS, { type: "string", nullable: true } as const),
          required: [], additionalProperties: false, nullable: true,
        },
        outcomes: {
          type: "object",
          additionalProperties: {
            type: "object",
            properties: { status: { type: "string", nullable: true }, comment: { type: "boolean", nullable: true } },
            required: [],
            additionalProperties: false,
          },
          required: [],
        },
      },
      required: ["outcomes"],
      additionalProperties: false,
    },
  },
  required: ["tracker"],
  additionalProperties: false,
} as unknown as JSONSchemaType<PolicyConfig>; // TS cannot check the key maps built by optionalKeys against the type

export const projectConfigSchema: JSONSchemaType<ProjectConfig> = {
  type: "object",
  properties: {
    projectId: { type: "string", pattern: KEY_RE.source }, // names the machine file, so one safe path segment
    adapters: {
      type: "object",
      properties: optionalKeys(PROJECT_PORTS, argvSchema),
      required: [...PROJECT_PORTS],
      additionalProperties: false,
    },
    policy: policySchema,
  },
  required: ["projectId", "adapters", "policy"],
  additionalProperties: false,
};

const profileSchema: JSONSchemaType<CapabilityProfile> = {
  type: "object",
  properties: {
    env: { type: "object", additionalProperties: { type: "string" }, required: [], nullable: true },
    tools: { ...stringsSchema, nullable: true },
  },
  required: [],
  additionalProperties: false,
};

export const machineConfigSchema: JSONSchemaType<MachineConfig> = {
  type: "object",
  properties: {
    principal: argvSchema,
    state: argvSchema,
    telemetry: { ...argvSchema, nullable: true },
    secrets: {
      type: "object",
      additionalProperties: {
        type: "object", properties: { env: { type: "string" } }, required: ["env"], additionalProperties: false,
      },
      required: [],
      nullable: true,
    },
    capabilities: {
      type: "object",
      properties: optionalKeys(PORTS, { ...profileSchema, nullable: true }),
      required: [],
      additionalProperties: false,
      nullable: true,
    },
  },
  required: ["principal", "state"],
  additionalProperties: false,
} as unknown as JSONSchemaType<MachineConfig>; // as policySchema: optionalKeys maps are not checkable by TS
