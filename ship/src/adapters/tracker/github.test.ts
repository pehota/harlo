// M2.4: the GitHub issues Tracker adapter, driven as an executable against a fake `gh` on PATH.
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Stdin, WorkItem } from "../../../src/contracts/common";
import { schemaFor } from "../../../src/contracts/ports";
import { workItem as baseWorkItem } from "../../../src/core/fixtures/builders.fixture";

const ADAPTER = join(import.meta.dir, "github.ts");
const ajv = new Ajv();

type Issue = { title: string; body: string; labels: string[]; state?: "open" | "closed"; comments?: string[] };
type FakeState = { repo: string; issues: Record<string, Issue>; fail?: string[]; failEditAfterAdd?: boolean; failCleanup?: boolean };
type GhCall = { argv: string[]; stdin: string; env: string[] };

// The fake `gh`: logs every call to calls.jsonl, serves and mutates issues in state.json.
// `fail` lists "<cmd> <sub>" pairs that exit 1 untouched; `failEditAfterAdd` applies the adds, then exits 1;
// `failCleanup` makes an edit without adds (the cleanup retry) exit 1 untouched.
const FAKE_GH = `
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
const [dir, ...argv] = process.argv.slice(2);
const stdin = argv.includes("--body-file") ? await Bun.stdin.text() : "";
appendFileSync(dir + "/calls.jsonl", JSON.stringify({ argv, stdin, env: Object.keys(process.env).sort() }) + "\\n");
const state = JSON.parse(readFileSync(dir + "/state.json", "utf8"));
const save = () => writeFileSync(dir + "/state.json", JSON.stringify(state));
const flag = (name) => { const at = argv.indexOf(name); return at === -1 ? undefined : argv[at + 1]; };
const flags = (name) => argv.flatMap((arg, i) => (arg === name ? [argv[i + 1]] : []));
const die = (msg) => { console.error(msg); process.exit(1); };
const [cmd, sub, n] = argv;
if ((state.fail ?? []).includes(cmd + " " + sub)) die("boom: " + cmd + " " + sub);
if (cmd === "repo" && sub === "view") { console.log(JSON.stringify({ nameWithOwner: state.repo })); process.exit(0); }
if (cmd !== "issue") die("unknown command " + cmd);
if (sub !== "list" && flag("--repo") !== state.repo) die("wrong repo " + flag("--repo"));
const issue = state.issues[n];
if (sub === "view") {
  if (!issue) die("no issue " + n);
  const out = { number: Number(n), title: issue.title, body: issue.body, labels: issue.labels.map((name) => ({ name })) };
  console.log(JSON.stringify(Object.fromEntries(flag("--json").split(",").map((f) => [f, out[f]]))));
} else if (sub === "list") {
  const label = flag("--label");
  const numbers = Object.keys(state.issues).map(Number).sort((a, b) => b - a) // newest first, like gh
    .filter((k) => (state.issues[k].state ?? "open") === "open" && state.issues[k].labels.includes(label));
  console.log(JSON.stringify(numbers.map((number) => ({ number }))));
} else if (sub === "edit") {
  if (!issue) die("no issue " + n);
  for (const label of flags("--add-label")) if (!issue.labels.includes(label)) issue.labels.push(label);
  if (state.failCleanup && flags("--add-label").length === 0) die("boom cleanup");
  if (state.failEditAfterAdd && flags("--add-label").length > 0) { save(); die("boom after add"); }
  issue.labels = issue.labels.filter((label) => !flags("--remove-label").includes(label));
  save();
} else if (sub === "comment") {
  if (!issue) die("no issue " + n);
  (issue.comments ??= []).push(stdin);
  save();
} else die("unknown issue op " + sub);
`;

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

type Fake = { dir: string; bin: string; state: () => FakeState; calls: () => GhCall[] };

