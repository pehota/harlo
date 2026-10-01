#!/usr/bin/env bun
// Md-file Tracker adapter (plan §6 M1.2/M1.3). Layout: <dir>/<key>.md, external-path mode only
// (no repo-mode/commit — out of scope per plan.md's "Out of scope" list).
// argv: --dir <dir> tracker <op>; stdin: Stdin (§3.1); stdout: one Result JSON line.
// Frontmatter is `---\n...\n---\n` at the top of the file, holding at least `status:` and
// optionally `title:`. The body is everything between the frontmatter and the `<!-- ship:log -->`
// marker; `comment` only ever appends below that marker, so `body` is unchanged after a comment
// (W1, no self-echo: a later `ship changed` must not see its own comment as a change).
// Every mutation (update/comment) is committed to a git repo lazily created inside <dir> (best effort:
// a git failure only warns on stderr, the op still succeeds and stdout stays one Result line).
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { WorkItem } from "../../../src/contracts/common";
import type {
  TrackerCommentPayload, TrackerNextBody, TrackerReadBody, TrackerReadPayload, TrackerUpdatePayload,
} from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { check } from "../../../src/contracts/validate";
import { KEY_RE } from "../../../src/core/ids";

const MARKER = "<!-- ship:log -->";
const FRONTMATTER_RE = /^---\r?\n([\s\S]*?)\r?\n---\r?\n/;

const expandHome = (dir: string): string =>
  dir === "~" ? homedir() : dir.startsWith("~/") ? join(homedir(), dir.slice(2)) : dir;

// A tracker key names a file, so it must be one safe path segment (no `/`, no leading `.`).
const filePath = (root: string, key: string): string => {
  if (!KEY_RE.test(key)) throw new Error(`not a tracker key: ${JSON.stringify(key)}`);
  return join(root, `${key}.md`);
};

/** Runs git in the tracker dir; stdout/stderr are captured so nothing leaks into the adapter's stdout protocol. */
const git = (root: string, args: string[]): string => {
  const proc = Bun.spawnSync(["git", "-C", root, "-c", "commit.gpgsign=false", ...args], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`git ${args[0]} failed: ${proc.stderr.toString().trim()}`);
  return proc.stdout.toString();
};

/** Creates the repo in `root` itself (never a parent's) on first write and commits the files already there. */
const ensureRepo = (root: string): void => {
  if (existsSync(join(root, ".git"))) return;
  git(root, ["init", "--quiet"]);
  // A local identity only when none is configured, so the commit works with no global git config.
  if (!Bun.spawnSync(["git", "-C", root, "config", "user.email"], { stdout: "pipe" }).stdout.toString().trim()) {
    git(root, ["config", "user.name", "ship"]);
    git(root, ["config", "user.email", "ship@localhost"]);
  }
  if (readdirSync(root).some((name) => name.endsWith(".md"))) {
    git(root, ["add", "--", "*.md"]);
    git(root, ["commit", "--quiet", "--no-verify", "-m", "tracker: initial import of existing WorkItems"]);
  }
};

/** Commits `name` if it changed (no empty commit for a no-op write). Never throws: failure is a stderr warning. */
const commitChange = (root: string, name: string, message: string): void => {
  try {
    git(root, ["add", "--", name]);
    if (Bun.spawnSync(["git", "-C", root, "diff", "--cached", "--quiet", "--", name]).exitCode === 0) return;
    git(root, ["commit", "--quiet", "--no-verify", "-m", message, "--", name]);
  } catch (error) {
    console.error(`warning: tracker git commit skipped: ${error instanceof Error ? error.message : String(error)}`);
  }
};

/** Best-effort repo init before a mutation; a failure only warns (the commit step will then warn too). */
const prepareRepo = (root: string): void => {
  try {
    ensureRepo(root);
  } catch (error) {
    console.error(`warning: tracker git init skipped: ${error instanceof Error ? error.message : String(error)}`);
  }
};

const readFile = (path: string): string => {
  if (!existsSync(path)) throw new Error(`no tracker file: ${path}`);
  return readFileSync(path, "utf8");
};

/** Splits a file's raw text into its frontmatter body and the rest (title/body/marker/log). */
const splitFrontmatter = (raw: string): { frontmatter: string; rest: string } => {
  const match = FRONTMATTER_RE.exec(raw);
  if (!match) throw new Error("tracker file has no frontmatter");
  return { frontmatter: match[1] ?? "", rest: raw.slice(match[0].length) };
};

