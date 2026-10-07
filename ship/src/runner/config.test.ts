// M0.16: loading the project and machine config layers (plan §3.5).
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Policy } from "../core/types";
import { type Config, ConfigError, loadConfig } from "./config";

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-config-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

type Json = Record<string, any>;

const project = (): Json => ({
  projectId: "harlo",
  adapters: {
    tracker: ["bun", "adapters/tracker-md.ts", "--dir", "~/notes/harlo"],
    workspace: ["bun", "adapters/workspace-worktree.ts"],
    define: ["bun", "adapters/fake.ts"], implement: ["bun", "adapters/fake.ts"], check: ["bun", "adapters/fake.ts"],
    integrate: ["bun", "adapters/integrate.ts"], deploy: ["bun", "adapters/fake.ts"], verify: ["bun", "adapters/fake.ts"],
  },
  policy: {
    tracker: {
      outcomes: {
        delivered: { status: "done" },
        accepted_with_failure: { status: "done", comment: true },
        rolled_back: { status: "reopened", comment: true },
        abandoned: { comment: true },
      },
    },
  },
});
const machine = (): Json => ({
  principal: ["bun", "adapters/principal/index.ts"],
  state: ["bun", "adapters/state/files.ts", "--dir", "~/.local/state/ship/harlo"],
  secrets: { GH: { env: "GH_TOKEN" } },
  capabilities: { integrate: { env: { GH_TOKEN: "$secrets.GH", MODE: "plain" }, tools: ["git", "gh"] } },
});

/** Write both layers into a temp repo and load them, the machine layer via $SHIP_MACHINE_CONFIG. */
const load = (projectJson: Json | string, machineJson: Json | string, env: Record<string, string> = {}): Config => {
  const repo = tempDir();
  const text = (x: Json | string) => (typeof x === "string" ? x : JSON.stringify(x));
  writeFileSync(join(repo, "ship.config.json"), text(projectJson));
  writeFileSync(join(repo, "machine.json"), text(machineJson));
  return loadConfig(repo, { SHIP_MACHINE_CONFIG: join(repo, "machine.json"), GH_TOKEN: "secret-value", ...env });
};

const defaultPolicy: Policy = {
  fixRounds: 2,
  retryCap: { default: 1 },
  maxBlockedRetries: 3,
  minimum: {
    accept: "person", land: "person", failure: "person", blocked: "person",
    decision: { scope: "person", advisory: "model" },
    question: {},
  },
  outcomes: ["rolled_back", "abandoned"],
  tracker: { steps: {}, outcomes: project().policy.tracker.outcomes },
};

describe("valid", () => {
  test("defaults fill the Policy; secrets resolve into the port's profile env; every port has an adapter", () => {
    const config = load(project(), machine());
    expect(config.projectId).toBe("harlo");
    expect(config.policy).toEqual(defaultPolicy);
    expect(config.adapters.integrate).toEqual({
      argv: ["bun", "adapters/integrate.ts"], env: { GH_TOKEN: "secret-value", MODE: "plain" }, tools: ["git", "gh"],
    });
    expect(config.adapters.principal).toEqual({ argv: ["bun", "adapters/principal/index.ts"], env: {}, tools: [] });
    expect(config.adapters.state.argv).toEqual(machine().state);
    expect(Object.keys(config.adapters).sort()).toEqual([
      "check", "define", "deploy", "implement", "integrate", "principal", "state", "tracker", "verify", "workspace",
    ]);
  });

  test("a full policy (the §3.5 example) is taken as written", () => {
    const full = project();
    full.policy = {
      fixRounds: 3,
      retryCap: { default: 1, deploy: 0 },
      maxBlockedRetries: 3,
      minimum: {
        accept: "person", land: "person", failure: "person", blocked: "model",
        decision: { scope: "person", advisory: "model" },
        question: { clarify: "model", login: "person" },
      },
      outcomes: ["rolled_back", "abandoned"],
      tracker: { steps: { implement: "in_progress" }, outcomes: project().policy.tracker.outcomes },
    };
    expect(load(full, machine()).policy).toEqual(full.policy as Policy);
  });

  test("a partial minimum keeps the other defaults", () => {
    const partial = project();
    partial.policy.minimum = { decision: { advisory: "person" }, question: { clarify: "model" } };
    expect(load(partial, machine()).policy.minimum).toEqual({
      ...defaultPolicy.minimum, decision: { scope: "person", advisory: "person" }, question: { clarify: "model" },
    });
  });

  test("a machine config without `telemetry` loads with telemetry: null", () => {
    const config = load(project(), machine());
    expect(config.telemetry).toBeNull();
  });

  test("a machine config with `telemetry` loads it as an adapter spec", () => {
    const withTelemetry = { ...machine(), telemetry: ["bun", "adapters/telemetry/tty.ts"] };
    const config = load(project(), withTelemetry);
    expect(config.telemetry).toEqual({ argv: ["bun", "adapters/telemetry/tty.ts"], env: {}, tools: [] });
  });

  test("without $SHIP_MACHINE_CONFIG the machine layer is ~/.config/ship/<projectId>.json", () => {
    const repo = tempDir();
    const home = tempDir();
    writeFileSync(join(repo, "ship.config.json"), JSON.stringify(project()));
    mkdirSync(join(home, ".config", "ship"), { recursive: true });
    writeFileSync(join(home, ".config", "ship", "harlo.json"), JSON.stringify(machine()));
    expect(loadConfig(repo, { HOME: home, GH_TOKEN: "t" }).adapters.integrate.env.GH_TOKEN).toBe("t");
  });
});

