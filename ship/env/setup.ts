#!/usr/bin/env bun
// Setup (environment code): writes a git repo's `ship.config.json` (at the git root) and its machine config
// `~/.config/ship/<projectId>.json`, then proves both load in the real `bin/ship` (`ship status`) and prints the
// command that starts the queue (`env/queue.ts`). Run from anywhere inside the target repo:
//   bun <harlo>/ship/env/setup.ts [flags]
// Interactive by default: each prompt shows its default, [enter] accepts it. Prompts are written to stderr and
// answers read from stdin line by line. A value given as a flag is never asked; `--yes` takes the default for
// every value not given, so `--yes` (or a flag for every value) runs without prompts.
// Never imports src/core or src/runner (environment code); the configs are checked against src/contracts schemas,
// then loaded by `bin/ship` itself, so the cross-field policy rules are the Runner's own.
//
// argv: see USAGE below.
// exit: 0 written and loaded · 1 bad usage, not a git repo, bad value, or a config file exists (no --force),
//       nothing written · 2 written, but `ship status` rejected them
import { appendFileSync, existsSync, mkdirSync, readFileSync, readSync, writeFileSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { type MachineConfig, type PolicyConfig, type ProjectConfig, machineConfigSchema, projectConfigSchema } from "../src/contracts/config";
import { check } from "../src/contracts/validate";

const SHIP = resolve(import.meta.dir, "..");
const HOME = process.env.HOME ?? homedir();
const OWN = "own path…";

type Port = "tracker" | "workspace" | "define" | "implement" | "check" | "integrate" | "deploy" | "verify" | "principal" | "state";
type Adapter = { name: string; path: string };

// Rule: a port lists an adapter only once it implements EVERY op of that port. Update this when an adapter is
// completed: jira (tracker) is left out while it implements only read/next (pehota/harlo#43).
const ADAPTERS: Record<Port, Adapter[]> = {
  tracker: [{ name: "github", path: "tracker/github.ts" }, { name: "md", path: "tracker/md.ts" }],
  workspace: [{ name: "worktree", path: "workspace/worktree.ts" }],
  define: [{ name: "claude", path: "agent/claude/index.ts" }],
  implement: [{ name: "claude", path: "agent/claude/index.ts" }],
  check: [{ name: "claude", path: "agent/claude/index.ts" }],
  integrate: [{ name: "local", path: "integrate/local.ts" }],
  deploy: [{ name: "principal", path: "ask/principal/index.ts" }],
  verify: [{ name: "principal", path: "ask/principal/index.ts" }],
  principal: [{ name: "tty", path: "principal/tty.ts" }],
  state: [{ name: "files", path: "state/files.ts" }],
};
const PORT_FLAGS: Exclude<Port, "tracker">[] = ["workspace", "define", "implement", "check", "integrate", "deploy", "verify", "principal", "state"];
const VALUE_FLAGS = [
  "--project-id", "--tracker", "--repo", "--project", "--project-owner", "--ready-label", "--status-labels",
  "--tracker-dir", "--main", "--worktrees", "--state-dir", ...PORT_FLAGS.map((port) => `--${port}`),
];

const USAGE = `usage: setup.ts [--yes] [--force] [--help] [--project-id <id>]
  [--tracker ${ADAPTERS.tracker.map((a) => a.name).join("|")}|path:<argv>] [--repo <owner/name>] [--project <n>] [--project-owner <owner>]
  [--ready-label <name>] [--status-labels <a,b,...>] [--tracker-dir <dir>]
  [--main current|<existing branch>|new:<name>] [--worktrees <dir>] [--state-dir <dir>]
  [--<port> <adapter>|path:<argv>]  for port in ${PORT_FLAGS.join(", ")}`;

class SetupError extends Error {}

const parseArgs = (args: string[]): { values: Map<string, string>; yes: boolean; force: boolean; help: boolean } => {
  const values = new Map<string, string>();
  const bools = { yes: false, force: false, help: false };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    const bool = arg.slice(2) as keyof typeof bools;
    if (arg.startsWith("--") && bool in bools) bools[bool] = true;
    else if (VALUE_FLAGS.includes(arg) && i + 1 < args.length) values.set(arg, args[++i] ?? "");
    else throw new SetupError(`unknown or incomplete argument: ${arg}\n${USAGE}`);
  }
  return { values, ...bools };
};