const fakeGh = (state: FakeState): Fake => {
  const dir = mkdtempSync(join(tmpdir(), "ship-github-"));
  dirs.push(dir);
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(join(dir, "fake-gh.ts"), FAKE_GH);
  writeFileSync(join(dir, "state.json"), JSON.stringify(state));
  writeFileSync(join(dir, "calls.jsonl"), "");
  writeFileSync(join(bin, "gh"), `#!/bin/sh\nexec "${process.execPath}" "${join(dir, "fake-gh.ts")}" "${dir}" "$@"\n`);
  chmodSync(join(bin, "gh"), 0o755);
  return {
    dir,
    bin,
    state: () => JSON.parse(readFileSync(join(dir, "state.json"), "utf8")) as FakeState,
    calls: () => readFileSync(join(dir, "calls.jsonl"), "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line) as GhCall),
  };
};

const workItemFor = (key: string): WorkItem => ({ ...baseWorkItem, key });

type Call = { op: string; payload: unknown; workItem?: WorkItem | null };
type Out = { exitCode: number; stdout: unknown };
type Opts = { flags?: string[]; path?: string; extraEnv?: Record<string, string> };

/** Run `tracker/github.ts [flags] tracker <op>` with a Stdin envelope, as the Runner does. */
const call = async (fake: Fake, { op, payload, workItem = null }: Call, opts: Opts = {}): Promise<Out> => {
  const stdin: Stdin = {
    id: "harlo-1-1/tracker-1", delivery: "harlo-1-1", port: "tracker", op,
    workItem: workItem ?? workItemFor("harlo-1"), workspace: null, payload, tools: [],
  };
  const flags = opts.flags ?? ["--repo", "acme/harlo", "--status-labels", "in_progress,in_review,done"];
  const proc = Bun.spawn([process.execPath, ADAPTER, ...flags, "tracker", op], {
    stdin: new Blob([JSON.stringify(stdin)]),
    stdout: "pipe",
    stderr: "pipe",
    cwd: fake.dir,
    env: { PATH: opts.path ?? `${fake.bin}:${dirname(process.execPath)}:/usr/bin:/bin`, HOME: process.env.HOME ?? "", ...opts.extraEnv },
  });
  const [text, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  if (exitCode !== 0) return { exitCode, stdout: text };
  const stdout: unknown = JSON.parse(text);
  const contract = schemaFor("tracker", op);
  if (contract && !ajv.validate(contract.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  return { exitCode, stdout };
};

const read = (key: string): Call => ({ op: "read", payload: { key } });
const next = (): Call => ({ op: "next", payload: {} });
const update = (key: string, status: string): Call => ({ op: "update", payload: { status }, workItem: workItemFor(key) });
const comment = (key: string, text: string): Call => ({ op: "comment", payload: { text }, workItem: workItemFor(key) });
const ok = (body: unknown) => ({ exitCode: 0, stdout: { status: "ok", body } });
const failed = { exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) };

const ISSUE_7: Issue = { title: "Greet by \"name\"", body: "Say hello.\n\n- [ ] to the given name", labels: ["ready", "bug"] };
const base = (): FakeState => ({
  repo: "acme/harlo",
  issues: {
    "7": structuredClone(ISSUE_7),
    "3": { title: "Three", body: "", labels: ["ready"] },
    "2": { title: "Two", body: "", labels: ["ready"], state: "closed" },
    "1": { title: "One", body: "", labels: ["in_progress"] },
  },
});
const ghOps = (fake: Fake): string[] => fake.calls().map(({ argv }) => `${argv[0]} ${argv[1]}`);

describe("tracker/github adapter", () => {
  test("read: key <repo>-<n>, title and body verbatim", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, read("harlo-7"))).toEqual(ok({ workItem: { key: "harlo-7", title: ISSUE_7.title, body: ISSUE_7.body } }));
    expect(fake.calls()[0]?.argv).toEqual(["issue", "view", "7", "--repo", "acme/harlo", "--json", "title,body"]);
  });

  test("read: without --repo the repo is resolved via gh repo view", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, read("harlo-7"), { flags: [] })).toEqual(ok({ workItem: { key: "harlo-7", title: ISSUE_7.title, body: ISSUE_7.body } }));
    expect(ghOps(fake)).toEqual(["repo view", "issue view"]);
  });

  test.each(["harlo", "harlo-", "harlo-x", "harlo-07", "other-7", "../harlo-7", "harlo-7/"])("read: malformed key %p fails without reaching gh", async (key) => {
    const fake = fakeGh(base());
    expect(await call(fake, read(key))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test("read: gh failure (missing issue) fails", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, read("harlo-99"))).toEqual(failed);
  });

  test("read: no gh on PATH fails", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, read("harlo-7"), { path: join(fake.dir, "empty") })).toEqual(failed);
  });

  test("next: lowest-numbered open issue with the ready label", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, next())).toEqual(ok({ key: "harlo-3" }));
    expect(fake.calls()[0]?.argv).toEqual(expect.arrayContaining(["issue", "list", "--label", "ready", "--state", "open"]));
  });

  test("next: custom ready label", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, next(), { flags: ["--repo", "acme/harlo", "--ready-label", "in_progress"] })).toEqual(ok({ key: "harlo-1" }));
    expect(fake.calls()[0]?.argv).toEqual(expect.arrayContaining(["--label", "in_progress"]));
  });

  test("next: null when nothing matches", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, next(), { flags: ["--repo", "acme/harlo", "--ready-label", "nope"] })).toEqual(ok({ key: null }));
  });

  test("next: gh failure fails", async () => {
    const fake = fakeGh({ ...base(), fail: ["issue list"] });
    expect(await call(fake, next())).toEqual(failed);
  });

  test("update: adds the status, removes other status labels, leaves the rest", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, update("harlo-7", "in_progress"))).toEqual(ok({}));
    expect(fake.state().issues["7"]?.labels).toEqual(["bug", "in_progress"]);
    expect(fake.calls().at(-1)?.argv).toEqual(["issue", "edit", "7", "--repo", "acme/harlo", "--add-label", "in_progress", "--remove-label", "ready"]);
    expect(await call(fake, update("harlo-7", "done"))).toEqual(ok({}));
    expect(fake.state().issues["7"]?.labels).toEqual(["bug", "done"]);
  });

  test("update: an already-set status is a no-op with no edit", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, update("harlo-1", "in_progress"))).toEqual(ok({}));
    expect(ghOps(fake)).toEqual(["issue view"]);
  });

  test("update: empty status clears the status labels only", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, update("harlo-7", ""))).toEqual(ok({}));
    expect(fake.state().issues["7"]?.labels).toEqual(["bug"]);
    expect(fake.calls().at(-1)?.argv).toEqual(["issue", "edit", "7", "--repo", "acme/harlo", "--remove-label", "ready"]);
  });

  test("update: a status outside the configured set fails before any gh call", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, update("harlo-7", "bug"))).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test("update: invalid key and invalid payload fail without reaching gh", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, update("other-7", "done"))).toEqual(failed);
    expect(await call(fake, { op: "update", payload: { status: 1 }, workItem: workItemFor("harlo-7") })).toEqual(failed);
    expect(fake.calls()).toEqual([]);
  });

  test("update: an edit that changed nothing fails", async () => {
    const fake = fakeGh({ ...base(), fail: ["issue edit"] });
    expect(await call(fake, update("harlo-7", "done"))).toEqual(failed);
    expect(fake.state().issues["7"]?.labels).toEqual(["ready", "bug"]);
  });

  test("update: an edit that failed after the add is cleaned up by a narrower retry, leaving one status label", async () => {
    const fake = fakeGh({ ...base(), failEditAfterAdd: true });
    expect(await call(fake, update("harlo-7", "done"))).toEqual(ok({}));
    expect(fake.state().issues["7"]?.labels).toEqual(["bug", "done"]);
    expect(fake.calls().at(-1)?.argv).toEqual(["issue", "edit", "7", "--repo", "acme/harlo", "--remove-label", "ready"]);
  });

  test("update: after a successful cleanup the issue is out of next's ready query", async () => {
    const fake = fakeGh({ ...base(), failEditAfterAdd: true });
    await call(fake, update("harlo-7", "done"));
    expect(fake.state().issues["7"]?.labels).not.toContain("ready");
  });

  test("update: an edit that failed midway and whose cleanup fails is ok with partial evidence, not failed", async () => {
    const fake = fakeGh({ ...base(), failEditAfterAdd: true, failCleanup: true });
    const result = await call(fake, update("harlo-7", "done"));
    expect(result).toEqual({
      exitCode: 0,
      stdout: { status: "ok", body: {}, evidence: [expect.objectContaining({ label: "partial" })] },
    });
    expect(fake.state().issues["7"]?.labels).toEqual(["ready", "bug", "done"]);
  });

  test("comment: text with quotes, newlines and leading dashes arrives intact via stdin", async () => {
    const fake = fakeGh(base());
    const text = "--body \"quoted\" 'single'\n\n-x $HOME `tick`\n";
    expect(await call(fake, comment("harlo-7", text))).toEqual(ok({}));
    expect(fake.state().issues["7"]?.comments).toEqual([text]);
    expect(fake.calls().at(-1)).toEqual(expect.objectContaining({
      argv: ["issue", "comment", "7", "--repo", "acme/harlo", "--body-file", "-"], stdin: text,
    }));
  });

  test("comment: a gh failure after it may have posted is a crash, never failed", async () => {
    const fake = fakeGh({ ...base(), fail: ["issue comment"] });
    expect((await call(fake, comment("harlo-7", "hi"))).exitCode).not.toBe(0);
  });

  test("comment: no gh on PATH fails (nothing ran)", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, comment("harlo-7", "hi"), { path: join(fake.dir, "empty") })).toEqual(failed);
  });

  test("W1: update/comment never edit title or body; read after writes is unchanged", async () => {
    const fake = fakeGh(base());
    const before = await call(fake, read("harlo-7"));
    await call(fake, update("harlo-7", "in_progress"));
    await call(fake, comment("harlo-7", "started"));
    await call(fake, update("harlo-7", ""));
    await call(fake, comment("harlo-7", "--title x"));
    await call(fake, update("harlo-7", "done"));
    expect(await call(fake, read("harlo-7"))).toEqual(before);
    const writes = fake.calls().filter(({ argv }) => argv[1] === "edit" || argv[1] === "comment");
    expect(writes.length).toBe(5);
    for (const { argv } of writes) {
      expect(argv).not.toContain("--title");
      expect(argv).not.toContain("--body");
      if (argv[1] === "edit") expect(argv.every((arg) => !arg.startsWith("--") || ["--repo", "--add-label", "--remove-label"].includes(arg))).toBe(true);
    }
  });

  test("env: gh sees only PATH, HOME and GH_TOKEN", async () => {
    const fake = fakeGh(base());
    await call(fake, read("harlo-7"), { extraEnv: { GH_TOKEN: "t0k", LEAKED_SECRET: "x", GH_REPO: "evil/repo" } });
    const env = (fake.calls()[0]?.env ?? []).filter((name) => !["PWD", "SHLVL", "_", "OLDPWD"].includes(name));
    expect(env).toEqual(["GH_TOKEN", "HOME", "PATH"]);
  });

  test("unknown op fails", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, { op: "close", payload: {} })).toEqual(failed);
  });

  test("cancel has nothing to cancel: ok {}", async () => {
    const fake = fakeGh(base());
    expect(await call(fake, { op: "cancel", payload: { target: "harlo-1-1/tracker-1" } })).toEqual(ok({}));
    expect(fake.calls()).toEqual([]);
  });
});
