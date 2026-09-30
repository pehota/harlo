#!/usr/bin/env bun
// Md-file Tracker adapter (plan §6 M1.2/M1.3). Layout: <dir>/<key>.md, external-path mode only
// (no repo-mode/commit — out of scope per plan.md's "Out of scope" list).
// argv: --dir <dir> tracker <op>; stdin: Stdin (§3.1); stdout: one Result JSON line.
// Frontmatter is `---\n...\n---\n` at the top of the file, holding at least `status:` and
// optionally `title:`. The body is everything between the frontmatter and the `<!-- ship:log -->`
// marker; `comment` only ever appends below that marker, so `body` is unchanged after a comment
// (W1, no self-echo: a later `ship changed` must not see its own comment as a change).
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
  writeFileSync(path, rewriteStatus(readFile(path), status));
  return {};
};

/** Appends a line below the marker; if the file predates the marker, the marker is added at the end. */
const comment = (root: string, key: string, { text }: TrackerCommentPayload): Record<string, never> => {
  const path = filePath(root, key);
  const raw = readFile(path);
  const withMarker = raw.includes(MARKER) ? raw : `${raw.endsWith("\n") ? raw : `${raw}\n`}${MARKER}\n`;
  writeFileSync(path, `${withMarker.endsWith("\n") ? withMarker : `${withMarker}\n`}${text}\n`);
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
