#!/usr/bin/env bun
// Minimal fixture adapter for cli.test.ts, serving tracker, workspace, the step ports and principal.
// argv: [--next <key>] [--title <t>] [--fail-read] [--crash] <port> <op>. M0.19 replaces it with the scripted fake.
//   tracker.read → ok {workItem} (failed with --fail-read); tracker.next → ok {key} (null without --next)
//   fires (update, comment, notify, cancel) → ok {}; every other op → accepted, or exit 1 with --crash
const args = process.argv.slice(2);
const [port, op] = args.slice(-2);
const flag = (name: string): string | undefined => {
  const at = args.indexOf(name);
  return at === -1 ? undefined : args[at + 1];
};
const stdin = JSON.parse(await Bun.stdin.text()) as { payload: { key?: string } };
const print = (stdout: unknown): void => console.log(JSON.stringify(stdout));

if (port === "tracker" && op === "read") {
  if (args.includes("--fail-read")) print({ status: "failed", info: "tracker unreachable" });
  else print({ status: "ok", body: { workItem: { key: stdin.payload.key, title: flag("--title") ?? "Greet by name", body: "Say hello." } } });
} else if (port === "tracker" && op === "next") {
  print({ status: "ok", body: { key: flag("--next") ?? null } });
} else if (["update", "comment", "notify", "cancel"].includes(op ?? "")) {
  print({ status: "ok", body: {} });
} else if (args.includes("--crash")) {
  console.error(`${port}.${op} crashed`);
  process.exit(1);
} else {
  print({ status: "accepted" });
}