const git = (root: string, args: string[]): { code: number; out: string; err: string } => {
  const proc = Bun.spawnSync(["git", "-C", root, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: proc.exitCode ?? 1, out: proc.stdout.toString().trim(), err: proc.stderr.toString().trim() };
};

/** What the repo tells us: root, current branch, local branches, GitHub `owner/name` of `origin` if any. */
const detect = () => {
  const top = git(process.cwd(), ["rev-parse", "--show-toplevel"]);
  if (top.code !== 0) throw new SetupError(`not inside a git repo (${process.cwd()}): run setup from the target repo`);
  const root = top.out;
  const branch = git(root, ["symbolic-ref", "--short", "HEAD"]);
  if (branch.code !== 0) throw new SetupError(`cannot read the current branch (detached HEAD?): ${branch.err}`);
  const branches = git(root, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]).out.split("\n").filter(Boolean);
  const origin = git(root, ["remote", "get-url", "origin"]);
  const github = origin.code === 0 ? /github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?\/?$/.exec(origin.out)?.[1] : undefined;
  return { root, current: branch.out, branches, github };
};

// --- prompts ------------------------------------------------------------------------------------------------

type Ask = {
  /** A free-text value: the flag if given, else the default under --yes, else a prompt. */
  text: (q: { flag: string; label: string; fallback: string }) => string;
  /** One of `options`: the flag if given (checked by the caller), else the default, else a numbered prompt. */
  choose: (q: { flag: string; label: string; options: string[]; fallback: number }) => string;
};

/** One stdin line, read byte by byte and blocking (Bun's line readers drop empty lines on a tty). */
const readLine = (prompt: string): string => {
  process.stderr.write(prompt);
  const bytes: number[] = [];
  const one = Buffer.alloc(1);
  let read = 0;
  while ((read = readSync(0, one, 0, 1, null)) === 1 && one[0] !== 10) bytes.push(one[0] ?? 0);
  if (read === 0 && bytes.length === 0) throw new SetupError("input ended before every question was answered");
  return Buffer.from(bytes).toString("utf8").trim();
};

const asker = (values: Map<string, string>, yes: boolean): Ask => ({
  text: ({ flag, label, fallback }) => {
    const given = values.get(flag);
    if (given !== undefined) return given;
    if (yes) return fallback;
    return readLine(`${label} [${fallback}]: `) || fallback;
  },
  choose: ({ flag, label, options, fallback }) => {
    const given = values.get(flag);
    if (given !== undefined) return given;
    const defaultOption = options[fallback] ?? "";
    if (yes) return defaultOption;
    process.stderr.write(`${label}:\n${options.map((o, i) => `  ${i + 1}) ${o}${i === fallback ? " (default)" : ""}`).join("\n")}\n`);
    for (;;) {
      const answer = readLine(`${label} [${fallback + 1}]: `);
      if (answer === "") return defaultOption;
      const picked = options[Number(answer) - 1];
      if (/^\d+$/.test(answer) && picked !== undefined) return picked;
      process.stderr.write(`pick 1-${options.length}\n`);
    }
  },
});

// --- choices ------------------------------------------------------------------------------------------------

const argvOf = (path: string): string[] => ["bun", join(SHIP, "src", "adapters", path)];
const splitArgv = (text: string): string[] => text.split(/\s+/).filter(Boolean);

