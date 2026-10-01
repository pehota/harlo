// M1.2/M1.3: the md-file Tracker adapter, driven as an executable (JSON piped into stdin, one JSON line out).
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../../src/contracts/common";
import { schemaFor } from "../../../src/contracts/ports";
import { workItem as baseWorkItem } from "../../../src/core/fixtures/builders.fixture";

const ADAPTER = join(import.meta.dir, "md.ts");
const ajv = new Ajv();

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-tracker-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const workItemFor = (key: string): WorkItem => ({ ...baseWorkItem, key });

type Call = { op: string; payload: unknown; workItem?: WorkItem | null };
type Out = { exitCode: number; stdout: unknown };

/** Run `tracker/md.ts --dir <dir> tracker <op>` with a Stdin envelope, as the Runner does. */
const call = async (dirArg: string, { op, payload, workItem = null }: Call): Promise<Out> => {
  const stdin: Stdin = {
    id: "PROJ-1-1/tracker-1", delivery: "PROJ-1-1", port: "tracker", op,
    workItem: workItem ?? workItemFor("PROJ-1"), workspace: null, payload, tools: [],
  };
  const proc = Bun.spawn(["bun", ADAPTER, "--dir", dirArg, "tracker", op], {
    stdin: new Blob([JSON.stringify(stdin)]),
    stdout: "pipe",
    stderr: "pipe",
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" },
  });
  const [text, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
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

const write = (dir: string, name: string, content: string): void => writeFileSync(join(dir, name), content);

const READY = `---
status: ready
---
# Greet by name

Say hello to the given name.

<!-- ship:log -->
`;

const TITLED = `---
status: ready
title: Custom Title
---
# Fallback H1

Body text here.

<!-- ship:log -->
`;

describe("tracker/md adapter", () => {
  test("read: title from H1 when frontmatter has none", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    expect(await call(dir, read("PROJ-1"))).toEqual(
      ok({ workItem: { key: "PROJ-1", title: "Greet by name", body: "# Greet by name\n\nSay hello to the given name." } }),
    );
  });

  test("read: frontmatter title overrides the H1", async () => {
    const dir = tempDir();
    write(dir, "PROJ-2.md", TITLED);
    expect(await call(dir, read("PROJ-2"))).toEqual(
      ok({ workItem: { key: "PROJ-2", title: "Custom Title", body: "# Fallback H1\n\nBody text here." } }),
    );
  });

  test("read: unknown key fails", async () => {
    const dir = tempDir();
    const result = await call(dir, read("MISSING"));
    expect(result).toEqual({ exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) });
  });

  test("next: first file (by filename) with status: ready", async () => {
    const dir = tempDir();
    write(dir, "PROJ-2.md", "---\nstatus: draft\n---\n# Two\n\n<!-- ship:log -->\n");
    write(dir, "PROJ-1.md", READY);
    write(dir, "PROJ-3.md", TITLED);
    expect(await call(dir, next())).toEqual(ok({ key: "PROJ-1" }));
  });

  test("next: null when none ready", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", "---\nstatus: draft\n---\n# One\n\n<!-- ship:log -->\n");
    expect(await call(dir, next())).toEqual(ok({ key: null }));
  });

  test("next: empty dir gives null", async () => {
    const dir = tempDir();
    expect(await call(dir, next())).toEqual(ok({ key: null }));
  });

  test("update: rewrites only frontmatter status; title/body byte-identical", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    expect(await call(dir, update("PROJ-1", "in_progress"))).toEqual(ok({}));
    const raw = readFileSync(join(dir, "PROJ-1.md"), "utf8");
    expect(raw).toBe(`---
status: in_progress
---
# Greet by name

Say hello to the given name.

<!-- ship:log -->
`);
    expect(await call(dir, read("PROJ-1"))).toEqual(
      ok({ workItem: { key: "PROJ-1", title: "Greet by name", body: "# Greet by name\n\nSay hello to the given name." } }),
    );
  });

  test("comment: appends below the marker, body unchanged before/after", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    const before = await call(dir, read("PROJ-1"));
    expect(await call(dir, comment("PROJ-1", "checked in, all good"))).toEqual(ok({}));
    const after = await call(dir, read("PROJ-1"));
    expect(after).toEqual(before);
    const raw = readFileSync(join(dir, "PROJ-1.md"), "utf8");
    expect(raw).toBe(`---
status: ready
---
# Greet by name

Say hello to the given name.

<!-- ship:log -->
checked in, all good
`);
  });

  test("comment: a second comment appends again, still below the marker", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    await call(dir, comment("PROJ-1", "first"));
    await call(dir, comment("PROJ-1", "second"));
    const raw = readFileSync(join(dir, "PROJ-1.md"), "utf8");
    expect(raw.endsWith("<!-- ship:log -->\nfirst\nsecond\n")).toBe(true);
  });

  test("update: unknown key fails, writes nothing", async () => {
    const dir = tempDir();
    const result = await call(dir, update("MISSING", "ready"));
    expect(result).toEqual({ exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) });
    expect(existsSync(join(dir, "MISSING.md"))).toBe(false);
  });

  test("cancel has nothing to cancel: ok {}", async () => {
    const dir = tempDir();
    expect(await call(dir, { op: "cancel", payload: { target: "PROJ-1-1/land-1" } })).toEqual(ok({}));
  });
});

