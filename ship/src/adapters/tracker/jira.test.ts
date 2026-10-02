// M3.1: the Jira Tracker adapter (read, next), driven as an executable against a fake Jira REST API on Bun.serve.
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { dirname, join } from "node:path";
import type { RunnerStdin } from "../../../src/contracts/common";
import { schemaFor } from "../../../src/contracts/ports";
import { flattenAdf } from "./jira";

const ADAPTER = join(import.meta.dir, "jira.ts");
const ajv = new Ajv();

const EMAIL = "bot@example.com";
const TOKEN = "s3cr3t-T0KEN-value";
const DECOY = "decoy-should-never-leak";
const AUTH = `Basic ${Buffer.from(`${EMAIL}:${TOKEN}`).toString("base64")}`;
const JQL = `project = PROJ AND status = "Ready for Dev" ORDER BY rank ASC`;

type JiraIssue = { summary: string; description: unknown };
/** `search` replaces the /search/jql reply: a JSON body (default `{issues: []}`), a raw text body, or a status. */
type FakeState = {
  issues?: Record<string, JiraIssue>;
  issueStatus?: number;
  search?: { status?: number; body?: unknown; raw?: string };
};
type JiraCall = { method: string; path: string; headers: Record<string, string>; body: string };
type FakeJira = { url: string; calls: () => JiraCall[]; close: () => void };

const servers: FakeJira[] = [];
afterEach(() => {
  for (const server of servers.splice(0)) server.close();
});

/** Routes `/rest/api/3/issue/{key}` and `/rest/api/3/search/jql` only; anything else is a 404. */
const fakeJira = (state: FakeState): FakeJira => {
  const log: JiraCall[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      log.push({ method: req.method, path: url.pathname + url.search, headers: Object.fromEntries(req.headers), body: await req.text() });
      const issueMatch = /^\/rest\/api\/3\/issue\/([^/]+)$/.exec(url.pathname);
      if (req.method === "GET" && issueMatch) {
        if (state.issueStatus) return new Response("{}", { status: state.issueStatus });
        const key = decodeURIComponent(issueMatch[1] ?? "");
        const issue = state.issues?.[key];
        if (!issue) return Response.json({ errorMessages: ["Issue does not exist"] }, { status: 404 });
        return Response.json({ id: "10001", key, fields: { summary: issue.summary, description: issue.description } });
      }
      if (req.method === "GET" && url.pathname === "/rest/api/3/search/jql") {
        const search = state.search ?? {};
        if (search.raw !== undefined) return new Response(search.raw, { status: search.status ?? 200 });
        return Response.json(search.body ?? { issues: [] }, { status: search.status ?? 200 });
      }
      return new Response("not routed", { status: 404 });
    },
  });
  const fake = { url: `http://localhost:${server.port}`, calls: () => [...log], close: () => server.stop(true) };
  servers.push(fake);
  return fake;
};

type Call = { op: string; payload: unknown };
type Out = { exitCode: number; stdout: unknown; stderr: string; text: string };
type Opts = { flags?: string[]; env?: Record<string, string> };

const baseEnv = (): Record<string, string> => ({
  PATH: `${dirname(process.execPath)}:/usr/bin:/bin`, HOME: process.env.HOME ?? "",
  JIRA_EMAIL: EMAIL, JIRA_API_TOKEN: TOKEN, SECRET_DECOY: DECOY,
});