/** The adapter a port is served by: a registry name, or `path:<argv>` / the "own path…" option (argv asked). */
const pickAdapter = (ask: Ask, port: Port, fallback = 0): { name: string; argv: string[] } => {
  const registry = ADAPTERS[port];
  const label = port[0]?.toUpperCase() + port.slice(1);
  const answer = ask.choose({ flag: `--${port}`, label, options: [...registry.map((a) => a.name), OWN], fallback });
  if (answer.startsWith("path:")) return { name: OWN, argv: splitArgv(answer.slice(5)) };
  if (answer === OWN) return { name: OWN, argv: splitArgv(ask.text({ flag: "", label: `${label} adapter argv`, fallback: "" })) };
  const found = registry.find((a) => a.name === answer);
  if (!found) throw new SetupError(`--${port}: unknown adapter ${answer} (one of ${registry.map((a) => a.name).join(", ")}, or path:<argv>)`);
  return { name: found.name, argv: argvOf(found.path) };
};

type Repo = ReturnType<typeof detect>;

/** The main line: the current branch, an existing local branch, or `new:<name>` (created later, from HEAD). */
const pickMain = (ask: Ask, repo: Repo): { branch: string; create: boolean } => {
  const options = [`current (${repo.current})`, "choose existing", "new"];
  const answer = ask.choose({ flag: "--main", label: "Main line", options, fallback: 0 });
  const chosen = answer === options[0] ? "current"
    : answer === "choose existing" ? ask.choose({ flag: "", label: "Existing branch", options: repo.branches, fallback: Math.max(0, repo.branches.indexOf(repo.current)) })
    : answer === "new" ? `new:${ask.text({ flag: "", label: "New main-line branch", fallback: "" })}`
    : answer;
  if (chosen === "current") return { branch: repo.current, create: false };
  if (chosen.startsWith("new:")) {
    const branch = chosen.slice(4);
    if (git(repo.root, ["check-ref-format", "--branch", branch]).code !== 0) throw new SetupError(`not a valid branch name: ${JSON.stringify(branch)}`);
    if (repo.branches.includes(branch)) throw new SetupError(`branch ${branch} already exists: pass --main ${branch}`);
    return { branch, create: true };
  }
  if (!repo.branches.includes(chosen)) throw new SetupError(`--main: no local branch ${chosen} (current, an existing branch, or new:<name>)`);
  return { branch: chosen, create: false };
};

type Statuses = { ready: string; working: string; done: string };
const PROJECT_STATUSES: Statuses = { ready: "Todo", working: "In Progress", done: "Done" }; // GitHub Project's default Status field
const LABEL_STATUSES: Statuses = { ready: "ready", working: "in_progress", done: "done" }; // md's `ready`, github's default ready label

/** Tracker argv (github by default when `origin` is on GitHub, else md), the statuses the policy maps to, dirs to create. */
const pickTracker = (ask: Ask, ctx: { repo: Repo; projectId: string }) => {
  const tracker = pickAdapter(ask, "tracker", ADAPTERS.tracker.findIndex((a) => a.name === (ctx.repo.github ? "github" : "md")));
  if (tracker.name === "md") {
    const dir = dirPath(ask.text({ flag: "--tracker-dir", label: "Tracker dir", fallback: join(HOME, ".local", "state", "ship", ctx.projectId, "tracker") }));
    return { argv: [...tracker.argv, "--dir", dir], statuses: LABEL_STATUSES, dirs: [dir] };
  }
  if (tracker.name === "github") {
    const repoName = ask.text({ flag: "--repo", label: "GitHub repo (owner/name)", fallback: ctx.repo.github ?? "" });
    const project = ask.text({ flag: "--project", label: "GitHub project number (empty = label mode)", fallback: "" });
    const owner = project ? ask.text({ flag: "--project-owner", label: "Project owner (empty = the repo owner)", fallback: "" }) : "";
    const statuses = project ? PROJECT_STATUSES : LABEL_STATUSES;
    const ready = ask.text({ flag: "--ready-label", label: "Ready status", fallback: statuses.ready });
    const labels = project
      ? ask.text({ flag: "--status-labels", label: "Status labels (unused in project mode)", fallback: "" })
      : ask.text({ flag: "--status-labels", label: "Status labels", fallback: `${statuses.working},${statuses.done}` });
    const argv = [
      ...tracker.argv, ...(repoName ? ["--repo", repoName] : []), ...(project ? ["--project", project] : []),
      ...(owner ? ["--project-owner", owner] : []), "--ready-label", ready, ...(labels ? ["--status-labels", labels] : []),
    ];
    return { argv, statuses, dirs: [] };
  }
  return { argv: tracker.argv, statuses: LABEL_STATUSES, dirs: [] }; // own path: label-style statuses
};

