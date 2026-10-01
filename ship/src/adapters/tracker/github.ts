#!/usr/bin/env bun
// GitHub issues Tracker adapter (plan §6 M2.4), driving the `gh` CLI; no direct API calls.
// argv: [--repo <owner/name>] [--ready-label <name>] [--status-labels <a,b,...>]
//       [--project <number>] [--project-owner <owner>] [--status-field <name>] tracker <op>;
// stdin: Stdin (§3.1); stdout: one Result JSON line.
// Keys are `<name>-<n>` (`name` is the repo part of `owner/name`; KEY_RE forbids `/`), e.g. `harlo-12`.
// Without --repo the repo is resolved once via `gh repo view` in the cwd.
// Statuses are labels. The status label set is --status-labels plus the ready label (default `ready`),
// so moving an issue to any other status also takes it out of `next`'s query. `update` leaves exactly
// one status label (or none, for an empty status); labels outside the set are never touched. A status
// outside the set is rejected as `failed` before any `gh` call.
// Project mode (--project <number>, owned by the repo's owner unless --project-owner overrides it): the item source is that GitHub Project's
// single-select field --status-field (default `Status`) instead of labels. `next` takes the Issue items of
// --repo whose field equals the ready value (--ready-label, default `ready`) and returns the lowest number
// (sorted here, item-list order is not relied on); drafts, PRs and other repos' items are skipped. Items are
// listed with --limit 1000, so a Project with more than 1000 items is truncated. `update` resolves the
// project, field and option ids at runtime and makes one `gh project item-edit`; --status-labels is unused
// and an empty status is rejected (a single-select cannot be cleared here). `read` and `comment` are unchanged.
// W1 (no self-echo): `update` only edits labels (or the Project's status field) and `comment` only adds a comment, so title and body
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

type Config = {
  repo: string | undefined; readyLabel: string; statusLabels: string[];
  project: string | undefined; projectOwner: string | undefined; statusField: string;
};
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


// ---- Project mode ----

type ProjectItem = { id: string; content: { type: string; number?: number; repository?: string }; [field: string]: unknown };

const ITEM_LIST_SCHEMA = {
  type: "object", required: ["items"],
  properties: {
    items: {
      type: "array",
      items: {
        type: "object", required: ["id", "content"],
        properties: {
          id: { type: "string" },
          content: {
            type: "object", required: ["type"],
            properties: { type: { type: "string" }, number: { type: "integer" }, repository: { type: "string" } },
          },
        },
      },
    },
  },
};
const PROJECT_VIEW_SCHEMA = { type: "object", required: ["id"], properties: { id: { type: "string" } } };
const FIELD_LIST_SCHEMA = {
  type: "object", required: ["fields"],
  properties: {
    fields: {
      type: "array",
      items: {
        type: "object", required: ["id", "name"],
        properties: {
          id: { type: "string" }, name: { type: "string" },
          options: { type: "array", items: { type: "object", required: ["id", "name"], properties: { id: { type: "string" }, name: { type: "string" } } } },
        },
      },
    },
  },
};

/** A read-only gh call whose JSON must fit `schema`; malformed output is a validation error (`failed`). */
const ghChecked = <T>(args: string[], schema: object): T => {
  const data = ghRead(args);
  const invalid = check(schema, data);
  if (invalid) throw new Error(`invalid gh ${args.slice(0, 2).join(" ")} output: ${invalid}`);
  return data as T;
};

const owner = (config: Config): string => config.projectOwner ?? (repoOf(config).split("/")[0] as string);

const projectItems = (config: Config, project: string): ProjectItem[] =>
  ghChecked<{ items: ProjectItem[] }>(
    ["project", "item-list", project, "--owner", owner(config), "--format", "json", "--limit", "1000"], ITEM_LIST_SCHEMA,
  ).items;

/** Only Issues of --repo count: drafts, pull requests and other repos' issues are never ours. */
const repoIssues = (config: Config, items: ProjectItem[]): (ProjectItem & { number: number })[] =>
  items.filter((item): item is ProjectItem & { number: number } =>
    item.content.type === "Issue" && item.content.repository === repoOf(config) && item.content.number !== undefined);

/** gh keys an item's field values by the field name with a lowercase first letter (`Status` → `status`). */
const fieldValue = (item: ProjectItem, field: string): unknown =>
  item[field] ?? item[field.charAt(0).toLowerCase() + field.slice(1)];

const projectNext = (config: Config, project: string): TrackerNextBody => {
  const numbers = repoIssues(config, projectItems(config, project))
    .filter((item) => fieldValue(item, config.statusField) === config.readyLabel)
    .map((item) => item.content.number as number);
  const lowest = numbers.sort((a, b) => a - b)[0];
  const body = { key: lowest === undefined ? null : `${keyPrefix(config)}${lowest}` };
  const invalid = check(schemaFor("tracker", "next")?.stdout ?? {}, { status: "ok", body });
  if (invalid) throw new Error(`invalid next body: ${invalid}`);
  return body;
};

/** Everything is resolved by read-only calls first, so a missing field, option or item fails before the one write. */
const projectUpdate = (config: Config, { project, key, status }: { project: string; key: string; status: string }): { body: Record<string, never> } => {
  if (status === "") throw new Error("an empty status cannot be set on a Project field");
  const n = issueNumber(config, key);
  const own = ["--owner", owner(config)];
  const projectId = ghChecked<{ id: string }>(["project", "view", project, ...own, "--format", "json"], PROJECT_VIEW_SCHEMA).id;
  const fields = ghChecked<{ fields: { id: string; name: string; options?: { id: string; name: string }[] }[] }>(
    ["project", "field-list", project, ...own, "--format", "json", "--limit", "100"], FIELD_LIST_SCHEMA,
  ).fields;
  const field = fields.find((f) => f.name === config.statusField);
  if (!field) throw new Error(`no field ${JSON.stringify(config.statusField)} in project ${project}`);
  const option = field.options?.find((o) => o.name === status);
  if (!option) throw new Error(`field ${JSON.stringify(field.name)} has no option ${JSON.stringify(status)}`);
  const item = repoIssues(config, projectItems(config, project)).find((i) => String(i.content.number) === n);
  if (!item) throw new Error(`issue ${key} is not an item of project ${project}`);
  const args = [
    "project", "item-edit", "--project-id", projectId, "--id", item.id, "--field-id", field.id, "--single-select-option-id", option.id,
  ];
  const result = runGh(args);
  if (result.exitCode !== 0) throw new Crash(ghError(args, result)); // the edit may have been applied
  return { body: {} };
};

/** The open issue with the ready label and the lowest number (gh lists newest first, so sort here). */
const next = (config: Config): TrackerNextBody => {
  if (config.project !== undefined) return projectNext(config, config.project);
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
  if (config.project !== undefined) return projectUpdate(config, { project: config.project, key, status });
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

const FLAGS = ["--repo", "--ready-label", "--status-labels", "--project", "--project-owner", "--status-field"];

/** argv after the script: `[--repo r] [--ready-label l] [--status-labels a,b] [--project n] [--status-field f] <port> <op>`. */
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
  const project = flags["--project"];
  if (project !== undefined && !/^[1-9][0-9]*$/.test(project)) throw new Error(`bad --project: ${JSON.stringify(project)}`);
  const projectOwner = flags["--project-owner"];
  const statusField = flags["--status-field"] ?? "Status";
  if (statusField === "") throw new Error("bad --status-field: empty");
  const [port, op] = positional;
  return { config: { repo: flags["--repo"], readyLabel, statusLabels, project, projectOwner, statusField }, port, op };
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
