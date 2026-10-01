#!/usr/bin/env bun
// GitHub issues Tracker adapter (plan §6 M2.4), driving the `gh` CLI; no direct API calls.
// argv: [--repo <owner/name>] [--ready-label <name>] [--status-labels <a,b,...>] tracker <op>;
// stdin: Stdin (§3.1); stdout: one Result JSON line.
// Keys are `<name>-<n>` (`name` is the repo part of `owner/name`; KEY_RE forbids `/`), e.g. `harlo-12`.
// Without --repo the repo is resolved once via `gh repo view` in the cwd.
// Statuses are labels. The status label set is --status-labels plus the ready label (default `ready`),
// so moving an issue to any other status also takes it out of `next`'s query. `update` leaves exactly
// one status label (or none, for an empty status); labels outside the set are never touched. A status
// outside the set is rejected as `failed` before any `gh` call.
// W1 (no self-echo): `update` only edits labels and `comment` only adds a comment, so title and body
// (all `read` returns) never change through this adapter.
// Env: `gh` gets only PATH, HOME and GH_TOKEN (from the capability profile), nothing else inherited.
import type { WorkItem } from "../../../src/contracts/common";
import type {
  TrackerCommentPayload, TrackerNextBody, TrackerReadBody, TrackerReadPayload, TrackerUpdatePayload,
} from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { check } from "../../../src/contracts/validate";
import { KEY_RE } from "../../../src/core/ids";

/** `gh` exited non-zero after it may have changed something: exit non-zero (a crash), never `failed`. */
class Crash extends Error {}

type Config = { repo: string | undefined; readyLabel: string; statusLabels: string[] };
type Gh = { exitCode: number; stdout: string; stderr: string };

