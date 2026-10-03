// env/setup.ts driven as a real subprocess against temp git repos, with HOME overridden to a temp dir so nothing
// touches the real home. The written configs are proven by loading them in the real `bin/ship` (`ship status`).
import { afterAll, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { runPty } from "../test/fixtures/pty";

const SHIP = join(import.meta.dir, "..");
const BIN = join(SHIP, "bin", "ship");
const SETUP = join(import.meta.dir, "setup.ts");
const adapter = (path: string): string => join(SHIP, "src", "adapters", path);

const temps: string[] = [];
afterAll(() => {
  for (const dir of temps.splice(0)) rmSync(dir, { recursive: true, force: true });
});
const tempDir = (prefix: string): string => {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), prefix)));
  temps.push(dir);
  return dir;
};

const git = (dir: string, ...args: string[]): string => {
  const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${proc.stderr.toString()}`);
  return proc.stdout.toString().trim();
};

type Fixture = { root: string; home: string; id: string };

/** A temp git repo with one commit on `branch`, optionally an `origin`, and its own temp HOME. */
const repo = ({ branch = "main", origin }: { branch?: string; origin?: string } = {}): Fixture => {
  const root = tempDir("ship-setup-");
  git(root, "init", "-q", "-b", branch);
  git(root, "config", "user.email", "t@example.com");
  git(root, "config", "user.name", "T");
  git(root, "commit", "-q", "--allow-empty", "-m", "init");
  if (origin) git(root, "remote", "add", "origin", origin);
  return { root, home: tempDir("ship-setup-home-"), id: basename(root) };
};

const env = (home: string): Record<string, string> => ({ PATH: process.env.PATH ?? "", HOME: home, USER: "tester" });

const setup = (f: { root: string; home: string }, ...args: string[]) => {
  const proc = Bun.spawnSync(["bun", SETUP, ...args], { cwd: f.root, env: env(f.home), stdout: "pipe", stderr: "pipe" });
  return { exit: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
};

const machinePath = (f: Fixture, id = f.id): string => join(f.home, ".config", "ship", `${id}.json`);
const readJson = (path: string) => JSON.parse(readFileSync(path, "utf8"));
const project = (f: Fixture) => readJson(join(f.root, "ship.config.json"));

/** `ship status` from the repo root with the machine config found at its default HOME path, as `ship` does. */
const shipStatus = (f: Fixture) => {
  const proc = Bun.spawnSync([BIN, "status"], { cwd: f.root, env: env(f.home), stdout: "pipe", stderr: "pipe" });
  return { exit: proc.exitCode, stdout: proc.stdout.toString().trim(), stderr: proc.stderr.toString() };
};

const excludeLines = (f: Fixture): string[] =>
  readFileSync(join(f.root, ".git", "info", "exclude"), "utf8").split("\n").filter((line) => line === ".ship/");

describe("env/setup.ts", () => {
  test("--yes on a repo without a GitHub remote: md tracker, detected branch, valid configs, queue command", () => {
    const f = repo({ branch: "trunk" });
    const ran = setup(f, "--yes");
    expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: expect.any(String) });

    const trackerDir = join(f.home, ".local", "state", "ship", f.id, "tracker");
    const stateDir = join(f.home, ".local", "state", "ship", f.id, "state");
    const config = project(f);
    expect(config.projectId).toBe(f.id);
    expect(config.adapters).toEqual({
      tracker: ["bun", adapter("tracker/md.ts"), "--dir", trackerDir],
      workspace: ["bun", adapter("workspace/worktree.ts"), "--main", "trunk", "--root", join(f.root, ".ship", "worktrees")],
      define: ["bun", adapter("agent/claude/index.ts")],
      implement: ["bun", adapter("agent/claude/index.ts")],
      check: ["bun", adapter("agent/claude/index.ts")],
      integrate: ["bun", adapter("integrate/local.ts"), "--root", f.root],
      deploy: ["bun", adapter("ask/principal/index.ts")],
      verify: ["bun", adapter("ask/principal/index.ts")],
    });
    expect(config.policy.tracker.outcomes).toEqual({
      delivered: { status: "done", comment: true }, accepted_with_failure: { status: "done", comment: true },
      rolled_back: { status: "in_progress", comment: true }, abandoned: { comment: true },
    });
    expect(existsSync(trackerDir)).toBe(true);
    expect(existsSync(stateDir)).toBe(true);

    expect(readJson(machinePath(f))).toEqual({
      principal: ["bun", adapter("principal/tty.ts")],
      state: ["bun", adapter("state/files.ts"), "--dir", stateDir],
      capabilities: {
        define: { env: { USER: "tester" } }, implement: { env: { USER: "tester" } }, check: { env: { USER: "tester" } },
      },
    });
    expect(excludeLines(f)).toEqual([".ship/"]);
    expect(ran.stdout).toContain(
      `bun ${join(SHIP, "env", "queue.ts")} --ship ${BIN} --interval 30000 --state bun ${adapter("state/files.ts")} --dir ${stateDir}`,
    );
    expect(ran.stdout).toContain("real terminal");
    expect(shipStatus(f)).toMatchObject({ exit: 0, stdout: '{"deliveries":[]}' });
  });

  test("a GitHub origin defaults to the github tracker in label mode", () => {
    const f = repo({ origin: "git@github.com:acme/widget.git" });
    const ran = setup(f, "--yes");
    expect(ran.exit).toBe(0);
    const config = project(f);
    expect(config.adapters.tracker).toEqual([
      "bun", adapter("tracker/github.ts"), "--repo", "acme/widget", "--ready-label", "ready", "--status-labels", "in_progress,done",
    ]);
    expect(config.policy.tracker.outcomes.delivered).toEqual({ status: "done", comment: true });
    expect(shipStatus(f)).toMatchObject({ exit: 0, stdout: '{"deliveries":[]}' });
  });

  test("--tracker github with project flags: project-mode argv and Done / In Progress statuses", () => {
    const f = repo({ origin: "https://github.com/acme/widget.git" });
    const ran = setup(f, "--yes", "--tracker", "github", "--project", "7", "--project-owner", "acme-org");
    expect(ran.exit).toBe(0);
    const config = project(f);
    expect(config.adapters.tracker).toEqual([
      "bun", adapter("tracker/github.ts"), "--repo", "acme/widget", "--project", "7", "--project-owner", "acme-org",
      "--ready-label", "Todo",
    ]);
    expect(config.policy.tracker).toEqual({
      steps: { define: "In Progress", implement: "In Progress" },
      outcomes: {
        delivered: { status: "Done", comment: true }, accepted_with_failure: { status: "Done", comment: true },
        rolled_back: { status: "In Progress", comment: true }, abandoned: { comment: true },
      },
    });
    expect(shipStatus(f)).toMatchObject({ exit: 0, stdout: '{"deliveries":[]}' });
  });

  test("github label mode: policy statuses come from --status-labels (first in progress, last done)", () => {
    const f = repo({ origin: "git@github.com:acme/widget.git" });
    expect(setup(f, "--yes", "--status-labels", "doing,review,shipped").exit).toBe(0);
    const { policy, adapters } = project(f);
    const tracker: string[] = adapters.tracker;
    const accepted = [...(tracker[tracker.indexOf("--status-labels") + 1] ?? "").split(","), tracker[tracker.indexOf("--ready-label") + 1]];
    expect(policy.tracker.steps).toEqual({ define: "doing", implement: "doing" });
    expect(policy.tracker.outcomes.delivered.status).toBe("shipped");
    const written = [
      ...Object.values(policy.tracker.steps as Record<string, string>),
      ...Object.values(policy.tracker.outcomes as Record<string, { status?: string }>).flatMap((o) => (o.status ? [o.status] : [])),
    ];
    for (const status of written) expect(accepted).toContain(status);
  });

  test("github label mode: fewer than two status labels is refused, nothing written", () => {
    const f = repo({ origin: "git@github.com:acme/widget.git" });
    const ran = setup(f, "--yes", "--status-labels", "done");
    expect(ran.exit).toBe(1);
    expect(ran.stderr).toContain("--status-labels");
    expect(existsSync(join(f.root, "ship.config.json"))).toBe(false);
  });

  test("github project mode: --status-labels names the in-progress and done options", () => {
    const f = repo({ origin: "git@github.com:acme/widget.git" });
    expect(setup(f, "--yes", "--project", "3", "--status-labels", "Doing,Shipped").exit).toBe(0);
    const { policy } = project(f);
    expect(policy.tracker.steps.define).toBe("Doing");
    expect(policy.tracker.outcomes.delivered.status).toBe("Shipped");
  });

  test("--main new:<name> creates the branch from HEAD and uses it as the main line", () => {
    const f = repo();
    const ran = setup(f, "--yes", "--main", "new:release");
    expect(ran.exit).toBe(0);
    expect(git(f.root, "rev-parse", "release")).toBe(git(f.root, "rev-parse", "HEAD"));
    expect(project(f).adapters.workspace).toContain("release");
  });

  test("--main <existing> picks that local branch; an unknown one is an error that writes nothing", () => {
    const f = repo();
    git(f.root, "branch", "dev");
    const bad = setup(f, "--yes", "--main", "nope");
    expect(bad.exit).not.toBe(0);
    expect(bad.stderr).toContain("nope");
    expect(existsSync(join(f.root, "ship.config.json"))).toBe(false);

    const ran = setup(f, "--yes", "--main", "dev");
    expect(ran.exit).toBe(0);
    const workspace: string[] = project(f).adapters.workspace;
    expect(workspace[workspace.indexOf("--main") + 1]).toBe("dev");
  });

  test("--main never prompts: menu words and new without a name are usage errors that write nothing", () => {
    for (const value of ["new", "new:", "choose existing", "choose", "current (main)"]) {
      const f = repo();
      const ran = setupWithInput(f, "", [...allFlagsBut(f, "--main"), "--main", value]);
      expect({ value, exit: ran.exit }).toEqual({ value, exit: 1 });
      expect(ran.stderr).toContain("new:<name>");
      expect(ran.stderr).not.toContain("[");
      expect(existsSync(join(f.root, "ship.config.json"))).toBe(false);
    }
  });

  test("--main <menu word> picks an existing local branch of that name", () => {
    const f = repo();
    git(f.root, "branch", "new");
    expect(setup(f, "--yes", "--main", "new").exit).toBe(0);
    const workspace: string[] = project(f).adapters.workspace;
    expect(workspace[workspace.indexOf("--main") + 1]).toBe("new");
  });

  /** A repo whose `origin` (or `name`) is a real local bare repo. */
  const repoWithRemote = (name = "origin"): Fixture & { remote: string } => {
    const f = repo();
    const remote = tempDir("ship-setup-remote-");
    git(remote, "init", "-q", "--bare");
    git(f.root, "remote", "add", name, remote);
    return { ...f, remote };
  };
  const remoteHas = (remote: string, branch: string): boolean =>
    Bun.spawnSync(["git", "-C", remote, "rev-parse", "--verify", "-q", `refs/heads/${branch}`]).exitCode === 0;
  const upstreamOf = (f: Fixture, branch: string): string => git(f.root, "rev-parse", "--abbrev-ref", `${branch}@{upstream}`);

  test("--main new:<name> --push-main pushes the new main line with upstream", () => {
    const f = repoWithRemote();
    const ran = setup(f, "--yes", "--push-main", "--main", "new:rel");
    expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: "" });
    expect(remoteHas(f.remote, "rel")).toBe(true);
    expect(upstreamOf(f, "rel")).toBe("origin/rel");
  });

  test("--main new:<name> under --yes does not push, and prints the push command", () => {
    const f = repoWithRemote();
    const ran = setup(f, "--yes", "--main", "new:rel");
    expect(ran.exit).toBe(0);
    expect(remoteHas(f.remote, "rel")).toBe(false);
    expect(ran.stderr).toContain("git push -u origin rel");
    expect(ran.stderr).toContain("Integrate");
  });

  test("all flags, no --push-main: no push question, no push", () => {
    const f = repoWithRemote();
    const ran = setupWithInput(f, "", [...allFlagsBut(f, "--main"), "--main", "new:rel"]);
    expect(ran.exit).toBe(0);
    expect(ran.stderr).not.toContain("[y/N]");
    expect(remoteHas(f.remote, "rel")).toBe(false);
  });

  test("answering no to the push question pushes nothing and prints the command", () => {
    const f = repoWithRemote();
    const ran = setupWithInput(f, "\nn\n", [...allFlagsBut(f, "--main", "--project-id"), "--main", "new:rel"]);
    expect(ran.exit).toBe(0);
    expect(ran.stderr).toContain("Push rel to origin with upstream? [y/N]: ");
    expect(ran.stderr).toContain("git push -u origin rel");
    expect(remoteHas(f.remote, "rel")).toBe(false);
  });

  test("without origin the first remote is used", () => {
    const f = repoWithRemote("upstream");
    expect(setup(f, "--yes", "--push-main", "--main", "new:rel").exit).toBe(0);
    expect(upstreamOf(f, "rel")).toBe("upstream/rel");
  });

  test("a failed push is not fatal: configs written, exit 0, the command on stderr", () => {
    const f = repo({ origin: join(tempDir("ship-setup-gone-"), "missing.git") });
    const ran = setup(f, "--yes", "--push-main", "--main", "new:rel");
    expect(ran.exit).toBe(0);
    expect(ran.stderr).toContain("git push -u origin rel");
    expect(ran.stderr).toContain("Integrate");
    expect(shipStatus(f)).toMatchObject({ exit: 0 });
  });

  test("no remote: no push question and nothing about pushing", () => {
    const f = repo();
    const ran = setupWithInput(f, "", [...allFlagsBut(f, "--main"), "--main", "new:rel"]);
    expect({ exit: ran.exit, stderr: ran.stderr }).toEqual({ exit: 0, stderr: "" });
  });

  test("flags of an unchosen tracker or own-path adapter: one warning naming each ignored flag", () => {
    const f = repo();
    const ran = setup(f, "--yes", "--tracker", "md", "--repo", "a/b", "--project", "3", "--state", `path:bun ${adapter("state/files.ts")} --dir ${join(f.home, "s")}`, "--state-dir", "/x");
    expect(ran.exit).toBe(0);
    const warnings = ran.stderr.split("\n").filter((line) => line.startsWith("warning:"));
    expect(warnings).toEqual([expect.stringContaining("--repo")]);
    for (const flag of ["--repo", "--project", "--state-dir"]) expect(warnings[0]).toContain(flag);
    expect(warnings[0]).not.toContain("--tracker-dir");

    const g = repo({ origin: "git@github.com:acme/widget.git" });
    const gh = setup(g, "--yes", "--tracker-dir", "/t");
    expect(gh.stderr).toContain("warning:");
    expect(gh.stderr).toContain("--tracker-dir");
  });

  /** The written integrate `--root`, and the branch checked out there. */
  const integrateRoot = (f: Fixture): { root: string; head: string } => {
    const integrate: string[] = project(f).adapters.integrate;
    const root = integrate[integrate.indexOf("--root") + 1] ?? "";
    return { root, head: git(root, "symbolic-ref", "--short", "HEAD") };
  };

  test("--main new:<name>: Integrate lands in a main-line worktree on that branch", () => {
    const f = repo();
    expect(setup(f, "--yes", "--main", "new:x").exit).toBe(0);
    expect(integrateRoot(f)).toEqual({ root: join(f.root, ".ship", "main-line"), head: "x" });
    expect(git(f.root, "symbolic-ref", "--short", "HEAD")).toBe("main");
  });

  test("--main <existing non-current>: Integrate lands in a main-line worktree on that branch", () => {
    const f = repo();
    git(f.root, "branch", "dev");
    expect(setup(f, "--yes", "--main", "dev").exit).toBe(0);
    expect(integrateRoot(f)).toEqual({ root: join(f.root, ".ship", "main-line"), head: "dev" });
  });

  test("--main current: Integrate --root stays the git root", () => {
    const f = repo();
    expect(setup(f, "--yes", "--main", "current").exit).toBe(0);
    expect(integrateRoot(f)).toEqual({ root: f.root, head: "main" });
  });

  test("a rerun with --force reuses the existing main-line worktree", () => {
    const f = repo();
    git(f.root, "branch", "dev");
    expect(setup(f, "--yes", "--main", "dev").exit).toBe(0);
    const rerun = setup(f, "--yes", "--force", "--main", "dev");
    expect({ exit: rerun.exit, stderr: rerun.stderr }).toEqual({ exit: 0, stderr: "" });
    expect(integrateRoot(f)).toEqual({ root: join(f.root, ".ship", "main-line"), head: "dev" });
  });

  test("a main line already checked out in another worktree is reused there", () => {
    const f = repo();
    const elsewhere = join(tempDir("ship-setup-wt-"), "dev");
    git(f.root, "worktree", "add", "-q", "-b", "dev", elsewhere);
    expect(setup(f, "--yes", "--main", "dev").exit).toBe(0);
    expect(integrateRoot(f)).toEqual({ root: elsewhere, head: "dev" });
    expect(existsSync(join(f.root, ".ship", "main-line"))).toBe(false);
  });

  test("--worktrees overrides the workspace root", () => {
    const f = repo();
    const dir = join(f.home, "wt");
    expect(setup(f, "--yes", "--worktrees", dir).exit).toBe(0);
    const workspace: string[] = project(f).adapters.workspace;
    expect(workspace[workspace.indexOf("--root") + 1]).toBe(dir);
  });

  test("a rerun with --force rewrites the configs and keeps exactly one .ship/ exclude line", () => {
    const f = repo();
    expect(setup(f, "--yes").exit).toBe(0);
    const rerun = setup(f, "--yes", "--force", "--tracker", "md");
    expect(rerun.exit).toBe(0);
    expect(excludeLines(f)).toEqual([".ship/"]);
  });

  test("refuses to overwrite an existing ship.config.json without --force, writing nothing", () => {
    const f = repo();
    const file = join(f.root, "ship.config.json");
    writeFileSync(file, "keep");
    const ran = setup(f, "--yes");
    expect(ran.exit).not.toBe(0);
    expect(ran.stderr).toContain(file);
    expect(readFileSync(file, "utf8")).toBe("keep");
    expect(existsSync(machinePath(f))).toBe(false);
  });

  test("refuses to overwrite an existing machine config without --force, writing nothing", () => {
    const f = repo();
    expect(setup(f, "--yes").exit).toBe(0);
    rmSync(join(f.root, "ship.config.json"));
    writeFileSync(machinePath(f), "keep");
    const ran = setup(f, "--yes");
    expect(ran.exit).not.toBe(0);
    expect(ran.stderr).toContain(machinePath(f));
    expect(readFileSync(machinePath(f), "utf8")).toBe("keep");
    expect(existsSync(join(f.root, "ship.config.json"))).toBe(false);
  });

  test("outside a git repo it is an error", () => {
    const dir = tempDir("ship-setup-nogit-");
    const ran = setup({ root: dir, home: dir }, "--yes");
    expect(ran.exit).not.toBe(0);
    expect(ran.stderr).toContain("git repo");
  });

  test("--help prints usage", () => {
    const f = repo();
    const ran = setup(f, "--help");
    expect(ran.exit).toBe(0);
    expect(ran.stdout).toContain("usage: setup.ts");
  });

  /** Every flag but the ones in `omit`, so setup asks exactly the prompts those leave open. */
  const allFlagsBut = (f: Fixture, ...omit: string[]): string[] => {
    const flags: Record<string, string> = {
      "--tracker": "md", "--tracker-dir": join(f.home, "t"), "--workspace": "worktree", "--main": "current",
      "--worktrees": join(f.home, "wt"), "--define": "claude", "--implement": "claude", "--check": "claude",
      "--integrate": "local", "--deploy": "principal", "--verify": "principal", "--principal": "tty", "--state": "files",
      "--state-dir": join(f.home, "s"), "--project-id": f.id,
    };
    return Object.entries(flags).filter(([flag]) => !omit.includes(flag)).flat();
  };
  const setupWithInput = (f: Fixture, input: string, args: string[]) => {
    const proc = Bun.spawnSync(["bun", SETUP, ...args], { cwd: f.root, env: env(f.home), stdin: Buffer.from(input), stdout: "pipe", stderr: "pipe" });
    return { exit: proc.exitCode, stderr: proc.stderr.toString() };
  };

  test("the tracker menu lists exactly the fully implemented trackers plus own path (no jira)", () => {
    const f = repo();
    const ran = setupWithInput(f, "\n", allFlagsBut(f, "--tracker"));
    expect(ran.exit).toBe(0);
    expect(ran.stderr).toContain("Tracker:\n  1) github\n  2) md (default)\n  3) own path…\nTracker [2]: ");
  });

  test("a single-implementation port lists its one adapter plus own path", () => {
    const f = repo();
    const ran = setupWithInput(f, "\n", allFlagsBut(f, "--workspace"));
    expect(ran.exit).toBe(0);
    expect(ran.stderr).toContain("Workspace:\n  1) worktree (default)\n  2) own path…\nWorkspace [1]: ");
  });

  test("own path: --define 'path:<argv>' and the interactive own-path option write that argv", () => {
    const f = repo();
    const ran = setupWithInput(f, "2\nmy-ws --fast\n", [...allFlagsBut(f, "--workspace", "--define"), "--define", "path:bun /x/agent.ts --quick"]);
    expect({ exit: ran.exit, stderr: ran.stderr }).toMatchObject({ exit: 0 });
    expect(ran.stderr).toContain("Workspace adapter argv [");
    const { adapters } = project(f);
    expect(adapters.define).toEqual(["bun", "/x/agent.ts", "--quick"]);
    expect(adapters.workspace).toEqual(["my-ws", "--fast"]);
  });

  test("interactive: [enter] accepts each default, one non-default pick (a new main line)", async () => {
    const f = repo();
    const enter = (label: string) => ({ wait: `${label} [`, send: "\n" });
    const ran = await runPty(["sh", "-c", 'exec bun "$0" < /dev/tty', SETUP], "", {
      cwd: f.root,
      env: env(f.home),
      turns: [
        enter("Project id"), enter("Tracker"), enter("Tracker dir"), enter("Workspace"),
        { wait: "Main line [", send: "3\n" }, { wait: "New main-line branch [", send: "feature-x\n" },
        enter("Worktrees root"), enter("Define"), enter("Implement"), enter("Check"), enter("Integrate"),
        enter("Deploy"), enter("Verify"), enter("Principal"), enter("State"), enter("State dir"),
      ],
    });
    expect(ran.exit).toBe(0);
    expect(ran.ptyOutput).toContain("(default)");
    expect(git(f.root, "rev-parse", "feature-x")).toBe(git(f.root, "rev-parse", "HEAD"));
    const config = project(f);
    expect(config.adapters.tracker[1]).toBe(adapter("tracker/md.ts"));
    expect(config.adapters.workspace).toContain("feature-x");
    expect(shipStatus(f)).toMatchObject({ exit: 0, stdout: '{"deliveries":[]}' });
  }, 30_000);

  test("interactive: yes to the push question pushes the new main line with upstream", async () => {
    const f = repoWithRemote();
    const ran = await runPty(["sh", "-c", 'exec bun "$0" "$@" < /dev/tty', SETUP, ...allFlagsBut(f, "--main")], "", {
      cwd: f.root,
      env: env(f.home),
      turns: [
        { wait: "Main line [", send: "3\n" }, { wait: "New main-line branch [", send: "rel\n" },
        { wait: "Push rel to origin with upstream? [y/N]", send: "y\n" },
      ],
    });
    expect(ran.exit).toBe(0);
    expect(remoteHas(f.remote, "rel")).toBe(true);
    expect(upstreamOf(f, "rel")).toBe("origin/rel");
  }, 30_000);
});
