#!/usr/bin/env bun
// Git-worktree Workspace adapter (plan §6 M1.1). Layout: `<root>/<delivery>` is a worktree on branch
// `ship/<delivery>`, branched off `--main` in the repo the adapter runs in (its cwd is the main line).
// argv: --main <branch> --root <dir> workspace <op>; stdin: Stdin (§3.1); stdout: one Result JSON line.
// setup/teardown are idempotent on the worktree's presence on disk, not on git error text.
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Stdin } from "../../../src/contracts/common";
import { isDeliveryId } from "../../../src/core/ids";
import type { Empty, SetupBody, TeardownPayload } from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { check } from "../../../src/contracts/validate";

type Ctx = { root: string; main: string; delivery: string; cwd: string };

const expandHome = (dir: string): string =>
  dir === "~" ? homedir() : dir.startsWith("~/") ? join(homedir(), dir.slice(2)) : dir;

const branchFor = (delivery: string): string => `ship/${delivery}`;

const git = async (args: string[], cwd: string): Promise<{ code: number; out: string; err: string }> => {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [out, err, code] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  return { code, out, err };
};

const setup = async (ctx: Ctx): Promise<SetupBody> => {
  const path = join(ctx.root, ctx.delivery);
  const branch = branchFor(ctx.delivery);
  if (existsSync(path)) {
    const head = await git(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"], ctx.cwd);
    if (head.code === 0 && head.out.trim() === branch) return { path, base: ctx.main }; // already set up: idempotent
    throw new Error(`path exists and is not the ${branch} worktree: ${path}`);
  }
  mkdirSync(ctx.root, { recursive: true });
  const add = await git(["worktree", "add", path, "-b", branch, ctx.main], ctx.cwd);
  if (add.code !== 0) throw new Error(`git worktree add failed: ${add.err || add.out}`);
  return { path, base: ctx.main }; // base: step agents diff against it, never an assumed `main` (harlo-52)
};

const teardown = async (ctx: Ctx, { path }: TeardownPayload): Promise<Empty> => {
  const branch = branchFor(ctx.delivery);
  if (existsSync(path)) {
    const remove = await git(["worktree", "remove", "--force", path], ctx.cwd);
    if (remove.code !== 0) throw new Error(`git worktree remove failed: ${remove.err || remove.out}`);
  }
  // Best effort: the worktree is gone either way, so a stray or already-gone branch is not a failure.
  await git(["branch", "-D", branch], ctx.cwd);
  return {};
};

const cancel = async (): Promise<Empty> => ({}); // nothing runs in the background, so there is never anything to cancel

const ops: Record<string, (ctx: Ctx, payload: never) => Promise<unknown>> = { setup, teardown, cancel };

/** argv after the script: `--main <branch> --root <dir> <port> <op>`. */
const parseArgs = (
  args: string[],
): { main: string | undefined; root: string | undefined; port: string | undefined; op: string | undefined } => {
  const at = (flag: string, from: string[]): { value: string | undefined; rest: string[] } => {
    const i = from.indexOf(flag);
    return i === -1 ? { value: undefined, rest: from } : { value: from[i + 1], rest: [...from.slice(0, i), ...from.slice(i + 2)] };
  };
  const { value: main, rest: r1 } = at("--main", args);
  const { value: root, rest: r2 } = at("--root", r1);
  const [port, op] = r2;
  return { main, root, port, op };
};

const run = async (): Promise<unknown> => {
  const { main, root, port, op } = parseArgs(process.argv.slice(2));
  if (!main || !root) throw new Error("usage: workspace/worktree.ts --main <branch> --root <dir> workspace <op>");
  const contract = port === "workspace" && op ? schemaFor("workspace", op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  if (!isDeliveryId(stdin.delivery)) throw new Error(`not a Delivery id: ${JSON.stringify(stdin.delivery)}`);
  const ctx: Ctx = { root: expandHome(root), main, delivery: stdin.delivery, cwd: process.cwd() };
  return handler(ctx, stdin.payload as never);
};

try {
  console.log(JSON.stringify({ status: "ok", body: await run() }));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