const frontmatterField = (frontmatter: string, name: string): string | undefined => {
  const match = new RegExp(`^${name}:\\s*(.*)$`, "m").exec(frontmatter);
  return match?.[1]?.trim().replace(/^["']|["']$/g, "");
};

/** The body is the text above the marker (or all of it, if there is no marker yet). */
const bodyOf = (rest: string): string => {
  const at = rest.indexOf(MARKER);
  return (at === -1 ? rest : rest.slice(0, at)).trim();
};

const h1Title = (body: string): string | undefined => /^#\s+(.+)$/m.exec(body)?.[1]?.trim();

const parse = (raw: string): { status: string | undefined; title: string; body: string } => {
  const { frontmatter, rest } = splitFrontmatter(raw);
  const body = bodyOf(rest);
  return { status: frontmatterField(frontmatter, "status"), title: frontmatterField(frontmatter, "title") ?? h1Title(body) ?? "", body };
};

const read = (root: string, { key }: TrackerReadPayload): TrackerReadBody => {
  const { title, body } = parse(readFile(filePath(root, key)));
  return { workItem: { key, title, body } satisfies WorkItem };
};

const next = (root: string): TrackerNextBody => {
  if (!existsSync(root)) return { key: null };
  const files = readdirSync(root).filter((name) => name.endsWith(".md")).sort();
  for (const name of files) {
    if (parse(readFileSync(join(root, name), "utf8")).status === "ready") return { key: name.slice(0, -3) };
  }
  return { key: null };
};

/** Rewrites only the frontmatter `status:` line; every other byte (title, body, marker, log) is untouched. */
const rewriteStatus = (raw: string, status: string): string => {
  const { frontmatter, rest } = splitFrontmatter(raw);
  const hasStatus = /^status:\s*.*$/m.test(frontmatter);
  const newFrontmatter = hasStatus
    ? frontmatter.replace(/^status:\s*.*$/m, `status: ${status}`)
    : `${frontmatter}\nstatus: ${status}`;
  return `---\n${newFrontmatter}\n---\n${rest}`;
};

const update = (root: string, key: string, { status }: TrackerUpdatePayload): Record<string, never> => {
  const path = filePath(root, key);
  const updated = rewriteStatus(readFile(path), status);
  prepareRepo(root);
  writeFileSync(path, updated);
  commitChange(root, `${key}.md`, `update ${key}: status ${status}`);
  return {};
};

/** Appends a line below the marker; if the file predates the marker, the marker is added at the end. */
const comment = (root: string, key: string, { text }: TrackerCommentPayload): Record<string, never> => {
  const path = filePath(root, key);
  const raw = readFile(path);
  const withMarker = raw.includes(MARKER) ? raw : `${raw.endsWith("\n") ? raw : `${raw}\n`}${MARKER}\n`;
  prepareRepo(root);
  writeFileSync(path, `${withMarker.endsWith("\n") ? withMarker : `${withMarker}\n`}${text}\n`);
  commitChange(root, `${key}.md`, `comment ${key}`);
  return {};
};

type Stdin = { workItem: WorkItem | null; payload?: unknown };

const ops: Record<string, (root: string, stdin: Stdin) => unknown> = {
  read: (root, stdin) => read(root, stdin.payload as TrackerReadPayload),
  next: (root) => next(root),
  update: (root, stdin) => update(root, requireKey(stdin), stdin.payload as TrackerUpdatePayload),
  comment: (root, stdin) => comment(root, requireKey(stdin), stdin.payload as TrackerCommentPayload),
  cancel: () => ({}), // nothing runs in the background, so there is never anything to cancel
};

const requireKey = ({ workItem }: Stdin): string => {
  if (!workItem) throw new Error("no WorkItem on stdin");
  return workItem.key;
};

/** argv after the script: `--dir <dir> <port> <op>`. */
const parseArgs = (args: string[]): { dir: string | undefined; port: string | undefined; op: string | undefined } => {
  const at = args.indexOf("--dir");
  const dir = at === -1 ? undefined : args[at + 1];
  const positional = at === -1 ? args : [...args.slice(0, at), ...args.slice(at + 2)];
  const [port, op] = positional;
  return { dir, port, op };
};

/** Every error is caught: read/next/cancel change nothing on failure; update/comment fail before their write. */
const run = async (): Promise<unknown> => {
  const { dir, port, op } = parseArgs(process.argv.slice(2));
  if (!dir) throw new Error("usage: tracker/md.ts --dir <dir> tracker <op>");
  const contract = port === "tracker" && op ? schemaFor("tracker", op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return handler(expandHome(dir), stdin);
};

try {
  console.log(JSON.stringify({ status: "ok", body: await run() }));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