const ghEnv = (): Record<string, string> => {
  const env: Record<string, string> = { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" };
  if (process.env.GH_TOKEN) env.GH_TOKEN = process.env.GH_TOKEN;
  return env;
};

/** Runs `gh`; a spawn failure (e.g. no `gh` on PATH) throws, which is `failed`: nothing ran. */
const runGh = (args: string[], input?: string): Gh => {
  const proc = Bun.spawnSync(["gh", ...args], {
    stdin: input === undefined ? "ignore" : Buffer.from(input), stdout: "pipe", stderr: "pipe", env: ghEnv(),
  });
  return { exitCode: proc.exitCode ?? 1, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
};

const ghError = (args: string[], { exitCode, stderr }: Gh): string =>
  `gh ${args.slice(0, 2).join(" ")} exited ${exitCode}: ${stderr.trim()}`;

/** A read-only `gh` call: any failure changed nothing, so it throws a plain Error (`failed`). */
const ghRead = (args: string[]): unknown => {
  const result = runGh(args);
  if (result.exitCode !== 0) throw new Error(ghError(args, result));
  return JSON.parse(result.stdout);
};

let resolvedRepo: string | undefined;
const repoOf = (config: Config): string => {
  resolvedRepo ??= config.repo ?? (ghRead(["repo", "view", "--json", "nameWithOwner"]) as { nameWithOwner: string }).nameWithOwner;
  if (!/^[^/\s]+\/[^/\s]+$/.test(resolvedRepo)) throw new Error(`not an owner/name repo: ${JSON.stringify(resolvedRepo)}`);
  return resolvedRepo;
};

const keyPrefix = (config: Config): string => `${repoOf(config).split("/")[1]}-`;

/** `<name>-<n>` → n; anything else (bad shape, no number, another repo's prefix) throws before any edit. */
const issueNumber = (config: Config, key: string): string => {
  if (!KEY_RE.test(key)) throw new Error(`not a tracker key: ${JSON.stringify(key)}`);
  const prefix = keyPrefix(config);
  const n = key.startsWith(prefix) ? key.slice(prefix.length) : "";
  if (!/^[1-9][0-9]*$/.test(n)) throw new Error(`not an issue key of ${repoOf(config)}: ${JSON.stringify(key)}`);
  return n;
};

const read = (config: Config, { key }: TrackerReadPayload): TrackerReadBody => {
  const n = issueNumber(config, key);
  const issue = ghRead(["issue", "view", n, "--repo", repoOf(config), "--json", "title,body"]) as { title: string; body: string };
  return { workItem: { key, title: issue.title, body: issue.body } satisfies WorkItem };
};

/** The open issue with the ready label and the lowest number (gh lists newest first, so sort here). */
const next = (config: Config): TrackerNextBody => {
  const issues = ghRead([
    "issue", "list", "--repo", repoOf(config), "--label", config.readyLabel, "--state", "open",
    "--json", "number", "--limit", "1000",
  ]) as { number: number }[];
  const lowest = issues.map((issue) => issue.number).sort((a, b) => a - b)[0];
  return { key: lowest === undefined ? null : `${keyPrefix(config)}${lowest}` };
};

const labelsOf = (config: Config, n: string): string[] =>
  (ghRead(["issue", "view", n, "--repo", repoOf(config), "--json", "labels"]) as { labels: { name: string }[] })
    .labels.map((label) => label.name);

const sameSet = (a: string[], b: string[]): boolean => a.length === b.length && a.every((label) => b.includes(label));

/**
 * One `gh issue edit` with every add and remove. If it fails, the labels are re-read: unchanged gives
 * `failed`, and a failed re-read is a crash (the outcome is unknown). Changed means the add took effect,
 * so it is never `failed`: a second, narrower edit removes the stale status labels still present, and if
 * that succeeds the result is a plain `ok`. If the cleanup fails too, the labels are re-read once more
 * and the result is `ok` with a `partial` evidence item.
 */
const update = (config: Config, key: string, { status }: TrackerUpdatePayload): { body: Record<string, never>; evidence?: { label: string; text: string }[] } => {
  const statusSet = [...new Set([...config.statusLabels, config.readyLabel])];
  if (status !== "" && !statusSet.includes(status)) {
    throw new Error(`status ${JSON.stringify(status)} is not a configured status label (${statusSet.join(", ")})`);
  }
  const n = issueNumber(config, key);
  const before = labelsOf(config, n);
  const remove = before.filter((label) => statusSet.includes(label) && label !== status);
  const add = status !== "" && !before.includes(status) ? [status] : [];
  if (add.length === 0 && remove.length === 0) return { body: {} };
  const args = [
    "issue", "edit", n, "--repo", repoOf(config),
    ...add.flatMap((label) => ["--add-label", label]), ...remove.flatMap((label) => ["--remove-label", label]),
  ];
  const result = runGh(args);
  if (result.exitCode === 0) return { body: {} };
  let after: string[];
  try {
    after = labelsOf(config, n);
  } catch (error) {
    throw new Crash(`${ghError(args, result)}; re-reading labels failed too: ${error instanceof Error ? error.message : String(error)}`);
  }
  if (sameSet(before, after)) throw new Error(ghError(args, result));
  const stale = after.filter((label) => statusSet.includes(label) && label !== status);
  if (stale.length > 0) {
    const cleanupArgs = ["issue", "edit", n, "--repo", repoOf(config), ...stale.flatMap((label) => ["--remove-label", label])];
    const cleanup = runGh(cleanupArgs);
    if (cleanup.exitCode === 0) return { body: {} };
    try {
      after = labelsOf(config, n);
    } catch (error) {
      throw new Crash(`${ghError(cleanupArgs, cleanup)}; re-reading labels failed too: ${error instanceof Error ? error.message : String(error)}`);
    }
  }
  return { body: {}, evidence: [{ label: "partial", text: `${ghError(args, result)}; labels now: ${after.join(", ")}` }] };
};

/** Text goes in on stdin (`--body-file -`), so quotes, newlines and leading dashes arrive intact. */
const comment = (config: Config, key: string, { text }: TrackerCommentPayload): Record<string, never> => {
  const args = ["issue", "comment", issueNumber(config, key), "--repo", repoOf(config), "--body-file", "-"];
  const result = runGh(args, text);
  if (result.exitCode !== 0) throw new Crash(ghError(args, result)); // the comment may have been posted
  return {};
};

type Stdin = { workItem: WorkItem | null; payload?: unknown };
type Reply = { body: unknown; evidence?: unknown[] };

const requireKey = ({ workItem }: Stdin): string => {
  if (!workItem) throw new Error("no WorkItem on stdin");
  return workItem.key;
};

const ops: Record<string, (config: Config, stdin: Stdin) => Reply> = {
  read: (config, stdin) => ({ body: read(config, stdin.payload as TrackerReadPayload) }),
  next: (config) => ({ body: next(config) }),
  update: (config, stdin) => update(config, requireKey(stdin), stdin.payload as TrackerUpdatePayload),
  comment: (config, stdin) => ({ body: comment(config, requireKey(stdin), stdin.payload as TrackerCommentPayload) }),
  cancel: () => ({ body: {} }), // every gh call is synchronous, so there is never anything to cancel
};

const FLAGS = ["--repo", "--ready-label", "--status-labels"];

/** argv after the script: `[--repo r] [--ready-label l] [--status-labels a,b] <port> <op>`. */
const parseArgs = (args: string[]): { config: Config; port: string | undefined; op: string | undefined } => {
  const flags: Record<string, string> = {};
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i] ?? "";
    if (!FLAGS.includes(arg)) { positional.push(arg); continue; }
    const value = args[++i];
    if (value === undefined) throw new Error(`${arg} needs a value`);
    flags[arg] = value;
  }
  const statusLabels = (flags["--status-labels"] ?? "").split(",").map((label) => label.trim()).filter(Boolean);
  const readyLabel = flags["--ready-label"] ?? "ready";
  if (readyLabel === "" || readyLabel.includes(",")) throw new Error(`bad --ready-label: ${JSON.stringify(readyLabel)}`);
  const [port, op] = positional;
  return { config: { repo: flags["--repo"], readyLabel, statusLabels }, port, op };
};

/** Every error is caught: `failed` only where nothing changed, a crash (exit 1) where something may have. */
const run = async (): Promise<Reply> => {
  const { config, port, op } = parseArgs(process.argv.slice(2));
  const contract = port === "tracker" && op ? schemaFor("tracker", op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return handler(config, stdin);
};

try {
  const { body, evidence } = await run();
  console.log(JSON.stringify(evidence ? { status: "ok", body, evidence } : { status: "ok", body }));
} catch (error) {
  const info = error instanceof Error ? error.message : String(error);
  if (error instanceof Crash) {
    console.error(info);
    process.exit(1);
  }
  console.log(JSON.stringify({ status: "failed", info }));
}
