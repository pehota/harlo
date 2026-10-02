#!/usr/bin/env bun
// Jira Cloud Tracker adapter (plan §6 M3.1): `read` and `next` over the REST API v3, via fetch.
// argv: [--base-url <url>] [--jql <query>] tracker <op>; stdin: Stdin (§3.1); stdout: one Result JSON line.
// Base URL: --base-url, else JIRA_BASE_URL; neither is `failed` before any request.
// Auth: Basic base64(JIRA_EMAIL:JIRA_API_TOKEN). The environment is read for those three names only, and the
// token never appears in a reply.
// read: GET /rest/api/3/issue/{key}?fields=summary,description → {key (verbatim), title: summary,
// body: the ADF description flattened to plain text ("" when null)}.
// next: GET /rest/api/3/search/jql?jql=<--jql verbatim>&fields=key&maxResults=1 → issues[0].key, or null when
// none match. Only the first page is read: a returned nextPageToken is never followed and no result count is read.
// --jql must include ORDER BY for `next` to be deterministic; it is passed through unchanged, never rewritten.
// update and comment are M3.2; until then they are unsupported (`failed`).
import type { WorkItem } from "../../../src/contracts/common";
import type { TrackerNextBody, TrackerReadBody, TrackerReadPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { check } from "../../../src/contracts/validate";
import { KEY_RE } from "../../../src/core/ids";

type Config = { baseUrl: string | undefined; jql: string | undefined };
type Node = { type?: unknown; text?: unknown; attrs?: { language?: unknown }; content?: unknown };

const nodesOf = (node: Node): Node[] =>
  Array.isArray(node.content) ? node.content.filter((child): child is Node => typeof child === "object" && child !== null) : [];

const blocks = (parts: string[]): string => parts.filter((part) => part !== "").join("\n\n");

/** ADF → plain text. Total: an unknown node gives its nested text (or nothing), and nothing throws. */
export const flattenAdf = (node: unknown): string => {
  if (typeof node !== "object" || node === null) return "";
  const n = node as Node;
  const children = nodesOf(n);
  const inline = (): string => children.map(flattenAdf).join("");
  const items = (marker: (i: number) => string): string =>
    children.map((item, i) => `${marker(i)}${flattenAdf(item)}`).join("\n");
  switch (n.type) {
    case "text": return typeof n.text === "string" ? n.text : "";
    case "hardBreak": return "\n";
    case "doc": return blocks(children.map(flattenAdf));
    case "paragraph": return inline();
    case "bulletList": return items(() => "- ");
    case "orderedList": return items((i) => `${i + 1}. `);
    case "listItem": return children.map(flattenAdf).filter((part) => part !== "").join("\n").replaceAll("\n", "\n  ");
    case "codeBlock": {
      const language = typeof n.attrs?.language === "string" ? n.attrs.language : "";
      return `\`\`\`${language}\n${inline()}\n\`\`\``;
    }
    default: // panel, table, heading, mention, emoji, ...: block children are separated, inline ones concatenated
      return children.some((child) => Array.isArray(child.content)) ? blocks(children.map(flattenAdf)) : inline();
  }
};

const secret = (): string => process.env.JIRA_API_TOKEN ?? "";

/** One authenticated GET; any non-2xx or non-JSON reply throws (`failed`), with the token never in the message. */
const getJson = async (config: Config, pathAndQuery: string): Promise<unknown> => {
  const base = (config.baseUrl ?? process.env.JIRA_BASE_URL ?? "").replace(/\/+$/, "");
  if (!/^https?:\/\/[^/]/.test(base)) throw new Error("no Jira base URL: set --base-url or JIRA_BASE_URL");
  const email = process.env.JIRA_EMAIL;
  if (!email || !secret()) throw new Error("JIRA_EMAIL and JIRA_API_TOKEN must be set");
  const route = pathAndQuery.split("?")[0];
  const response = await fetch(`${base}${pathAndQuery}`, {
    headers: { Authorization: `Basic ${Buffer.from(`${email}:${secret()}`).toString("base64")}`, Accept: "application/json" },
    signal: AbortSignal.timeout(30_000),
  });
  const text = await response.text();
  if (!response.ok) {
    let detail = "";
    try {
      const messages = (JSON.parse(text) as { errorMessages?: unknown }).errorMessages;
      if (Array.isArray(messages)) detail = `: ${messages.filter((m) => typeof m === "string").join("; ")}`;
    } catch { /* a non-JSON error body is not echoed */ }
    throw new Error(`GET ${route} returned HTTP ${response.status}${detail}`);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`GET ${route} returned a non-JSON body`);
  }
};

const read = async (config: Config, { key }: TrackerReadPayload): Promise<TrackerReadBody> => {
  if (!KEY_RE.test(key)) throw new Error(`not a tracker key: ${JSON.stringify(key)}`);
  const issue = await getJson(config, `/rest/api/3/issue/${encodeURIComponent(key)}?fields=summary,description`) as
    { fields?: { summary?: unknown; description?: unknown } };
  const summary = issue?.fields?.summary;
  if (typeof summary !== "string") throw new Error(`issue ${key} has no summary`);
  return { workItem: { key, title: summary, body: flattenAdf(issue.fields?.description) } satisfies WorkItem };
};

const next = async (config: Config): Promise<TrackerNextBody> => {
  if (config.jql === undefined || config.jql.trim() === "") throw new Error("next needs --jql");
  const query = new URLSearchParams({ jql: config.jql, fields: "key", maxResults: "1" });
  const page = await getJson(config, `/rest/api/3/search/jql?${query}`) as { issues?: unknown };
  if (!Array.isArray(page?.issues)) throw new Error("search/jql reply has no issues array");
  if (page.issues.length === 0) return { key: null };
  const key = (page.issues[0] as { key?: unknown } | null)?.key;
  if (typeof key !== "string" || !KEY_RE.test(key)) throw new Error(`search/jql returned an issue without a valid key: ${JSON.stringify(key)}`);
  return { key };
};

type Stdin = { payload?: unknown };

const ops: Record<string, (config: Config, stdin: Stdin) => Promise<{ body: unknown }>> = {
  read: async (config, stdin) => ({ body: await read(config, stdin.payload as TrackerReadPayload) }),
  next: async (config) => ({ body: await next(config) }),
  cancel: async () => ({ body: {} }), // every request is awaited within the call, so there is never anything to cancel
};

const FLAGS = ["--base-url", "--jql"];

/** argv after the script: `[--base-url u] [--jql q] <port> <op>`. */
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
  const [port, op] = positional;
  return { config: { baseUrl: flags["--base-url"], jql: flags["--jql"] }, port, op };
};

const run = async (): Promise<{ body: unknown }> => {
  const { config, port, op } = parseArgs(process.argv.slice(2));
  const contract = port === "tracker" && op ? schemaFor("tracker", op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return handler(config, stdin);
};

if (import.meta.main) {
  try {
    const { body } = await run();
    console.log(JSON.stringify({ status: "ok", body }));
  } catch (error) {
    const info = error instanceof Error ? error.message : String(error);
    console.log(JSON.stringify({ status: "failed", info: secret() ? info.replaceAll(secret(), "***") : info }));
  }
}
