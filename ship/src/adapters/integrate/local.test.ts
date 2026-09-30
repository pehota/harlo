// M1.5/M1.6: the local-merge Integrate adapter, driven as an executable, against real temp git repos
// (no mocking): a "main" repo (the main line, `--root`) and a "delivery" repo, which is a linked worktree
// of the main repo checked out on `ship/<delivery>` (as workspace.setup, M1.2, would have created it).
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../../src/contracts/common";
import { schemaFor } from "../../../src/contracts/ports";

const ADAPTER = join(import.meta.dir, "local.ts");
const ajv = new Ajv();

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-integrate-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

/** Run a git command in `dir`, throwing on a nonzero exit (setup only; the adapter is what's under test). */
const git = (dir: string, ...args: string[]): string => {
  const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) throw new Error(`git ${args.join(" ")} in ${dir}: ${proc.stderr.toString()}`);
  return proc.stdout.toString();
};

/** A main repo (root) with one commit on `main`, plus a linked worktree on `ship/<delivery>` sharing its .git. */
const setup = (delivery: string): { root: string; workspace: string } => {
  const root = tempDir();
  git(root, "init", "-q", "-b", "main");
  git(root, "config", "user.email", "t@example.com");
  git(root, "config", "user.name", "T");
  writeFileSync(join(root, "shared.txt"), "line one\n");
  writeFileSync(join(root, "root-only.txt"), "root\n");
  git(root, "add", "-A");
  git(root, "commit", "-q", "-m", "initial");
  const workspace = join(tempDir(), delivery); // a sibling temp dir, not nested under root (so root's own
  // `git status` never sees it as an untracked path)
  git(root, "worktree", "add", "-q", "-b", `ship/${delivery}`, workspace);
  return { root, workspace };
};

const workItem: WorkItem = { key: "k", title: "t", body: "b" };

/** Run `integrate/local.ts --root <root> integrate <op>` with a Stdin envelope, as the Runner does. */
const call = async (
  root: string,
  workspace: string | null,
  delivery: string,
  op: string,
  payload: unknown,
): Promise<{ exitCode: number; stdout: unknown }> => {
  const stdin: Stdin = { id: `${delivery}/integrate-1`, delivery, port: "integrate", op, workItem, workspace, payload, tools: [] };
  const proc = Bun.spawn(["bun", ADAPTER, "--root", root, "integrate", op], {
    stdin: new Blob([JSON.stringify(stdin)]),
    stdout: "pipe",
    stderr: "pipe",
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "" },
  });
  const [text, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const stdout: unknown = JSON.parse(text);
  const contract = schemaFor("integrate", op);
  if (contract && !ajv.validate(contract.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  return { exitCode, stdout };
};

const isClean = (dir: string): boolean => git(dir, "status", "--porcelain").trim() === "";
const rebaseInProgress = (dir: string): boolean =>
  existsSync(join(dir, ".git", "rebase-merge")) || existsSync(join(dir, ".git", "rebase-apply"));

describe("integrate/local adapter", () => {
  test("clean fast-forward: rebase + ff-only merge lands, and pushes if a remote is configured", async () => {
    const { root, workspace } = setup("PROJ-1-1");
    writeFileSync(join(workspace, "feature.txt"), "hello\n");
    git(workspace, "add", "-A");
    git(workspace, "commit", "-q", "-m", "add feature");

    // a bare remote to prove push happens when one is configured
    const remote = tempDir();
    git(remote, "init", "-q", "--bare", "-b", "main");
    git(root, "remote", "add", "origin", remote);
    git(root, "push", "-q", "-u", "origin", "main");

    const result = await call(root, workspace, "PROJ-1-1", "run", { changeset: "ship/PROJ-1-1@abc" });
    expect(result).toEqual({ exitCode: 0, stdout: { status: "ok", body: { verdict: "landed" } } });
    expect(existsSync(join(root, "feature.txt"))).toBe(true);
    expect(git(root, "log", "-1", "--format=%s")).toBe("add feature\n");
    expect(git(remote, "log", "-1", "--format=%s")).toBe("add feature\n"); // pushed
    expect(isClean(root)).toBe(true);
    expect(isClean(workspace)).toBe(true);
  });

  test("conflicting change: aborts the rebase (repo left clean) and asks about the conflict", async () => {
    const { root, workspace } = setup("PROJ-2-1");
    // conflicting edits to the same line of the same file, one on main, one on the delivery branch
    writeFileSync(join(root, "shared.txt"), "main line change\n");
    git(root, "add", "-A");
    git(root, "commit", "-q", "-m", "change on main");
    writeFileSync(join(workspace, "shared.txt"), "delivery change\n");
    git(workspace, "add", "-A");
    git(workspace, "commit", "-q", "-m", "conflicting change");

    const result = await call(root, workspace, "PROJ-2-1", "run", { changeset: "ship/PROJ-2-1@abc" });
    expect(result.exitCode).toBe(0);
    expect(result.stdout).toMatchObject({ status: "question", about: "conflict" });
    expect((result.stdout as { prompt: string }).prompt).toEqual(expect.any(String));

    // the rebase was aborted: no rebase in progress, working tree clean, branch tip unchanged
    expect(rebaseInProgress(workspace)).toBe(false);
    expect(isClean(workspace)).toBe(true);
    expect(git(workspace, "log", "-1", "--format=%s")).toBe("conflicting change\n");
    expect(isClean(root)).toBe(true);
    expect(git(root, "log", "-1", "--format=%s")).toBe("change on main\n");
  });

  test("re-issued with answer:resolved after the conflict is fixed: retries the rebase and lands", async () => {
    const { root, workspace } = setup("PROJ-3-1");
    writeFileSync(join(root, "shared.txt"), "main line change\n");
    git(root, "add", "-A");
    git(root, "commit", "-q", "-m", "change on main");
    writeFileSync(join(workspace, "shared.txt"), "delivery change\n");
    git(workspace, "add", "-A");
    git(workspace, "commit", "-q", "-m", "conflicting change");

    const asked = await call(root, workspace, "PROJ-3-1", "run", { changeset: "ship/PROJ-3-1@abc" });
    expect(asked.stdout).toMatchObject({ status: "question", about: "conflict" });

    // resolve: amend the delivery commit so it no longer touches the conflicting file
    writeFileSync(join(workspace, "shared.txt"), "line one\n"); // back to the shared base content
    writeFileSync(join(workspace, "feature.txt"), "resolved feature\n");
    git(workspace, "add", "-A");
    git(workspace, "commit", "-q", "--amend", "-m", "conflicting change (resolved)");

    const retried = await call(root, workspace, "PROJ-3-1", "run", { changeset: "ship/PROJ-3-1@abc", answer: "resolved" });
    expect(retried).toEqual({ exitCode: 0, stdout: { status: "ok", body: { verdict: "landed" } } });
    expect(readFileSync(join(root, "feature.txt"), "utf8")).toBe("resolved feature\n");
    expect(isClean(root)).toBe(true);
    expect(isClean(workspace)).toBe(true);
  });

  test("cancel has nothing to cancel: ok {}", async () => {
    const { root } = setup("PROJ-4-1");
    const result = await call(root, null, "PROJ-4-1", "cancel", { target: "PROJ-4-1/integrate-1" });
    expect(result).toEqual({ exitCode: 0, stdout: { status: "ok", body: {} } });
  });
});
