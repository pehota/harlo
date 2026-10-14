#!/usr/bin/env bun
// TEST-ONLY adapter: waits, then answers like a scripted reply or crashes. Stands in for a step that takes a while,
// so a `ship next` chain stays in flight (env/queue.test.ts).
// argv: <delay ms> <reply JSON | exit:<n>> <port> <op>; stdin is drained and ignored.
const [delay, reply] = process.argv.slice(2);
await Bun.stdin.text();
await Bun.sleep(Number(delay));
if (reply!.startsWith("exit:")) {
  console.error("slow step crashed");
  process.exit(Number(reply!.slice("exit:".length)));
}
console.log(reply);
