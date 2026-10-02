// M1.1: the git-worktree Workspace adapter, driven as an executable (JSON piped into stdin, one JSON line out).
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../../src/contracts/common";
import { schemaFor } from "../../../src/contracts/ports";
import { workItem as baseWorkItem } from "../../../src/core/fixtures/builders.fixture";

const ADAPTER = join(import.meta.dir, "worktree.ts");
const ajv = new Ajv();

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-workspace-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** A real git repo with one commit on `main` (or `mainLine`), used as the main line every test worktrees off. */
const gitRepo = async (mainLine = "main"): Promise<string> => {
  const dir = tempDir();
  const run = async (args: string[]): Promise<void> => {
    const proc = Bun.spawn(["git", ...args], { cwd: dir, stdout: "pipe", stderr: "pipe" });
    await proc.exited;
  };
  await run(["init", "-b", mainLine]);
  await run(["config", "user.email", "test@example.com"]);
  await run(["config", "user.name", "Test"]);
  writeFileSync(join(dir, "README.md"), "hello\n");
  await run(["add", "README.md"]);
  await run(["commit", "-m", "init"]);
  return dir;
};

const branches = async (repo: string): Promise<string[]> => {
  const proc = Bun.spawn(["git", "branch", "--list"], { cwd: repo, stdout: "pipe" });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return out.split("\n").map((line) => line.replace(/^[*+]?\s*/, "")).filter(Boolean);
};

const workItemFor = (key: string): WorkItem => ({ ...baseWorkItem, key });

type Call = { op: string; payload: unknown; main?: string };
type Out = { exitCode: number; stdout: unknown };

/** Run `workspace/worktree.ts --main <main> --root <root> workspace <op>` with a Stdin envelope, as the Runner does. */
const call = async (repo: string, root: string, delivery: string, { op, payload, main = "main" }: Call): Promise<Out> => {
  const stdin: Stdin = {
    id: `${delivery}/workspace-1`, delivery, port: "workspace", op,
    workItem: workItemFor("PROJ-1"), workspace: null, payload, tools: [],
  };
  const proc = Bun.spawn(["bun", ADAPTER, "--main", main, "--root", root, "workspace", op], {
    cwd: repo,
    stdin: new Blob([JSON.stringify(stdin)]),
    stdout: "pipe",
    stderr: "pipe",
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" },
  });
  const [text, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const stdout: unknown = JSON.parse(text);
  const contract = schemaFor("workspace", op);
  if (contract && !ajv.validate(contract.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  return { exitCode, stdout };
};

const setup = (main?: string): Call => ({ op: "setup", payload: {}, ...(main === undefined ? {} : { main }) });
const teardown = (path: string): Call => ({ op: "teardown", payload: { path } });
const ok = (body: unknown) => ({ exitCode: 0, stdout: { status: "ok", body } });

describe("workspace/worktree adapter", () => {
  test("setup creates a worktree at <root>/<delivery> on branch ship/<delivery> off main", async () => {
    const repo = await gitRepo();
    const root = tempDir();
    const delivery = "PROJ-1-1";
    const result = await call(repo, root, delivery, setup());
    const path = join(root, delivery);
    expect(result).toEqual(ok({ path, base: "main" }));
    expect(existsSync(join(path, "README.md"))).toBe(true);
    expect(await branches(repo)).toContain("ship/PROJ-1-1");
  });

  test("setup reports the --main branch as base, fresh and on an idempotent re-setup (harlo-52)", async () => {
    const repo = await gitRepo("dogfood");
    const root = tempDir();
    const delivery = "PROJ-1-1";
    const path = join(root, delivery);
    expect(await call(repo, root, delivery, setup("dogfood"))).toEqual(ok({ path, base: "dogfood" }));
    expect(await call(repo, root, delivery, setup("dogfood"))).toEqual(ok({ path, base: "dogfood" }));
    expect(await branches(repo)).not.toContain("main");
  });

  test("setup is idempotent: a second call for the same delivery returns ok", async () => {
    const repo = await gitRepo();
    const root = tempDir();
    const delivery = "PROJ-1-1";
    const path = join(root, delivery);
    expect(await call(repo, root, delivery, setup())).toEqual(ok({ path, base: "main" }));
    expect(await call(repo, root, delivery, setup())).toEqual(ok({ path, base: "main" }));
  });

  test("teardown removes the worktree and its branch", async () => {
    const repo = await gitRepo();
    const root = tempDir();
    const delivery = "PROJ-1-1";
    const path = join(root, delivery);
    await call(repo, root, delivery, setup());
    const result = await call(repo, root, delivery, teardown(path));
    expect(result).toEqual(ok({}));
    expect(existsSync(path)).toBe(false);
    expect(await branches(repo)).not.toContain("ship/PROJ-1-1");
  });

  test("teardown is idempotent: a second call for an already-torn-down delivery returns ok", async () => {
    const repo = await gitRepo();
    const root = tempDir();
    const delivery = "PROJ-1-1";
    const path = join(root, delivery);
    await call(repo, root, delivery, setup());
    expect(await call(repo, root, delivery, teardown(path))).toEqual(ok({}));
    expect(await call(repo, root, delivery, teardown(path))).toEqual(ok({}));
  });

  test("cancel has nothing to cancel: ok {}", async () => {
    const repo = await gitRepo();
    const root = tempDir();
    expect(await call(repo, root, "PROJ-1-1", { op: "cancel", payload: { target: "PROJ-1-1/land-1" } })).toEqual(ok({}));
  });
});