describe("invalid: a ConfigError (the CLI's exit 2)", () => {
  const with_ = (base: () => Json, change: (x: Json) => void) => () => {
    const x = base();
    change(x);
    return x;
  };
  const rows: { name: string; project: () => Json | string; machine: () => Json | string; env?: Record<string, string>; message: string }[] = [
    { name: "cross-layer key: principal in the project layer", project: with_(project, (p) => { p.principal = ["x"]; }), machine, message: "principal" },
    { name: "cross-layer key: policy in the machine layer", project, machine: with_(machine, (m) => { m.policy = {}; }), message: "policy" },
    { name: "unknown port in adapters", project: with_(project, (p) => { p.adapters.deployy = ["x"]; }), machine, message: "deployy" },
    { name: "unknown port in capabilities", project, machine: with_(machine, (m) => { m.capabilities.deployy = {}; }), message: "deployy" },
    { name: "missing key: project adapters.verify", project: with_(project, (p) => { delete p.adapters.verify; }), machine, message: "verify" },
    { name: "missing key: machine state", project, machine: with_(machine, (m) => { delete m.state; }), message: "state" },
    { name: "undeclared $secrets", project, machine: with_(machine, (m) => { m.capabilities.integrate.env.GH_TOKEN = "$secrets.NOPE"; }), message: "$secrets.NOPE" },
    { name: "declared secret whose env var is unset", project, machine, env: { GH_TOKEN: "" }, message: "GH_TOKEN" },
    { name: "missing delivered.status", project: with_(project, (p) => { p.policy.tracker.outcomes.delivered = { comment: true }; }), machine, message: "delivered" },
    { name: "missing accepted_with_failure.status", project: with_(project, (p) => { delete p.policy.tracker.outcomes.accepted_with_failure; }), machine, message: "accepted_with_failure" },
    { name: "an outcome without a tracker mapping", project: with_(project, (p) => { p.policy.outcomes = ["rolled_back", "abandoned", "paused"]; }), machine, message: "paused" },
    { name: "a default outcome without a tracker mapping", project: with_(project, (p) => { delete p.policy.tracker.outcomes.abandoned; }), machine, message: "abandoned" },
    { name: "a stop outcome without comment: true", project: with_(project, (p) => { p.policy.tracker.outcomes.rolled_back = { status: "reopened" }; }), machine, message: "policy.tracker.outcomes.rolled_back.comment" },
    { name: "a stop outcome with comment: false", project: with_(project, (p) => { p.policy.tracker.outcomes.abandoned = { comment: false }; }), machine, message: "policy.tracker.outcomes.abandoned.comment" },
    { name: "project file is not JSON", project: () => "{nope", machine, message: "ship.config.json" },
  ];
  test.each(rows)("$name", ({ project: p, machine: m, env, message }) => {
    const attempt = () => load(p(), m(), env);
    expect(attempt).toThrow(ConfigError);
    expect(attempt).toThrow(message);
  });

  test("a missing machine file", () => {
    const repo = tempDir();
    writeFileSync(join(repo, "ship.config.json"), JSON.stringify(project()));
    expect(() => loadConfig(repo, { SHIP_MACHINE_CONFIG: join(repo, "absent.json") })).toThrow(ConfigError);
  });
});
