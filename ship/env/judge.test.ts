// Part 2 of the peaceful-leaping-moonbeam plan: the judge tool, driven through a real Delivery (`bin/ship` +
// fake step/tracker/workspace/principal adapters + the real file State adapter), exactly as
// env/poll/changed.test.ts drives its poller. Define is put through a fix-round rerun (the accept gate's
// "adjust" answer) so both define-1 and define-2 land in the journal distinctly, and Implement's changeset
// points at a real commit in a temp git repo, so the `git show`/`--root` path is genuinely exercised.
import { afterAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { D, lifecycle } from "../test/fixtures/lifecycle.fixture";

const JUDGE = join(import.meta.dir, "judge.ts");

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
      "workspace.setup": { status: "ok", body: { path: "/ws/whatever" } },
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
    expect(define1).toContain("-- INPUT --\n{}");
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
      "workspace.setup": { status: "ok", body: { path: "/ws/whatever" } },
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
});
