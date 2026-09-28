#!/usr/bin/env bun
// Local-merge Integrate adapter (plan §6 M1.5/M1.6). Land a Delivery by rebasing its branch onto the main
// line and fast-forwarding the main line onto it, with no PR and no CI polling (that is `integrate-pr.ts`, M3).
//
// argv: --root <dir> integrate <op>; --root is the main-line repo (the one `workspace/worktree.ts`, M1.2,
// creates the delivery's linked worktree from, so both share one .git and its branch `ship/<delivery>` is
// visible by name from `--root` with no fetch). stdin: Stdin (§3.1), whose `workspace` is that worktree's
// path. stdout: one Result JSON line.
//
// `run {changeset, answer?}`:
//   1. rebase `ship/<delivery>` (in the delivery worktree) onto the main line's current branch;
//   2. on conflict: `rebase --abort` (leaves both repos clean) and ask `{about: "conflict"}`. Re-issued with
//      `answer: "resolved"`, this simply retries step 1 — nothing here depends on `answer`'s value, only on
//      the delivery branch having changed since the last attempt.
//   3. on a clean rebase: `merge --ff-only` the delivery branch into the main line in `--root`, then push if
//      `--root` has a remote configured.
// Every step is a plain git command already idempotent under a repeated command id: rebasing or merging a
// branch that is already up to date with the main line does nothing and still reports `landed`.
//
// `cancel`: no-op (the generic contract) — nothing here runs in the background to cancel.
import type { EvidenceItem, Result, Stdin } from "../../src/contracts/common";
import type { CancelPayload, IntegrateBody, IntegratePayload } from "../../src/contracts/ports";
import { schemaFor } from "../../src/contracts/ports";
import { check } from "../../src/contracts/validate";
import { isDeliveryId } from "../../src/core/ids";

type GitRun = { code: number; stdout: string; stderr: string };

const git = (dir: string, args: string[]): GitRun => {
  const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
};

const currentBranch = (dir: string): string => {
  const branch = git(dir, ["symbolic-ref", "--short", "HEAD"]);
  if (branch.code !== 0) throw new Error(`cannot read the current branch of ${dir}: ${branch.stderr}`);
  return branch.stdout.trim();
};

const hasRemote = (dir: string): boolean => git(dir, ["remote"]).stdout.trim().length > 0;

/** Paths still unmerged after a failed rebase, read before `rebase --abort` clears the conflict markers. */
const conflictedFiles = (dir: string): string[] =>
  git(dir, ["diff", "--name-only", "--diff-filter=U"]).stdout.split("\n").filter((line) => line !== "");

const ok = <Body>(body: Body): Result<Body> => ({ status: "ok", body });
const question = (prompt: string, about: string, evidence: EvidenceItem[]): Result<never> =>
  ({ status: "question", prompt, about, evidence });

const run = (root: string, stdin: Stdin): Result<IntegrateBody> => {
  const { delivery, workspace } = stdin;
  if (!workspace) throw new Error("integrate run requires a workspace (from workspace.setup)");
  if (!isDeliveryId(delivery)) throw new Error(`not a Delivery id: ${JSON.stringify(delivery)}`);
  const branch = `ship/${delivery}`;
  const main = currentBranch(root);

  const rebase = git(workspace, ["rebase", main]);
  if (rebase.code !== 0) {
    const files = conflictedFiles(workspace);
    const abort = git(workspace, ["rebase", "--abort"]);
    if (abort.code !== 0) throw new Error(`rebase of ${branch} onto ${main} conflicted, and abort failed: ${abort.stderr}`);
    const evidence = files.length > 0
      ? files.map((file): EvidenceItem => ({ label: "conflict", text: file }))
      : [{ label: "conflict", text: rebase.stderr } satisfies EvidenceItem];
    return question(`Rebasing ${branch} onto ${main} conflicts.`, "conflict", evidence);
  }

  const merge = git(root, ["merge", "--ff-only", branch]);
  if (merge.code !== 0) throw new Error(`ff-only merge of ${branch} into ${main} failed: ${merge.stderr}`);

  if (hasRemote(root)) {
    const push = git(root, ["push"]);
    if (push.code !== 0) throw new Error(`push of ${main} failed: ${push.stderr}`);
  }

  return ok<IntegrateBody>({ verdict: "landed" });
};

const cancel = (_root: string, _stdin: Stdin): Result<Record<string, never>> => ok({});

const ops: Record<string, (root: string, stdin: Stdin) => Result<unknown>> = { run, cancel };

/** argv after the script: `--root <dir> <port> <op>`. */
const parseArgs = (args: string[]): { root: string | undefined; port: string | undefined; op: string | undefined } => {
  const at = args.indexOf("--root");
  const root = at === -1 ? undefined : args[at + 1];
  const positional = at === -1 ? args : [...args.slice(0, at), ...args.slice(at + 2)];
  const [port, op] = positional;
  return { root, port, op };
};

/** Every unexpected error is caught: a thrown rebase/merge/push failure changes nothing the adapter reports as done. */
const main = async (): Promise<Result<unknown>> => {
  const { root, port, op } = parseArgs(process.argv.slice(2));
  if (!root) throw new Error("usage: integrate/local.ts --root <dir> integrate <op>");
  const contract = port === "integrate" && op ? schemaFor("integrate", op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload as IntegratePayload | CancelPayload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return handler(root, stdin);
};

try {
  console.log(JSON.stringify(await main()));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
