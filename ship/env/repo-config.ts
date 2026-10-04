// A set-up repo's git root and its machine config's `state` argv, resolved for the environment scripts
// (env/judge.ts, env/queue.ts) the way `ship` resolves them (src/runner/config.ts's loadConfig): `<root>/ship.config.json`
// → projectId → `$SHIP_MACHINE_CONFIG`, else `~/.config/ship/<projectId>.json`. Environment code: the lookup is
// mirrored here, not imported from src/runner; files are checked against the src/contracts schemas. A missing or
// invalid file is a RepoConfigError naming it, in ship's own `<layer> config <path>: <reason>` shape.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import type { SchemaObject } from "ajv";
import { type MachineConfig, type ProjectConfig, machineConfigSchema, projectConfigSchema } from "../src/contracts/config";
import { check } from "../src/contracts/validate";

const SHIP = resolve(import.meta.dir, "..");

/** This checkout's `bin/ship`. */
export const SHIP_BIN = join(SHIP, "bin", "ship");

/** A repo or its config cannot be used: the script prints the message and exits 1. */
export class RepoConfigError extends Error {}

type Env = Record<string, string | undefined>;
export type RepoConfig = { projectId: string; machineFile: string; state: string[] };

/** The top of the git repo `dir` is in. */
export const gitRoot = (dir: string): string => {
  const top = Bun.spawnSync(["git", "-C", dir, "rev-parse", "--show-toplevel"], { stdout: "pipe", stderr: "pipe" });
  if (top.exitCode !== 0) throw new RepoConfigError(`not inside a git repo (${dir}): pass --repo <path> or run from the target repo`);
  return top.stdout.toString().trim();
};

const readLayer = <T>(path: string, schema: SchemaObject, layer: string): T => {
  const fail = (reason: string) =>
    new RepoConfigError(`${layer} config ${path}: ${reason}\nset the repo up with: bun ${join(SHIP, "env", "setup.ts")}`);
  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw fail(error instanceof Error ? error.message : String(error));
  }
  const invalid = check(schema, parsed);
  if (invalid) throw fail(invalid);
  return parsed as T;
};

/** The project id, the machine config file `ship` would read from `root`, and that file's `state` argv. */
export const repoConfig = (root: string, env: Env = process.env): RepoConfig => {
  const project = readLayer<ProjectConfig>(join(root, "ship.config.json"), projectConfigSchema, "project");
  const machineFile = env.SHIP_MACHINE_CONFIG ?? join(env.HOME ?? homedir(), ".config", "ship", `${project.projectId}.json`);
  const machine = readLayer<MachineConfig>(machineFile, machineConfigSchema, "machine");
  return { projectId: project.projectId, machineFile, state: machine.state };
};