/** Run `tracker/jira.ts [flags] tracker <op>` with a Runner-only Stdin; every reply is checked against the port schema. */
const call = async (fake: FakeJira | null, { op, payload }: Call, opts: Opts = {}): Promise<Out> => {
  const stdin: RunnerStdin = { id: null, delivery: null, port: "tracker", op, workItem: null, workspace: null, payload, tools: [] };
  const flags = opts.flags ?? (fake ? ["--base-url", fake.url, "--jql", JQL] : []);
  const proc = Bun.spawn([process.execPath, ADAPTER, ...flags, "tracker", op], {
    stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe", env: opts.env ?? baseEnv(),
  });
  const [text, stderr, exitCode] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect(text.trim().split("\n")).toHaveLength(1);
  const stdout: unknown = JSON.parse(text);
  const contract = schemaFor("tracker", op);
  if (contract && !ajv.validate(contract.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  expect(text).not.toContain(TOKEN);
  expect(stderr).not.toContain(TOKEN);
  expect(text).not.toContain(DECOY);
  return { exitCode, stdout, stderr, text };
};

const read = (key: string): Call => ({ op: "read", payload: { key } });
const next = (): Call => ({ op: "next", payload: {} });
const ok = (body: unknown) => ({ status: "ok", body });
const failed = expect.objectContaining({ status: "failed", info: expect.stringMatching(/\S/) });
const result = (out: Out) => (expect(out.exitCode).toBe(0), out.stdout);

/** Every request carries the expected Basic auth and none carries the decoy. */
const expectAuthed = (fake: FakeJira) => {
  for (const c of fake.calls()) {
    expect(c.headers.authorization).toBe(AUTH);
    expect(JSON.stringify(c)).not.toContain(DECOY);
  }
};

const para = (...content: unknown[]) => ({ type: "paragraph", content });
const text = (t: string, marks?: unknown[]) => ({ type: "text", text: t, ...(marks ? { marks } : {}) });
const doc = (...content: unknown[]) => ({ type: "doc", version: 1, content });
const li = (...content: unknown[]) => ({ type: "listItem", content });

const DESCRIPTION = doc(
  para(text("Say hello.")),
  { type: "bulletList", content: [li(para(text("to the name"))), li(para(text("politely")))] },
  { type: "codeBlock", attrs: { language: "ts" }, content: [text("greet(\"x\")")] },
);
const FLAT_DESCRIPTION = "Say hello.\n\n- to the name\n- politely\n\n```ts\ngreet(\"x\")\n```";

describe("flattenAdf", () => {
  test.each([
    ["doc joins blocks with a blank line", doc(para(text("a")), para(text("b"))), "a\n\nb"],
    ["paragraph concatenates its content", para(text("a"), text("b"), text(" c")), "ab c"],
    ["text is verbatim, marks dropped", text("**not md** <x>", [{ type: "strong" }, { type: "link", attrs: { href: "h" } }]), "**not md** <x>"],
    ["hardBreak is a newline", para(text("a"), { type: "hardBreak" }, text("b")), "a\nb"],
    ["bulletList gives - lines", { type: "bulletList", content: [li(para(text("x"))), li(para(text("y")))] }, "- x\n- y"],
    ["orderedList renumbers from 1, ignoring attrs.order", { type: "orderedList", attrs: { order: 5 }, content: [li(para(text("x"))), li(para(text("y")))] }, "1. x\n2. y"],
    ["listItem renders inline", li(para(text("x"), text("y"))), "xy"],
    ["codeBlock with language", { type: "codeBlock", attrs: { language: "bash" }, content: [text("ls -la\npwd")] }, "```bash\nls -la\npwd\n```"],
    ["codeBlock without language", { type: "codeBlock", content: [text("x = 1")] }, "```\nx = 1\n```"],
    ["unknown panel gives its nested text", { type: "panel", attrs: { panelType: "info" }, content: [para(text("note"))] }, "note"],
    ["unknown table gives its nested text", { type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [para(text("cell"))] }] }] }, "cell"],
    ["mention with no content gives nothing", para(text("hi "), { type: "mention", attrs: { id: "1", text: "@Ann" } }), "hi "],
    ["emoji with no content gives nothing", para({ type: "emoji", attrs: { shortName: ":smile:" } }), ""],
    ["null is empty", null, ""],
    ["garbage never throws", { type: "doc", content: [42, null, "x", { content: "nope" }] }, ""],
    ["a full description", DESCRIPTION, FLAT_DESCRIPTION],
  ])("%s", (_name, node, expected) => {
    expect(flattenAdf(node)).toBe(expected);
  });
});

