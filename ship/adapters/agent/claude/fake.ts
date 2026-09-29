#!/usr/bin/env bun
// TEST-ONLY fake `claude` CLI, for adapters/agent/claude/index.test.ts (--agent-bin points here instead of the real
// `claude`). Mimics the real CLI's argv/stdout shape confirmed by the M1.8 spike: called as
// `<this> -p <prompt> --output-format json --json-schema <schema> [--resume <id>]`, it prints one JSON line
// shaped like the real reply ({is_error, result, structured_output?, session_id?}) — even on a non-zero exit,
// per the spike's auth-failure finding — and optionally commits in its cwd first, standing in for the real
// agent's own commit(s) inside the workspace.
//
// env FAKE_AGENT_REPLIES (required): a JSON file `{"replies": <reply> | <reply>[]}`. A list gives the nth
// call the nth reply (adapters/fake.ts's own idea); a single reply answers every call.
// env FAKE_AGENT_LOG (optional): every call's argv is appended here as one JSON line, so a test can assert
// what the adapter passed — e.g. whether `--resume` was sent, and with which session id.
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type Reply = {
  is_error: boolean;
  result: string;
  structured_output?: unknown;
  session_id?: string;
  exitCode?: number;
  commit?: boolean; // when true, `git commit --allow-empty` in cwd before printing the reply
};
type Script = { replies: Reply | Reply[] };

/** This call's 0-based turn: claims the lowest free `call.<n>` file, atomic across processes (adapters/fake.ts). */
const claimTurn = (dir: string): number => {
  mkdirSync(dir, { recursive: true });
  for (let n = 0; ; n += 1) {
    try {
      writeFileSync(join(dir, `call.${n}`), "", { flag: "wx" });
      return n;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
  }
};

const args = process.argv.slice(2);
const log = process.env.FAKE_AGENT_LOG;
if (log) appendFileSync(log, `${JSON.stringify(args)}\n`);

const repliesFile = process.env.FAKE_AGENT_REPLIES;
if (!repliesFile) {
  console.error("usage: FAKE_AGENT_REPLIES=<file> [FAKE_AGENT_LOG=<file>] fake.ts -p ...");
  process.exit(2);
}
const { replies } = JSON.parse(readFileSync(repliesFile, "utf8")) as Script;
const reply = Array.isArray(replies) ? (replies[claimTurn(`${repliesFile}.calls`)] ?? replies.at(-1)!) : replies;

if (reply.commit) {
  const commit = Bun.spawnSync(["git", "commit", "--allow-empty", "-q", "-m", "fake agent commit"], {
    stdout: "pipe", stderr: "pipe",
  });
  if (commit.exitCode !== 0) {
    console.error(commit.stderr.toString());
    process.exit(commit.exitCode);
  }
}

console.log(JSON.stringify({
  is_error: reply.is_error, result: reply.result, structured_output: reply.structured_output, session_id: reply.session_id,
}));
process.exit(reply.exitCode ?? 0);