/** Every stop outcome comments; delivered/accepted_with_failure set the done status (Close awaits it). */
const policyFor = ({ working, done }: Statuses): PolicyConfig => ({
  tracker: {
    steps: { define: working, implement: working }, // a picked item leaves `ready` at once (queue re-pick guard)
    outcomes: {
      delivered: { status: done, comment: true }, accepted_with_failure: { status: done, comment: true },
      rolled_back: { status: working, comment: true }, abandoned: { comment: true },
    },
  },
});

// --- writing ------------------------------------------------------------------------------------------------

const refuseExisting = (paths: string[], force: boolean): void => {
  const existing = paths.find((path) => existsSync(path));
  if (existing && !force) throw new SetupError(`${existing} already exists: pass --force to overwrite (nothing written)`);
};

/** `.ship/` as a line of the repo's info/exclude, once. */
const excludeShipDir = (root: string): void => {
  const path = resolve(root, git(root, ["rev-parse", "--git-path", "info/exclude"]).out);
  const text = existsSync(path) ? readFileSync(path, "utf8") : "";
  if (text.split("\n").includes(".ship/")) return;
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, `${text === "" || text.endsWith("\n") ? "" : "\n"}.ship/\n`);
};

const dirPath = (dir: string): string =>
  resolve(dir === "~" ? HOME : dir.startsWith("~/") ? join(HOME, dir.slice(2)) : dir);

const quote = (arg: string): string => (/^[\w@%+=:,./-]+$/.test(arg) ? arg : `'${arg.replaceAll("'", `'\\''`)}'`);

const writeJson = (path: string, value: unknown): void => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(value, null, 2)}\n`);
};

type Plan = {
  repo: Repo; project: ProjectConfig; machine: MachineConfig; files: { project: string; machine: string };
  main: { branch: string; create: boolean } | undefined; worktrees: string | undefined; dirs: string[];
};

/** Every answer, flag or default, turned into both configs; nothing on disk changes here. */
const plan = (ask: Ask, ctx: { repo: Repo; projectFile: string; force: boolean }): Plan => {
  const { repo } = ctx;
  const projectId = ask.text({ flag: "--project-id", label: "Project id", fallback: basename(repo.root) });
  const machineFile = join(HOME, ".config", "ship", `${projectId}.json`);
  refuseExisting([machineFile], ctx.force);

  const tracker = pickTracker(ask, { repo, projectId });
  const workspace = pickAdapter(ask, "workspace");
  const main = workspace.name === "worktree" ? pickMain(ask, repo) : undefined;
  const worktrees = main
    ? dirPath(ask.text({ flag: "--worktrees", label: "Worktrees root", fallback: join(repo.root, ".ship", "worktrees") }))
    : undefined;
  const steps = { define: pickAdapter(ask, "define"), implement: pickAdapter(ask, "implement"), check: pickAdapter(ask, "check") };
  const integrate = pickAdapter(ask, "integrate");
  const gates = { deploy: pickAdapter(ask, "deploy"), verify: pickAdapter(ask, "verify") };
  const principal = pickAdapter(ask, "principal");
  const state = pickAdapter(ask, "state");
  const stateDir = state.name === "files"
    ? dirPath(ask.text({ flag: "--state-dir", label: "State dir", fallback: join(HOME, ".local", "state", "ship", projectId, "state") }))
    : undefined;

  const project: ProjectConfig = {
    projectId,
    adapters: {
      tracker: tracker.argv,
      workspace: main && worktrees ? [...workspace.argv, "--main", main.branch, "--root", worktrees] : workspace.argv,
      define: steps.define.argv, implement: steps.implement.argv, check: steps.check.argv,
      integrate: integrate.name === "local" ? [...integrate.argv, "--root", repo.root] : integrate.argv,
      deploy: gates.deploy.argv, verify: gates.verify.argv,
    },
    policy: policyFor(tracker.statuses),
  };
  const user = { env: { USER: process.env.USER ?? userInfo().username } }; // keychain-backed `claude` auth needs it
  const machine: MachineConfig = {
    principal: principal.argv,
    state: stateDir ? [...state.argv, "--dir", stateDir] : state.argv,
    capabilities: { define: user, implement: user, check: user },
  };
  const invalid = check(projectConfigSchema, project) ?? check(machineConfigSchema, machine);
  if (invalid) throw new SetupError(`invalid config: ${invalid}`);
  const dirs = [...tracker.dirs, ...(stateDir ? [stateDir] : [])];
  return { repo, project, machine, files: { project: ctx.projectFile, machine: machineFile }, main, worktrees, dirs };
};

