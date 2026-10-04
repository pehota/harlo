// env/repo-config.ts: a repo's git root and the State argv its machine config names, resolved the way `ship`
// itself does (src/runner/config.ts), against temp git repos and a temp HOME.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { RepoConfigError, SHIP_BIN, gitRoot, repoConfig } from "./repo-config";

const SHIP = join(import.meta.dir, "..");
const STATE = ["bun", "/abs/state/files.ts", "--dir", "/abs/state"];
const PORTS = ["tracker", "workspace", "define", "implement", "check", "integrate", "deploy", "verify"];
/** A schema-valid project config for `projectId`. */
const projectConfig = (projectId: string) => ({
  projectId, adapters: Object.fromEntries(PORTS.map((port) => [port, ["bun", `${port}.ts`]])),
  policy: { tracker: { outcomes: {} } },
});

const temps: string[] = [];
afterAll(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});
const tempDir = (prefix: string): string => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  temps.push(dir);
  return dir;
};

/** A temp git repo holding `ship.config.json` for project `id` (none when `id` is null). */
const repo = (id: string | null = "acme"): string => {
  const root = tempDir("ship-repo-config-");
  Bun.spawnSync(["git", "init", "-q", root]);
  if (id !== null) writeFileSync(join(root, "ship.config.json"), JSON.stringify(projectConfig(id)));
  return root;
};

const writeMachine = (path: string, machine: unknown = { principal: ["bun", "p.ts"], state: STATE }): string => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, JSON.stringify(machine));
  return path;
};

const errorOf = (fn: () => unknown): Error => {
  try {
    fn();
  } catch (error) {
    return error as Error;
  }
  throw new Error("expected a throw");
};

describe("gitRoot", () => {
  test("a subdir of a repo resolves to the repo's root", () => {
    const root = repo();
    const sub = join(root, "a", "b");
    mkdirSync(sub, { recursive: true });
    expect(gitRoot(sub)).toBe(root);
  });

  test("outside any git repo: a RepoConfigError naming the dir and --repo", () => {
    const dir = tempDir("ship-repo-config-nogit-");
    const error = errorOf(() => gitRoot(dir));
    expect(error).toBeInstanceOf(RepoConfigError);
    expect(error.message).toContain(dir);
    expect(error.message).toContain("--repo");
  });
});

describe("repoConfig", () => {
  test("default machine config: ~/.config/ship/<projectId>.json under HOME", () => {
    const root = repo("acme");
    const home = tempDir("ship-repo-config-home-");
    const machineFile = writeMachine(join(home, ".config", "ship", "acme.json"));
    expect(repoConfig(root, { HOME: home })).toEqual({ projectId: "acme", machineFile, state: STATE });
  });

  test("$SHIP_MACHINE_CONFIG overrides the default path", () => {
    const root = repo("acme");
    const home = tempDir("ship-repo-config-home-");
    writeMachine(join(home, ".config", "ship", "acme.json"), { principal: ["x"], state: ["wrong"] });
    const machineFile = writeMachine(join(tempDir("ship-repo-config-m-"), "m.json"));
    expect(repoConfig(root, { HOME: home, SHIP_MACHINE_CONFIG: machineFile }).state).toEqual(STATE);
  });

  test("no ship.config.json: the error names that file and suggests setup.ts", () => {
    const root = repo(null);
    const error = errorOf(() => repoConfig(root, { HOME: tempDir("ship-repo-config-home-") }));
    expect(error).toBeInstanceOf(RepoConfigError);
    expect(error.message).toContain(`project config ${join(root, "ship.config.json")}:`);
    expect(error.message).toContain(`bun ${join(SHIP, "env", "setup.ts")}`);
  });

  test("an invalid ship.config.json: the error names that file", () => {
    const root = repo(null);
    writeFileSync(join(root, "ship.config.json"), JSON.stringify({ adapters: {} }));
    const error = errorOf(() => repoConfig(root, {}));
    expect(error.message).toContain(`project config ${join(root, "ship.config.json")}:`);
  });

  test("no machine config: the error names the exact default path and suggests setup.ts", () => {
    const root = repo("acme");
    const home = tempDir("ship-repo-config-home-");
    const error = errorOf(() => repoConfig(root, { HOME: home }));
    expect(error).toBeInstanceOf(RepoConfigError);
    expect(error.message).toContain(`machine config ${join(home, ".config", "ship", "acme.json")}:`);
    expect(error.message).toContain(`bun ${join(SHIP, "env", "setup.ts")}`);
  });

  test("an invalid machine config: the error names that file", () => {
    const root = repo("acme");
    const machineFile = writeMachine(join(tempDir("ship-repo-config-m-"), "m.json"), { principal: ["x"] });
    const error = errorOf(() => repoConfig(root, { SHIP_MACHINE_CONFIG: machineFile }));
    expect(error.message).toContain(`machine config ${machineFile}:`);
  });
});

test("SHIP_BIN is this checkout's bin/ship", () => {
  expect(SHIP_BIN).toBe(join(SHIP, "bin", "ship"));
});
