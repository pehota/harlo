// Load the two config layers (plan §3.5), validate them, resolve `$secrets.X` into each port's capability
// profile env, and build the core Policy with its defaults. Any problem is a ConfigError (the CLI's exit 2).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { SchemaObject } from "ajv";
import type { Port } from "../contracts/common";
import { PORTS } from "../contracts/common";
import {
  type CapabilityProfile, type MachineConfig, type PolicyConfig, type ProjectConfig, machineConfigSchema,
  projectConfigSchema,
} from "../contracts/config";
import { check } from "../contracts/validate";
import type { Policy } from "../core/types";
import type { AdapterSpec } from "./spawn";

/** A config that cannot be used; nothing has been touched when it is thrown. */
export class ConfigError extends Error {
  override name = "ConfigError";
}

export type Config = { projectId: string; policy: Policy; adapters: Record<Port, AdapterSpec>; telemetry: AdapterSpec | null };
type Env = Record<string, string | undefined>;

const DEFAULT_POLICY = {
  fixRounds: 2,
  retryCap: { default: 1 }, // plan §3.5 example; the plan names no other default
  maxBlockedRetries: 3, // enough slack for a transient failure, far short of looping unboundedly
  minimum: {
    accept: "person", land: "person", failure: "person", blocked: "person",
    decision: { scope: "person", advisory: "model" }, // architecture: Gates table, v1 defaults
    question: {}, // an unknown `about` is `person` in the core
  },
  outcomes: ["rolled_back", "abandoned"],
} as const satisfies Omit<Policy, "tracker">;

const readLayer = <T>(path: string, schema: SchemaObject, layer: string): T => {
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new ConfigError(`${layer} config ${path}: ${error instanceof Error ? error.message : String(error)}`);
  }
  const invalid = check(schema, parsed);
  if (invalid) throw new ConfigError(`${layer} config ${path}: ${invalid}`);
  return parsed as T;
};

const buildPolicy = (written: PolicyConfig): Policy => {
  const minimum = written.minimum ?? {};
  return {
    fixRounds: written.fixRounds ?? DEFAULT_POLICY.fixRounds,
    retryCap: { ...DEFAULT_POLICY.retryCap, ...written.retryCap },
    maxBlockedRetries: written.maxBlockedRetries ?? DEFAULT_POLICY.maxBlockedRetries,
    minimum: {
      ...DEFAULT_POLICY.minimum,
      ...minimum,
      decision: { ...DEFAULT_POLICY.minimum.decision, ...minimum.decision },
      question: minimum.question ?? {},
    },
    outcomes: written.outcomes ?? [...DEFAULT_POLICY.outcomes],
    tracker: { steps: written.tracker.steps ?? {}, outcomes: written.tracker.outcomes },
  };
};

/** Close awaits a status for the two derived outcomes; every stop outcome needs a mapping that comments. */
const checkPolicy = (policy: Policy): void => {
  const mapped = policy.tracker.outcomes;
  for (const derived of ["delivered", "accepted_with_failure"]) {
    if (mapped[derived]?.status === undefined) {
      throw new ConfigError(`policy.tracker.outcomes.${derived}.status is required: Close awaits it`);
    }
  }
  const unmapped = policy.outcomes.filter((outcome) => !Object.hasOwn(mapped, outcome));
  if (unmapped.length > 0) throw new ConfigError(`policy.outcomes without a policy.tracker.outcomes mapping: ${unmapped.join(", ")}`);
  // A stop must leave its reason somewhere a person can inspect it: the tracker comment.
  const uncommented = policy.outcomes.find((outcome) => mapped[outcome]?.comment !== true);
  if (uncommented !== undefined) {
    throw new ConfigError(`policy.tracker.outcomes.${uncommented}.comment must be true: a stop's reason is kept as a tracker comment`);
  }
};

const SECRET_REF = /^\$secrets\.(.+)$/;

/** A profile env value, with a `$secrets.X` reference replaced by the value of X's env var. */
const resolveValue = (value: string, secrets: NonNullable<MachineConfig["secrets"]>, env: Env): string => {
  const name = SECRET_REF.exec(value)?.[1];
  if (name === undefined) return value;
  const secret = Object.hasOwn(secrets, name) ? secrets[name] : undefined;
  if (!secret) throw new ConfigError(`undeclared secret ${value}: add it to the machine config's "secrets"`);
  const resolved = env[secret.env];
  if (!resolved) throw new ConfigError(`secret ${name}: env var ${secret.env} is not set`);
  return resolved;
};

const adapterSpec = (argv: string[], profile: CapabilityProfile, secrets: NonNullable<MachineConfig["secrets"]>, env: Env): AdapterSpec => ({
  argv,
  env: Object.fromEntries(Object.entries(profile.env ?? {}).map(([name, value]) => [name, resolveValue(value, secrets, env)])),
  tools: profile.tools ?? [],
});

/** Load `<repo>/ship.config.json` and the machine layer (`$SHIP_MACHINE_CONFIG`, else ~/.config/ship/<projectId>.json). */
export const loadConfig = (repo: string, env: Env = process.env): Config => {
  const project = readLayer<ProjectConfig>(join(repo, "ship.config.json"), projectConfigSchema, "project");
  const machinePath = env.SHIP_MACHINE_CONFIG ?? join(env.HOME ?? homedir(), ".config", "ship", `${project.projectId}.json`);
  const machine = readLayer<MachineConfig>(machinePath, machineConfigSchema, "machine");

  const policy = buildPolicy(project.policy);
  checkPolicy(policy);

  const argvs: Record<Port, string[]> = { ...project.adapters, principal: machine.principal, state: machine.state };
  const secrets = machine.secrets ?? {};
  const profiles = machine.capabilities ?? {};
  const adapters = Object.fromEntries(
    PORTS.map((port) => [port, adapterSpec(argvs[port], profiles[port] ?? {}, secrets, env)]),
  ) as Record<Port, AdapterSpec>;
  const telemetry = machine.telemetry ? { argv: machine.telemetry, env: {}, tools: [] } : null;

  return { projectId: project.projectId, policy, adapters, telemetry };
};
