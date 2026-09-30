#!/usr/bin/env bun
// Stall poller (plan §6 M1.4; Bun/TS per the accepted architecture amendment, replacing the plan's bash
// env/poll-stalled.sh). Reads `ship status`, then for each Delivery with an awaited command, reads its
// journal straight off the configured State adapter (the same Stdin/Stdout contract the Runner uses,
// `src/runner/spawn.ts`; this is environment code, not core/runner, so it shells out to the adapter directly
// rather than importing runner internals) and applies the liveness rules below. One flag per line on stdout,
// per stalled Delivery: for cron mail or an alert hook. One-shot: ship ships no daemon (plan §7).
//
// Liveness rules (plan §6 M1.4), checked in this order once a Delivery's `awaiting` id is known:
//   - no `sent` entry for it: "never sent" iff the journal's last entry is older than the grace period,
//     else no flag (a synchronous adapter may legitimately run past the grace period before `sent` lands).
//   - a `sent` entry, plus a later `result`/`accepted`/`adapter_error` entry for the same id: no flag — an
//     `accepted` command's work continues elsewhere and is never pid-checked; a `result`/`adapter_error`
//     already resolved it. This is checked before the host/pid checks below, so it takes priority over them.
//   - a `sent` entry whose `host` differs from this poller's host: "unknown host" (§7 puts State on a local
//     filesystem shared by poller and Runner; a foreign host is flagged loudly, never skipped).
//   - a `sent` entry whose pid is gone, or alive under a different start time (pid reuse): "dead".
//   - a `sent` entry whose pid is alive with a matching start time: "hung?" once its age exceeds the port's
//     `maxRuntime`, else no flag.
//
// argv: --ship <path to bin/ship> [--grace <ms>] [--max-runtime <ms>] --state <state-adapter argv…>
//   `--state` takes the rest of argv: the adapter's own spawn argv, exactly as the machine config's `state`
//   entry does (e.g. `bun src/adapters/state/files.ts --dir <dir>`), since `state <op>` is appended by this poller.
//   `--grace`/`--max-runtime` are one poller-wide budget (ms), not per port [amend: the plan tables `maxRuntime`
//   per port; YAGNI keeps one number here — split it into a per-port map if a real profile needs one].
import { hostname } from "node:os";
import type { DeliveryId, RunnerStdin } from "../../src/contracts/common";
import { schemaFor } from "../../src/contracts/ports";
import type { TimedEntry } from "../../src/contracts/snapshot";
import { check } from "../../src/contracts/validate";

const DEFAULT_GRACE_MS = 5 * 60_000;
const DEFAULT_MAX_RUNTIME_MS = 15 * 60_000;

type StatusBody = { deliveries: { delivery: DeliveryId; at: string; awaiting: string | null }[] };
type Flag = "never sent" | "unknown host" | "dead" | "hung?";
type SentSignal = Extract<TimedEntry["signal"], { kind: "sent" }>;

const parseArgs = (
  args: string[],
): { ship: string | undefined; grace: number; maxRuntime: number; state: string[] } => {
  const stateAt = args.indexOf("--state");
  const head = stateAt === -1 ? args : args.slice(0, stateAt);
  const state = stateAt === -1 ? [] : args.slice(stateAt + 1);
  const flag = (name: string) => { const at = head.indexOf(name); return at === -1 ? undefined : head[at + 1]; };
  const num = (name: string, fallback: number) => { const v = flag(name); return v === undefined ? fallback : Number(v); };
  return { ship: flag("--ship"), grace: num("--grace", DEFAULT_GRACE_MS), maxRuntime: num("--max-runtime", DEFAULT_MAX_RUNTIME_MS), state };
};

const runShip = async (ship: string, args: string[]): Promise<{ exitCode: number; stdout: string; stderr: string }> => {
  const proc = Bun.spawn([ship, ...args], { stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  return { exitCode, stdout, stderr };
};

/** `state journal {delivery}` on the configured adapter, spawned exactly as the Runner spawns it. */
const journal = async (stateArgv: string[], delivery: DeliveryId): Promise<TimedEntry[]> => {
  const stdin: RunnerStdin = {
    id: null, delivery, port: "state", op: "journal", workItem: null, workspace: null, payload: { delivery }, tools: [],
  };
  const proc = Bun.spawn([...stateArgv, "state", "journal"], {
    stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  if (exitCode !== 0) throw new Error(`state journal ${delivery}: exit ${exitCode}\n${stderr}`);
  const reply = JSON.parse(stdout) as { status: string; body?: { entries: TimedEntry[] }; info?: string };
  const contract = schemaFor("state", "journal");
  const invalid = contract && check(contract.stdout, reply);
  if (invalid) throw new Error(`state journal ${delivery}: stdout fails the contract: ${invalid}`);
  if (reply.status !== "ok") throw new Error(`state journal ${delivery}: ${reply.info ?? reply.status}`);
  return reply.body!.entries;
};

/**
 * The start time of a live process (the pid-reuse guard), or "" when the pid is gone.
 * macOS only (`ps -o lstart=`, this repo's runtime): Linux's `/proc/<pid>/stat` field 22 is [unverified]
 * future work per plan.md §8.3, matching `src/runner/spawn.ts`'s own note — left unhandled here on purpose.
 */
const processStartTime = (pid: number): string =>
  Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)]).stdout.toString().trim();

const OUTCOME_KINDS = new Set(["result", "accepted", "adapter_error"]);
const hasOutcome = (entries: TimedEntry[], id: string): boolean =>
  entries.some((e) => OUTCOME_KINDS.has(e.signal.kind) && "id" in e.signal && e.signal.id === id);

/** The one flag for `id` (an `awaiting` command), or null when it is not stalled. */
const flagFor = (entries: TimedEntry[], id: string, host: string, now: number, grace: number, maxRuntime: number): Flag | null => {
  const sent = entries.findLast((e): e is TimedEntry & { signal: SentSignal } => e.signal.kind === "sent" && e.signal.id === id);
  if (!sent) {
    const last = entries.at(-1);
    return last && now - Date.parse(last.time) > grace ? "never sent" : null;
  }
  if (hasOutcome(entries, id)) return null;
  if (sent.signal.host !== host) return "unknown host";
  const lstart = processStartTime(sent.signal.pid);
  if (!lstart || lstart !== sent.signal.started) return "dead";
  return now - Date.parse(sent.signal.started) > maxRuntime ? "hung?" : null;
};

const main = async (): Promise<void> => {
  const { ship, grace, maxRuntime, state } = parseArgs(process.argv.slice(2));
  if (!ship || state.length === 0) throw new Error("usage: poll/stalled.ts --ship <path to bin/ship> --state <state-adapter argv…>");

  const status = await runShip(ship, ["status"]);
  if (status.exitCode !== 0) throw new Error(`ship status: exit ${status.exitCode}\n${status.stderr}`);
  const { deliveries } = JSON.parse(status.stdout) as StatusBody;

  const host = hostname();
  const now = Date.now();
  for (const { delivery, awaiting } of deliveries) {
    if (awaiting === null) continue;
    const entries = await journal(state, delivery);
    const flag = flagFor(entries, awaiting, host, now, grace, maxRuntime);
    if (flag) console.log(`${delivery} ${awaiting}: ${flag}`);
  }
};

await main();
