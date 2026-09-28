// M1.2/M1.3: the md-file Tracker adapter, driven as an executable (JSON piped into stdin, one JSON line out).
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../src/contracts/common";
import { schemaFor } from "../../src/contracts/ports";
import { workItem as baseWorkItem } from "../../src/core/fixtures/builders.fixture";

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
