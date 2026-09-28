#!/usr/bin/env bun
// TEST-ONLY adapter (plan §2: "M0, tests only"). Never configure it for a real Delivery.
// Serves any port/op from a script, so one executable stands in for tracker, workspace, every step port and
// principal (and `cancel` on each).
//
// argv: --script <file> <port> <op>; stdin: Stdin (§3.1), appended as one JSON line to <file>.stdin.jsonl.
// Script: {"replies": {"<port>.<op>": <reply> | <reply>[]}}. A list gives the nth call the nth reply; a single
// reply answers every call; an unscripted port/op or an exhausted list prints {"status":"accepted"}.
// A reply is printed as stdout, except {"exit": n, "stderr": s}, which prints s to stderr and exits n.
// The call count lives in <file>.calls/, so it survives across the separate processes the Runner spawns.
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

type Crash = { exit: number; stderr: string };
type Script = { replies: Record<string, unknown> };

/** This call's 0-based turn for `name`: claims the lowest free `<name>.<n>` file, atomic across processes. */
const claimTurn = (dir: string, name: string): number => {
  mkdirSync(dir, { recursive: true });
  for (let n = 0; ; n += 1) {
    try {
      writeFileSync(join(dir, `${name}.${n}`), "", { flag: "wx" });
      return n;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    }
  }
};

const args = process.argv.slice(2);
const script = args[args.indexOf("--script") + 1];
const [port, op] = args.slice(-2);
if (!args.includes("--script") || !script || !port || !op) {
  console.error("usage: fake.ts --script <file> <port> <op>");
  process.exit(2);
}

const stdin = await Bun.stdin.text();
appendFileSync(`${script}.stdin.jsonl`, `${JSON.stringify(JSON.parse(stdin))}\n`);

const name = `${port}.${op}`;
const { replies } = JSON.parse(readFileSync(script, "utf8")) as Script;
const scripted = Object.hasOwn(replies, name) ? replies[name] : undefined;
const turn = claimTurn(`${script}.calls`, name);
const reply = Array.isArray(scripted) ? scripted[turn] : scripted;

if (reply !== null && typeof reply === "object" && "exit" in reply) {
  const crash = reply as Crash;
  console.error(crash.stderr);
  process.exit(crash.exit);
}
console.log(JSON.stringify(reply ?? { status: "accepted" }));