// Git history of the tracker dir (docs/dogfood.md): lazily initialised, one commit per mutation.
describe("tracker/md adapter: git history", () => {
  const git = (dir: string, ...args: string[]): string => {
    const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
    return proc.stdout.toString().trim();
  };
  const log = (dir: string): string[] => git(dir, "log", "--format=%s").split("\n").filter(Boolean);

  /** Like `call`, but with a chosen PATH and the raw stdout/stderr, to prove git trouble never reaches stdout. */
  const callRaw = async (dir: string, c: Call, env: Record<string, string>) => {
    const stdin: Stdin = {
      id: "PROJ-1-1/tracker-1", delivery: "PROJ-1-1", port: "tracker", op: c.op,
      workItem: c.workItem ?? workItemFor("PROJ-1"), workspace: null, payload: c.payload, tools: [],
    };
    const proc = Bun.spawn([process.execPath, ADAPTER, "--dir", dir, "tracker", c.op], {
      stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe", env,
    });
    const [stdout, stderr] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
    return { stdout, stderr };
  };

  test("first write inits a repo in the tracker dir with a fallback identity and imports existing files", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    write(dir, "PROJ-2.md", TITLED);
    const home = tempDir(); // no global git config
    const { stdout } = await callRaw(dir, update("PROJ-1", "in_progress"), { PATH: process.env.PATH ?? "", HOME: home });
    expect(JSON.parse(stdout)).toEqual({ status: "ok", body: {} });
    expect(existsSync(join(dir, ".git"))).toBe(true);
    expect(log(dir)).toEqual(["update PROJ-1: status in_progress", "tracker: initial import of existing WorkItems"]);
    expect(git(dir, "show", "HEAD~1:PROJ-2.md")).toBe(TITLED.trim());
    expect(git(dir, "show", "HEAD~1:PROJ-1.md")).toBe(READY.trim()); // original content captured before the mutation
  });

  test("init is idempotent and never touches a parent repo", async () => {
    const parent = tempDir();
    Bun.spawnSync(["git", "-C", parent, "init", "--quiet"]);
    const dir = join(parent, "tracker");
    Bun.spawnSync(["mkdir", dir]);
    write(dir, "PROJ-1.md", READY);
    await call(dir, update("PROJ-1", "a"));
    await call(dir, update("PROJ-1", "b"));
    expect(existsSync(join(dir, ".git"))).toBe(true);
    expect(git(parent, "rev-list", "--all", "--count")).toBe("0");
    expect(log(dir)).toEqual(["update PROJ-1: status b", "update PROJ-1: status a", "tracker: initial import of existing WorkItems"]);
  });

  test("each mutation is exactly one commit with only the changed file; reads commit nothing", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    await call(dir, update("PROJ-1", "in_progress"));
    const before = log(dir).length;
    await call(dir, read("PROJ-1"));
    await call(dir, next());
    expect(log(dir).length).toBe(before);
    await call(dir, comment("PROJ-1", "hello"));
    expect(log(dir).length).toBe(before + 1);
    expect(log(dir)[0]).toBe("comment PROJ-1");
    expect(git(dir, "show", "--name-only", "--format=", "HEAD")).toBe("PROJ-1.md");
  });

  test("a no-op write makes no empty commit and no error", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    await call(dir, update("PROJ-1", "ready")); // already ready
    expect(await call(dir, update("PROJ-1", "ready"))).toEqual(ok({}));
    expect(log(dir)).toEqual(["tracker: initial import of existing WorkItems"]);
  });

  test("a manually removed file is recoverable from the last commit", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    await call(dir, comment("PROJ-1", "note"));
    const committed = readFileSync(join(dir, "PROJ-1.md"), "utf8");
    rmSync(join(dir, "PROJ-1.md"));
    git(dir, "checkout", "HEAD", "--", "PROJ-1.md");
    expect(readFileSync(join(dir, "PROJ-1.md"), "utf8")).toBe(committed);
  });

  test("git missing: the op succeeds, a warning goes to stderr, stdout is one clean Result line", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    const empty = tempDir();
    const { stdout, stderr } = await callRaw(dir, update("PROJ-1", "in_progress"), { PATH: empty, HOME: empty });
    expect(JSON.parse(stdout)).toEqual({ status: "ok", body: {} });
    expect(stdout.trim().split("\n")).toHaveLength(1);
    expect(stderr).toContain("warning");
    expect(readFileSync(join(dir, "PROJ-1.md"), "utf8")).toContain("status: in_progress");
  });

  test("a failing commit (rejecting hook is bypassed; broken repo is not) still succeeds with a warning", async () => {
    const dir = tempDir();
    write(dir, "PROJ-1.md", READY);
    await call(dir, update("PROJ-1", "a"));
    writeFileSync(join(dir, ".git", "HEAD"), "garbage");
    const { stdout, stderr } = await callRaw(dir, comment("PROJ-1", "x"), { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" });
    expect(JSON.parse(stdout)).toEqual({ status: "ok", body: {} });
    expect(stderr).toContain("warning");
  });
});