describe("tracker/jira adapter: read", () => {
  test("one GET of summary and description; key verbatim, ADF flattened", async () => {
    const fake = fakeJira({ issues: { "PROJ-123": { summary: "Greet by \"name\"", description: DESCRIPTION } } });
    expect(result(await call(fake, read("PROJ-123")))).toEqual(ok({ workItem: { key: "PROJ-123", title: "Greet by \"name\"", body: FLAT_DESCRIPTION } }));
    expect(fake.calls().map((c) => `${c.method} ${c.path}`)).toEqual(["GET /rest/api/3/issue/PROJ-123?fields=summary,description"]);
    expectAuthed(fake);
  });

  test("a null description is an empty body", async () => {
    const fake = fakeJira({ issues: { "PROJ-1": { summary: "S", description: null } } });
    expect(result(await call(fake, read("PROJ-1")))).toEqual(ok({ workItem: { key: "PROJ-1", title: "S", body: "" } }));
  });

  test.each([404, 401, 500])("HTTP %p fails", async (status) => {
    const fake = fakeJira(status === 404 ? {} : { issueStatus: status });
    expect(result(await call(fake, read("PROJ-1")))).toEqual(failed);
  });

  test("an unreachable server fails", async () => {
    const fake = fakeJira({});
    fake.close();
    expect(result(await call(null, read("PROJ-1"), { flags: ["--base-url", fake.url] }))).toEqual(failed);
  });

  test.each(["../PROJ-1", "PROJ 1", "PROJ-1/x", ""])("a malformed key %p fails with no request", async (key) => {
    const fake = fakeJira({});
    expect(result(await call(fake, read(key)))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test("an invalid payload fails with no request", async () => {
    const fake = fakeJira({});
    expect(result(await call(fake, { op: "read", payload: { key: 1 } }))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });
});

describe("tracker/jira adapter: next", () => {
  const issues = (...keys: unknown[]) => ({ issues: keys.map((key) => (key === undefined ? { id: "1" } : { id: "1", key })) });

  test("one GET /search/jql with the JQL verbatim, fields=key and maxResults=1", async () => {
    const fake = fakeJira({ search: { body: issues("PROJ-7") } });
    expect(result(await call(fake, next()))).toEqual(ok({ key: "PROJ-7" }));
    const calls = fake.calls();
    expect(calls).toHaveLength(1);
    const url = new URL(calls[0]?.path ?? "", fake.url);
    expect(`${calls[0]?.method} ${url.pathname}`).toBe("GET /rest/api/3/search/jql");
    expect(url.searchParams.get("jql")).toBe(JQL);
    expect(url.searchParams.get("fields")).toBe("key");
    expect(url.searchParams.get("maxResults")).toBe("1");
    expect(url.searchParams.has("nextPageToken")).toBe(false);
    expect([...url.searchParams.keys()].sort()).toEqual(["fields", "jql", "maxResults"]);
    expectAuthed(fake);
  });

  test.each([
    `project = PROJ AND status = Ready ORDER BY rank ASC`,
    `project = "My Proj" AND labels in ("a b", 'c') AND summary ~ "x=y&z" ORDER BY created DESC, key ASC`,
  ])("the JQL round-trips byte for byte: %p", async (jql) => {
    const fake = fakeJira({ search: { body: issues("PROJ-1") } });
    await call(fake, next(), { flags: ["--base-url", fake.url, "--jql", jql] });
    expect(new URL(fake.calls()[0]?.path ?? "", fake.url).searchParams.get("jql")).toBe(jql);
  });

  test("no issues is a null key", async () => {
    const fake = fakeJira({ search: { body: { issues: [] } } });
    expect(result(await call(fake, next()))).toEqual(ok({ key: null }));
  });

  test("several issues (maxResults ignored) gives issues[0].key unchanged", async () => {
    const served = issues("PROJ-9", "PROJ-2", "PROJ-5");
    for (const issue of served.issues) expect(issue).toHaveProperty("key");
    const fake = fakeJira({ search: { body: served } });
    expect(result(await call(fake, next()))).toEqual(ok({ key: "PROJ-9" }));
  });

  test("a nextPageToken is ignored and never followed; no count field is needed", async () => {
    const body = { ...issues("PROJ-3"), nextPageToken: "tok-2" };
    expect(Object.keys(body).sort()).toEqual(["issues", "nextPageToken"]);
    const fake = fakeJira({ search: { body } });
    expect(result(await call(fake, next()))).toEqual(ok({ key: "PROJ-3" }));
    expect(fake.calls()).toHaveLength(1);
  });

  test.each([
    ["500", { status: 500, body: { errorMessages: ["boom"] } }],
    ["400 bad JQL", { status: 400, body: { errorMessages: ["Error in the JQL Query"] } }],
    ["no issues array", { body: { values: [] } }],
    ["issues not an array", { body: { issues: { key: "PROJ-1" } } }],
    ["keyless issue", { body: issues(undefined) }],
    ["non-string key", { body: issues(123) }],
    ["key failing KEY_RE", { body: issues("../etc") }],
    ["a non-JSON body", { raw: "<html>gateway</html>" }],
  ])("%s fails, never guessing a key", async (_name, search) => {
    const fake = fakeJira({ search });
    expect(result(await call(fake, next()))).toEqual(failed);
    expect(fake.calls()).toHaveLength(1);
  });

  test("a missing --jql fails with no request", async () => {
    const fake = fakeJira({ search: { body: issues("PROJ-1") } });
    expect(result(await call(fake, next(), { flags: ["--base-url", fake.url] }))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });
});

describe("tracker/jira adapter: config and env", () => {
  const ISSUE = { issues: { "PROJ-1": { summary: "S", description: null } } };

  test("JIRA_BASE_URL is used without --base-url", async () => {
    const fake = fakeJira(ISSUE);
    const out = await call(fake, read("PROJ-1"), { flags: [], env: { ...baseEnv(), JIRA_BASE_URL: fake.url } });
    expect(result(out)).toEqual(ok({ workItem: { key: "PROJ-1", title: "S", body: "" } }));
    expectAuthed(fake);
  });

  test("--base-url wins over JIRA_BASE_URL", async () => {
    const used = fakeJira(ISSUE);
    const ignored = fakeJira(ISSUE);
    await call(used, read("PROJ-1"), { flags: ["--base-url", used.url], env: { ...baseEnv(), JIRA_BASE_URL: ignored.url } });
    expect(used.calls()).toHaveLength(1);
    expect(ignored.calls()).toEqual([]);
  });

  test("no base URL at all fails with no request", async () => {
    const fake = fakeJira(ISSUE);
    expect(result(await call(fake, read("PROJ-1"), { flags: ["--jql", JQL] }))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test.each(["JIRA_EMAIL", "JIRA_API_TOKEN"])("missing %s fails with no request", async (name) => {
    const fake = fakeJira(ISSUE);
    const env = baseEnv();
    delete env[name];
    expect(result(await call(fake, read("PROJ-1"), { env }))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test("the decoy env var reaches neither the server nor the output", async () => {
    const fake = fakeJira({ ...ISSUE, search: { body: { issues: [{ key: "PROJ-1" }] } } });
    await call(fake, read("PROJ-1"));
    await call(fake, next());
    expect(fake.calls()).toHaveLength(2);
    expectAuthed(fake);
  });

  test("a failed reply never carries the token", async () => {
    const fake = fakeJira({ issueStatus: 401, search: { status: 400, raw: `bad ${TOKEN}` } });
    expect(result(await call(fake, read("PROJ-1")))).toEqual(failed);
    expect(result(await call(fake, next()))).toEqual(failed);
  });

  test("jira.ts reads process.env only for JIRA_BASE_URL, JIRA_EMAIL and JIRA_API_TOKEN", async () => {
    const source = await Bun.file(ADAPTER).text();
    const reads = [...source.matchAll(/process\.env(?:\.([A-Za-z_]+)|\[)?/g)].map((m) => m[1] ?? "<dynamic>");
    expect(reads.length).toBeGreaterThan(0);
    expect(new Set(reads)).toEqual(new Set(["JIRA_BASE_URL", "JIRA_EMAIL", "JIRA_API_TOKEN"]));
  });

  test("an unknown op fails", async () => {
    const fake = fakeJira(ISSUE);
    expect(result(await call(fake, { op: "close", payload: {} }))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test("cancel is ok {} with no request", async () => {
    const fake = fakeJira(ISSUE);
    expect(result(await call(fake, { op: "cancel", payload: { target: "harlo-1-1/tracker-1" } }))).toEqual(ok({}));
    expect(fake.calls()).toEqual([]);
  });
});
