// Part 2 of the peaceful-leaping-moonbeam plan: the judge tool, driven through a real Delivery (`bin/ship` +
// fake step/tracker/workspace/principal adapters + the real file State adapter), exactly as
// env/poll/changed.test.ts drives its poller. Define is put through a fix-round rerun (the accept gate's
// "adjust" answer) so both define-1 and define-2 land in the journal distinctly, and Implement's changeset
// points at a real commit in a temp git repo, so the `git show`/`--root` path is genuinely exercised.
import { afterAll, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { D, lifecycle } from "../test/fixtures/lifecycle.fixture";

const JUDGE = join(import.meta.dir, "judge.ts");
const STATE = join(import.meta.dir, "..", "src", "adapters", "state", "files.ts");
const AGENT = join(import.meta.dir, "..", "src", "adapters", "agent", "claude", "index.ts");
const FAKE_CLI = join(import.meta.dir, "..", "src", "adapters", "agent", "claude", "fake.ts");

type Project = ReturnType<typeof lifecycle>;
const projects: Project[] = [];
const dirs: string[] = [];
afterAll(() => {
  for (const p of projects.splice(0)) p.cleanup();
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
const project = (...args: Parameters<typeof lifecycle>): Project => {
  const p = lifecycle(...args);
  projects.push(p);
  return p;
};

/** A real git repo with one commit, standing in for the Implement workspace's main-line repo (`--root`). */
const gitRepo = (): { dir: string; sha: string } => {
  const dir = mkdtempSync(join(tmpdir(), "ship-judge-ws-"));
  dirs.push(dir);
  const git = (...cmdArgs: string[]): string => {
    const proc = Bun.spawnSync(["git", "-C", dir, ...cmdArgs], { stdout: "pipe", stderr: "pipe" });
    if (proc.exitCode !== 0) throw new Error(`git ${cmdArgs.join(" ")}: ${proc.stderr.toString()}`);
    return proc.stdout.toString().trim();
  };
  git("init", "-q", "-b", "main");
  git("config", "user.email", "t@example.com");
  git("config", "user.name", "T");
  writeFileSync(join(dir, "README.md"), "hello judge\n");
  git("add", "-A");
  git("commit", "-q", "-m", "real implement commit");
  return { dir, sha: git("rev-parse", "HEAD") };
};

const okE = (body: Record<string, unknown>, reasoning: string) =>
  ({ status: "ok", body, evidence: [{ label: "reasoning", text: reasoning }] });
const answer = (text: string, comment?: string) =>
  JSON.stringify({ status: "ok", body: { answer: text, by: "person", ...(comment === undefined ? {} : { comment }) } });

const HAPPY_NO_USAGE = {
  "workspace.setup": { status: "ok", body: { path: "/ws/whatever", base: "trunk" } },
  "define.run": [{ status: "ok", body: { criteria: ["c"], runbook: ["r"] } }],
};

const runJudge = async (
  p: Project, delivery: string, opts: { root?: string; step?: string } = {},
): Promise<{ exitCode: number; stdout: string; stderr: string }> => {
  const proc = Bun.spawn(
    [
      "bun", JUDGE, "--delivery", delivery,
      ...(opts.root ? ["--root", opts.root] : []),
      ...(opts.step ? ["--step", opts.step] : []),
      "--state", ...p.stateArgv,
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { exitCode, stdout, stderr };
};

describe("env/judge", () => {
  test("renders INPUT/OUTPUT/REASONING per step-call, including a Define fix-round rerun and a real `git show`", async () => {
    const ws = gitRepo();
    const changeset = `ship/${D}@${ws.sha}`;

    const p = project({
      "workspace.setup": { status: "ok", body: { path: "/ws/whatever", base: "trunk" } },
      "define.run": [
        okE({ criteria: ["c1"], runbook: ["r1"] }, "reasoning-define-1"),
        okE({ criteria: ["c2"], runbook: ["r2"] }, "reasoning-define-2"),
      ],
      "implement.run": [okE({ changeset }, "reasoning-implement-1")],
      "check.run": [okE({ verdict: "pass" }, "reasoning-check-1")],
      "integrate.run": [{ status: "ok", body: { verdict: "landed" } }],
      "deploy.run": [{ status: "ok", body: { verdict: "live" } }],
      "verify.run": [{ status: "ok", body: { verdict: "pass" } }],
    });

    // start -> setup -> define-1 -> accept-1 (awaited)
    const started = await p.ship("start", "k");
    expect(started.out).toMatchObject({ awaiting: `${D}/accept-1` });

    // adjust: define re-entered with feedback -> define-2 -> accept-2 (awaited)
    const adjusted = await p.ship("signal", D, `${D}/accept-1`, answer("adjust", "please refine this"));
    expect(adjusted.out).toMatchObject({ awaiting: `${D}/accept-2` });

    // accept: implement-1 -> check-1 -> land-1 (awaited)
    const accepted = await p.ship("signal", D, `${D}/accept-2`, answer("accept"));
    expect(accepted.out).toMatchObject({ awaiting: `${D}/land-1` });

    // approve: integrate -> deploy -> verify -> close -> teardown -> closed
    const approved = await p.ship("signal", D, `${D}/land-1`, answer("approve"));
    expect(approved.out).toMatchObject({ awaiting: null });
    expect((await p.snapshot()).at).toBe("closed");

    const ran = await runJudge(p, D, { root: ws.dir });
    expect(ran.stderr).toBe("");
    expect(ran.exitCode).toBe(0);
    const out = ran.stdout;

    // define-1 and define-2 are both present, distinctly, each with its own input/output/reasoning.
    const define1 = out.slice(out.indexOf(`=== ${D}/define-1 ===`), out.indexOf(`=== ${D}/define-2 ===`));
    const define2 = out.slice(out.indexOf(`=== ${D}/define-2 ===`), out.indexOf(`=== ${D}/accept-2 ===`));
    expect(define1).toContain("-- INPUT --\n{\n  \"base\": \"trunk\"\n}");
    expect(define1).toContain("Criteria:\n  - c1");
    expect(define1).toContain("Runbook:\n  - r1");
    expect(define1).toContain("-- REASONING --\nreasoning: reasoning-define-1");

    expect(define2).toContain(`"feedback": "please refine this"`);
    expect(define2).toContain("Criteria:\n  - c2");
    expect(define2).toContain("Runbook:\n  - r2");
    expect(define2).toContain("-- REASONING --\nreasoning: reasoning-define-2");

    // implement-1: input carries the latest (define-2) criteria, output shows the changeset and a real `git show`.
    const implement1 = out.slice(out.indexOf(`=== ${D}/implement-1 ===`), out.indexOf(`=== ${D}/check-1 ===`));
    expect(implement1).toContain(`"c2"`);
    expect(implement1).toContain(`Changeset: ${changeset}`);
    expect(implement1).toContain("real implement commit"); // the real `git show <sha>` body
    expect(implement1).toContain("-- REASONING --\nreasoning: reasoning-implement-1");

    // check-1: verdict + reasoning.
    const rest = out.slice(out.indexOf(`=== ${D}/check-1 ===`));
    expect(rest).toContain("Verdict: pass");
    expect(rest).toContain("-- REASONING --\nreasoning: reasoning-check-1");

    // --step filters to just that step's calls, all sequences, nothing else.
    const defineOnly = await runJudge(p, D, { step: "define" });
    expect(defineOnly.exitCode).toBe(0);
    expect(defineOnly.stdout).toContain(`=== ${D}/define-1 ===`);
    expect(defineOnly.stdout).toContain(`=== ${D}/define-2 ===`);
    expect(defineOnly.stdout).not.toContain(`=== ${D}/implement-1 ===`);
    expect(defineOnly.stdout).not.toContain(`=== ${D}/check-1 ===`);
  }, 30_000);

  test("no --root: implement's changeset is shown without attempting `git show`", async () => {
    const p = project({
      "workspace.setup": { status: "ok", body: { path: "/ws/whatever", base: "trunk" } },
      "define.run": [{ status: "ok", body: { criteria: ["c"], runbook: ["r"] } }],
      "implement.run": [{ status: "ok", body: { changeset: `ship/${D}@deadbeef` } }],
      "check.run": [{ status: "ok", body: { verdict: "pass" } }],
      "integrate.run": [{ status: "ok", body: { verdict: "landed" } }],
      "deploy.run": [{ status: "ok", body: { verdict: "live" } }],
      "verify.run": [{ status: "ok", body: { verdict: "pass" } }],
    });
    await p.ship("start", "k");
    await p.ship("signal", D, `${D}/accept-1`, answer("accept"));

    const ran = await runJudge(p, D, { step: "implement" });
    expect(ran.exitCode).toBe(0);
    expect(ran.stdout).toContain(`Changeset: ship/${D}@deadbeef`);
    expect(ran.stdout).not.toContain("commit not reachable");
  }, 30_000);

  describe("usage per step-call (harlo-56)", () => {
    /** A real git repo checked out on `ship/<D>`, as workspace.setup leaves a Delivery workspace. */
    const workspace = (): string => {
      const { dir } = gitRepo();
      Bun.spawnSync(["git", "-C", dir, "checkout", "-q", "-b", `ship/${D}`]);
      return dir;
    };
    /** Puts the real claude adapter on define/implement/check, its --agent-bin a wrapper around the fake CLI. */
    const withAgent = (p: Project, replies: unknown[]): void => {
      const repliesFile = join(p.dir, "agent-replies.json");
      writeFileSync(repliesFile, JSON.stringify({ replies }));
      const bin = join(p.dir, "fake-claude");
      writeFileSync(bin, `#!/bin/sh\nFAKE_AGENT_REPLIES='${repliesFile}' exec bun '${FAKE_CLI}' "$@"\n`);
      chmodSync(bin, 0o755);
      const configFile = join(p.dir, "ship.config.json");
      const config = JSON.parse(readFileSync(configFile, "utf8")) as { adapters: Record<string, string[]> };
      for (const port of ["define", "implement", "check"]) config.adapters[port] = ["bun", AGENT, "--agent-bin", bin];
      writeFileSync(configFile, JSON.stringify(config));
    };
    const usage = (n: number, cost: number) => ({
      usage: { input_tokens: n, output_tokens: n * 2, cache_read_input_tokens: n * 3, cache_creation_input_tokens: n * 4 },
      total_cost_usd: cost, duration_ms: n * 1000, num_turns: n,
    });
    const block = (out: string, id: string): string => {
      const start = out.indexOf(`=== ${D}/${id} ===`);
      expect(start).not.toBe(-1);
      const end = out.indexOf("\n=== ", start + 1);
      return out.slice(start, end === -1 ? undefined : end);
    };

    test("every step-call's usage is journaled and rendered, crashed ones included, then totalled", async () => {
      const p = project({ "workspace.setup": { status: "ok", body: { path: workspace(), base: "main" } } });
      withAgent(p, [
        // define-1: ok
        { is_error: false, result: "r-define", session_id: "s-def", structured_output: { criteria: ["c"], runbook: ["r"] }, ...usage(1, 0.1) },
        // implement-1: finished without a commit -> failed, retried as implement-2
        { is_error: false, result: "r-impl-1", session_id: "s-impl", ...usage(2, 0.2) },
        // implement-2: commits -> ok (a fresh session: no delta in its payload)
        { is_error: false, result: "r-impl-2", session_id: "s-impl", commit: true, ...usage(3, 0.3) },
        // check-1: fix -> implement-3, resuming s-impl
        { is_error: false, result: "r-check", structured_output: { verdict: "fix", findings: [{ text: "f" }] }, ...usage(4, 0.4) },
        // implement-3: is_error after a commit -> crash; session total 0.75 is 0.45 for this call
        { is_error: true, result: "boom", session_id: "s-impl", commit: true, ...usage(5, 0.75) },
      ]);

      await p.ship("start", "k");
      const crashed = await p.ship("signal", D, `${D}/accept-1`, answer("accept"));
      expect(crashed.exit).toBe(5); // the awaited adapter crashed

      // The journal itself: a usage item in each step-call's `result`, the usage line in the crash's info.
      const entries = await p.journal();
      const usageIn = (id: string) => {
        const entry = entries.find((e) => e.signal.kind === "result" && e.signal.id === `${D}/${id}`);
        const result = entry?.signal.kind === "result" ? entry.signal.result : undefined;
        return result?.evidence?.find((e) => e.label === "usage")?.usage;
      };
      expect(usageIn("define-1")).toMatchObject({ inputTokens: 1, costUsd: 0.1 });
      expect(usageIn("implement-1")).toMatchObject({ inputTokens: 2, costUsd: 0.2 });
      expect(usageIn("implement-2")).toMatchObject({ inputTokens: 3, costUsd: 0.3 });
      expect(usageIn("check-1")).toMatchObject({ inputTokens: 4, costUsd: 0.4 });
      const crash = entries.find((e) => e.signal.kind === "adapter_error" && e.signal.id === `${D}/implement-3`);
      expect(crash?.info?.trimEnd().split("\n").at(-1)).toBe(
        `ship-usage: ${JSON.stringify({ inputTokens: 5, outputTokens: 10, cacheReadTokens: 15, cacheCreationTokens: 20, costUsd: 0.45, durationMs: 5000, turns: 5 })}`,
      );

      const ran = await runJudge(p, D);
      expect(ran.stderr).toBe("");
      expect(ran.exitCode).toBe(0);
      const out = ran.stdout;

      // ok: REASONING stays the reasoning only; USAGE is its own section.
      expect(block(out, "define-1")).toContain(
        "-- REASONING --\nreasoning: r-define\n-- USAGE --\ninput tokens: 1\noutput tokens: 2\ncache-read tokens: 3\n"
          + "cache-write tokens: 4\ncost: $0.1000\nduration: 1.0s\nturns: 1",
      );
      // failed
      const failed = block(out, "implement-1");
      expect(failed).toContain("failed: agent finished without committing any changes");
      expect(failed).not.toContain("-- REASONING --");
      expect(failed).toContain("-- USAGE --\ninput tokens: 2\n");
      // crashed: listed with no `result` entry, usage from the info's last line, not echoed in OUTPUT
      const crashBlock = block(out, "implement-3");
      expect(crashBlock).toContain("crashed (adapter_error):");
      expect(crashBlock).toContain("agent reported is_error after a commit");
      expect(crashBlock).not.toContain("ship-usage:");
      expect(crashBlock).toContain("-- USAGE --\ninput tokens: 5\noutput tokens: 10\ncache-read tokens: 15\n"
        + "cache-write tokens: 20\ncost: $0.4500\nduration: 5.0s\nturns: 5");
      // the gate's answer has no usage
      expect(block(out, "accept-1")).toContain("-- USAGE --\n(none)");

      // total: every call with usage, whatever its outcome; setup-1 and the accept gate are the calls without.
      const total = out.slice(out.indexOf(`=== TOTAL ${D} ===`));
      expect(total).toContain("input tokens: 15\noutput tokens: 30\ncache-read tokens: 45\ncache-write tokens: 60\n"
        + "cost: $1.4500\nduration: 15.0s\nturns: 15");
      expect(total).toContain("calls: 7 (5 with usage, 2 without usage data)");

      // --step: the total covers only the filtered calls (implement-1 failed, implement-2 ok, implement-3 crashed).
      const implementOnly = await runJudge(p, D, { step: "implement" });
      const filtered = implementOnly.stdout.slice(implementOnly.stdout.indexOf(`=== TOTAL ${D} ===`));
      expect(filtered).toContain("input tokens: 10\n");
      expect(filtered).toContain("cost: $0.9500\n");
      expect(filtered).toContain("calls: 3 (3 with usage, 0 without usage data)");
    }, 60_000);

    test("a journal with no usage anywhere renders (none) and a zero-usage total without crashing", async () => {
      const p = project(HAPPY_NO_USAGE);
      await p.ship("start", "k");
      const ran = await runJudge(p, D, { step: "define" });
      expect(ran.exitCode).toBe(0);
      expect(ran.stdout).toContain("-- USAGE --\n(none)");
      expect(ran.stdout).toContain(`=== TOTAL ${D} ===\n-- USAGE --\n(none)\ncalls: 1 (0 with usage, 1 without usage data)`);
    }, 30_000);
  });
});

describe("env/judge from a set-up repo (no plumbing flags)", () => {
  /** `bun judge.ts <args…>` from `cwd`, the machine config found as ship finds it. */
  const judge = async (p: Project, args: string[], cwd: string, machine = join(p.dir, "machine.json")) => {
    const proc = Bun.spawn(["bun", JUDGE, ...args], {
      cwd, env: { PATH: process.env.PATH ?? "", HOME: p.dir, SHIP_MACHINE_CONFIG: machine },
      stdout: "pipe", stderr: "pipe",
    });
    const [stdout, stderr, exitCode] = await Promise.all([
      new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
    ]);
    return { exitCode, stdout, stderr };
  };
  /** The lifecycle project made a git repo with one commit; returns that commit's sha. */
  const gitInit = (p: Project): string => {
    const git = (...cmdArgs: string[]) =>
      Bun.spawnSync(["git", "-C", p.dir, ...cmdArgs], { stdout: "pipe", stderr: "pipe" }).stdout.toString().trim();
    git("init", "-q", "-b", "main");
    git("config", "user.email", "t@example.com");
    git("config", "user.name", "T");
    writeFileSync(join(p.dir, "README.md"), "hello repo\n");
    git("add", "README.md");
    git("commit", "-q", "-m", "commit in the repo itself");
    return git("rev-parse", "HEAD");
  };
  const elsewhere = (): string => {
    const dir = mkdtempSync(join(tmpdir(), "ship-judge-cwd-"));
    dirs.push(dir);
    return dir;
  };

  test("no delivery: lists every Delivery, closed/abandoned included, most recent first, exit 0", async () => {
    const defined = { status: "ok", body: { criteria: ["c"], runbook: ["r"] } };
    const p = project({ ...HAPPY_NO_USAGE, "define.run": [defined, defined] }); // one Define per Delivery
    gitInit(p);
    await p.ship("start", "k"); // k-1, parked at accept-1
    await p.ship("stop", "k-1", "abandoned", "not wanted");
    expect((await p.ship("start", "k")).out).toMatchObject({ delivery: "k-2" });

    const ran = await judge(p, [], p.dir);
    expect(ran.stderr).toBe("");
    expect(ran.exitCode).toBe(0);
    const lines = ran.stdout.trim().split("\n");
    expect(lines).toHaveLength(2);
    const TIME = "\\d{4}-\\d\\d-\\d\\dT[\\d:.]+Z";
    expect(lines[0]).toMatch(new RegExp(`^k-2 +at=accept +last=${TIME}$`));
    expect(lines[1]).toMatch(new RegExp(`^k-1 +at=abandoned +outcome=abandoned +last=${TIME}$`));

    // the same list through the --state override, from outside any repo
    const viaState = await judge(p, ["--state", ...p.stateArgv], elsewhere());
    expect(viaState.exitCode).toBe(0);
    expect(viaState.stdout).toBe(ran.stdout);
  }, 30_000);

  test("no Deliveries yet: one clear line, exit 0", async () => {
    const p = project(HAPPY_NO_USAGE);
    gitInit(p);
    const ran = await judge(p, ["--repo", p.dir], elsewhere());
    expect(ran.exitCode).toBe(0);
    expect(ran.stdout.trim()).toBe("no Deliveries");
  }, 30_000);

  test("a positional delivery with --repo from elsewhere; --root defaults to the repo, so `git show` runs", async () => {
    const p = project({ ...HAPPY_NO_USAGE, "implement.run": [{ status: "ok", body: { changeset: "pending" } }] });
    const sha = gitInit(p);
    p.rescript({ "implement.run": [{ status: "ok", body: { changeset: `ship/${D}@${sha}` } }] });
    await p.ship("start", "k");
    await p.ship("signal", D, `${D}/accept-1`, answer("accept"));

    const ran = await judge(p, ["--repo", p.dir, D, "--step", "implement"], elsewhere());
    expect(ran.stderr).toBe("");
    expect(ran.exitCode).toBe(0);
    expect(ran.stdout).toContain(`=== ${D}/implement-1 ===`);
    expect(ran.stdout).toContain("commit in the repo itself"); // the real `git show`, no --root given
    expect(ran.stdout).not.toContain(`=== ${D}/define-1 ===`);
  }, 30_000);

  test("a repo with no ship.config.json: exit 1, the error names the file and suggests setup.ts", async () => {
    const p = project(HAPPY_NO_USAGE);
    const bare = elsewhere();
    Bun.spawnSync(["git", "init", "-q", bare]);
    const ran = await judge(p, ["--repo", bare], p.dir);
    expect(ran.exitCode).toBe(1);
    expect(ran.stderr).toContain("ship.config.json");
    expect(ran.stderr).toContain("env/setup.ts");
    expect(ran.stderr).not.toContain("    at "); // a message, not a stack trace
  }, 30_000);

  test("a relative state argv in the machine config runs from the repo root, as ship runs it", async () => {
    const p = project(HAPPY_NO_USAGE);
    gitInit(p);
    await p.ship("start", "k"); // k-1 in <repo>/state
    const machine = join(p.dir, "relative-machine.json");
    writeFileSync(machine, JSON.stringify({ principal: ["true"], state: ["bun", STATE, "--dir", "state"] }));

    const ran = await judge(p, ["--repo", p.dir], elsewhere(), machine); // the cwd has no `state` dir
    expect(ran.stderr).toBe("");
    expect(ran.exitCode).toBe(0);
    expect(ran.stdout).toContain("k-1");
  }, 30_000);

  test.each(["--repo", "--delivery", "--root", "--step"])("a trailing %s with no value says it needs one", async (flag) => {
    const p = project(HAPPY_NO_USAGE);
    const ran = await judge(p, [flag], p.dir);
    expect(ran.exitCode).toBe(1);
    expect(ran.stderr).toContain(`${flag} needs a value`);
    expect(ran.stderr).not.toContain("unknown or extra");
  }, 30_000);
});