/** The only step that changes anything: branch, directories, the exclude line, both files. */
const apply = (p: Plan): void => {
  if (p.main?.create) {
    const created = git(p.repo.root, ["branch", p.main.branch]);
    if (created.code !== 0) throw new SetupError(`git branch ${p.main.branch}: ${created.err}`);
  }
  for (const dir of p.dirs) mkdirSync(dir, { recursive: true });
  excludeShipDir(p.repo.root);
  writeJson(p.files.project, p.project);
  writeJson(p.files.machine, p.machine);
};

/** Load both files the way ship does: `ship status` from the git root with this machine config. */
const shipStatus = (p: Plan) => {
  const status = Bun.spawnSync([join(SHIP, "bin", "ship"), "status"], {
    cwd: p.repo.root, env: { ...process.env, SHIP_MACHINE_CONFIG: p.files.machine }, stdout: "pipe", stderr: "pipe",
  });
  return { exitCode: status.exitCode, stdout: status.stdout.toString().trim(), stderr: status.stderr.toString() };
};

/** Inside the repo, with no hidden segment (`bun test` skips hidden dirs such as the default `.ship/`). */
const visibleInRepo = (root: string, dir: string): boolean => {
  const rel = relative(root, dir);
  return !rel.startsWith("..") && !rel.split("/").some((segment) => segment.startsWith("."));
};

const report = (p: Plan, loaded: string): string[] => {
  const queue = ["bun", join(SHIP, "env", "queue.ts"), "--ship", join(SHIP, "bin", "ship"), "--interval", "30000", "--state", ...p.machine.state];
  const { root, current } = p.repo;
  return [
    `wrote ${p.files.project}`,
    `wrote ${p.files.machine}`,
    `\`ship status\` loads both: ${loaded}`,
    ...(p.main?.create ? [`created branch ${p.main.branch} from HEAD`] : []),
    ...(p.main && p.main.branch !== current
      ? [`note: integrate/local lands onto the branch checked out in ${root} (now ${current}): check out ${p.main.branch} there first`]
      : []),
    ...(p.worktrees && visibleInRepo(root, p.worktrees)
      ? [`warning: ${p.worktrees} is inside the repo and not hidden: bun test and other tools will pick up the Deliveries' files`]
      : []),
    "",
    `Start the queue, from ${root}:`,
    `  ${queue.map(quote).join(" ")}`,
    "The tty Principal answers gates on /dev/tty: run the queue in a real terminal.",
  ];
};

const run = (args: string[]): number => {
  const options = parseArgs(args);
  if (options.help) {
    console.log(USAGE);
    return 0;
  }
  const repo = detect();
  const projectFile = join(repo.root, "ship.config.json");
  refuseExisting([projectFile], options.force);

  const planned = plan(asker(options.values, options.yes), { repo, projectFile, force: options.force });
  apply(planned);
  const status = shipStatus(planned);
  if (status.exitCode !== 0) {
    console.error(`written, but \`ship status\` rejected them (exit ${status.exitCode}):\n${status.stderr}`);
    return 2;
  }
  console.log(report(planned, status.stdout).join("\n"));
  return 0;
};

const main = (): number => {
  try {
    return run(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof SetupError ? error.message : error instanceof Error ? error.stack : String(error));
    return 1;
  }
};

process.exit(main());
