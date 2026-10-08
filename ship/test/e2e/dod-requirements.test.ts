// harlo-61: a dod-shaped requirements object end to end through `bin/ship`. The real agent-claude adapter serves
// Define (`--requirements dod`) and Check, each over the fake `claude` CLI; every other port is the scripted fake.
// The workspace is a real git repo, so Check's declared-files rule diffs real commits against the Delivery's base.
import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { D, answer, coreSequence, implemented, lifecycle, ok, payloadOf, verdict } from "../fixtures/lifecycle.fixture";
import type { TimedEntry } from "../../src/contracts/snapshot";

const TIMEOUT = 120_000;
const ROOT = join(import.meta.dir, "..", "..");
const CLAUDE = join(ROOT, "src", "adapters", "agent", "claude", "index.ts");
const FAKE_CLAUDE = join(ROOT, "src", "adapters", "agent", "claude", "fake.ts");
const CONTRACT = JSON.parse(readFileSync(join(ROOT, "test", "fixtures", "dod-requirements.json"), "utf8")) as unknown;

const cleanups: (() => void)[] = [];
afterAll(() => {
  for (const cleanup of cleanups.splice(0)) cleanup();
});

const git = (dir: string, ...args: string[]): string => {
  const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${proc.stderr.toString()}`);
  return proc.stdout.toString().trim();
};

/** Commit `files` in the workspace and return the new HEAD. */
const commit = (ws: string, files: Record<string, string>): string => {
  for (const [path, content] of Object.entries(files)) {
    mkdirSync(join(ws, path, ".."), { recursive: true });
    writeFileSync(join(ws, path), content);
  }
  git(ws, "add", "-A");
  git(ws, "commit", "-q", "-m", Object.keys(files).join(", "));
  return git(ws, "rev-parse", "HEAD");
};

/** An `--agent-bin` for the fake CLI: adapters get only PATH and HOME, so the wrapper carries its replies and log. */
const agentBin = (dir: string, name: string, replies: unknown): { bin: string; log: string } => {
  const file = join(dir, `${name}.replies.json`);
  const log = join(dir, `${name}.log.jsonl`);
  writeFileSync(file, JSON.stringify({ replies }));
  const bin = join(dir, `${name}-agent`);
  writeFileSync(bin, `#!/bin/sh\nFAKE_AGENT_REPLIES='${file}' FAKE_AGENT_LOG='${log}' exec bun '${FAKE_CLAUDE}' "$@"\n`);
  chmodSync(bin, 0o755);
  return { bin, log };
};

/** The requirements object every Check prompt carried, parsed back from its `Requirements (full):` line. */
const requirementsInPrompts = (log: string): unknown[] =>
  readFileSync(log, "utf8").trim().split("\n").map((line) => {
    const argv = JSON.parse(line) as string[];
    const prompt = argv[argv.indexOf("-p") + 1]!.split("\n");
    return JSON.parse(prompt[prompt.indexOf("Requirements (full):") + 1]!) as unknown;
  });

const resultOf = (entries: TimedEntry[], suffix: string): unknown => {
  const entry = entries.find((e) => e.signal.kind === "result" && e.signal.id === `${D}/${suffix}`);
  return entry?.signal.kind === "result" ? entry.signal.result : undefined;
};

describe("dod-shaped requirements, Define → Check → Verify (harlo-61)", () => {
  test("harlo-61: e2e: Define emits the dod contract, Check and Verify get it deep-equal, Check enforces doc_paths", async () => {
    const scratch = mkdtempSync(join(tmpdir(), "ship-e2e-dod-"));
    cleanups.push(() => rmSync(scratch, { recursive: true, force: true }));
    const ws = join(scratch, "ws");
    mkdirSync(ws);
    git(ws, "init", "-q", "-b", "main");
    git(ws, "config", "user.email", "t@example.com");
    git(ws, "config", "user.name", "T");
    commit(ws, { "README.md": "hello\n" });
    git(ws, "checkout", "-q", "-b", `ship/${D}`);
    const missesDocs = commit(ws, { "src/greet.ts": "export const greet = (n: string) => `Hello, ${n}`;\n", "README.md": "greet names you\n" });
    const touchesAll = commit(ws, { "docs/greet.md": "# greet\nPrints Hello, <name>.\n" });

    const define = agentBin(scratch, "define", { is_error: false, result: "defined", session_id: "s-def", structured_output: CONTRACT });
    const check = agentBin(scratch, "check", { is_error: false, result: "looks fine", structured_output: { verdict: "pass" } });
    const p = lifecycle({
      "workspace.setup": ok({ path: ws, base: "main" }),
      "implement.run": [implemented(`ship/${D}@${missesDocs}`), implemented(`ship/${D}@${touchesAll}`)],
      "integrate.run": [verdict("landed")], "deploy.run": [verdict("live")], "verify.run": [verdict("pass")],
    }, {}, {
      adapters: {
        define: ["bun", CLAUDE, "--agent-bin", define.bin, "--requirements", "dod"],
        check: ["bun", CLAUDE, "--agent-bin", check.bin],
      },
    });
    cleanups.push(p.cleanup);

    const started = await p.ship("start", "k");
    expect({ exit: started.exit, awaiting: started.out?.awaiting, stderr: started.stderr }).toEqual({ exit: 0, awaiting: `${D}/accept-1`, stderr: "" });
    const accepted = await p.ship("signal", D, `${D}/accept-1`, answer("accept"));
    expect({ exit: accepted.exit, awaiting: accepted.out?.awaiting }).toEqual({ exit: 0, awaiting: `${D}/land-1` });
    const landed = await p.ship("signal", D, `${D}/land-1`, answer("approve"));
    expect({ exit: landed.exit, awaiting: landed.out?.awaiting }).toEqual({ exit: 0, awaiting: null });

    const entries = await p.journal();
    expect(coreSequence(entries)).toContain("result check-1: check→implement");
    expect(coreSequence(entries)).toContain("result check-2: check→land");
    expect((await p.snapshot()).at).toBe("closed");

    // What Define emitted is exactly the fixture contract …
    const emitted = (resultOf(entries, "define-1") as { body: { requirements: unknown } }).body.requirements;
    expect(emitted).toEqual(CONTRACT);
    // … and both Check calls (two passes each) and Verify received that same object, deep-equal.
    const atCheck = requirementsInPrompts(check.log);
    expect(atCheck).toHaveLength(4);
    for (const received of atCheck) expect(received).toEqual(emitted);
    expect((payloadOf(p.log(), "verify-1") as { requirements: unknown }).requirements).toEqual(emitted);

    // Check acted on it: the first changeset never touched docs/greet.md, so fix naming it though the agent said pass …
    const check1 = resultOf(entries, "check-1") as { status: string; body: { verdict: string; findings: { text: string; ref?: string }[] } };
    expect(check1.status).toBe("ok");
    expect(check1.body.verdict).toBe("fix");
    expect(check1.body.findings.map((f) => f.ref)).toEqual(["docs/greet.md"]);
    expect((payloadOf(p.log(), "implement-2") as { findings: unknown }).findings).toEqual(check1.body.findings);
    // … and the second, touching every declared path (README.md and docs/greet.md since main), passes.
    expect((resultOf(entries, "check-2") as { body: unknown }).body).toEqual({ verdict: "pass" });
  }, TIMEOUT);
});
