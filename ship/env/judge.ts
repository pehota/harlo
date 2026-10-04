#!/usr/bin/env bun
// Judge tool (plan Part 2, "A judge tool for step output quality"; Bun/TS, environment code, mirroring
// env/poll/stalled.ts's shape). Reads a Delivery's journal straight off the configured State adapter (the same
// Stdin/Stdout contract the Runner uses; this is environment code, not core/runner, so it shells out to the
// adapter directly rather than importing runner internals) and renders, per step-call, what the adapter was
// asked, what it returned, and — when the adapter populates it — the raw reasoning behind that answer and what the
// call cost (USAGE: tokens, USD, duration, turns), then one usage total for the Delivery. Purely a read/render
// tool: no gating, no verdict of its own.
//
// argv: [--repo <path>] [<delivery> | --delivery <id>] [--root <main-line-repo>] [--step <name>]
//       [--state <state-adapter argv…>]
//   The State adapter is the one the repo's machine config names, found as `ship` finds it (env/repo-config.ts):
//   `--repo` (default: the cwd's git root) → `ship.config.json` → `$SHIP_MACHINE_CONFIG`, else
//   `~/.config/ship/<projectId>.json` → its `state` argv. `--state` overrides that and skips the config lookup;
//   it takes the rest of argv (same convention as `poll/stalled.ts`). No delivery → one line per Delivery the
//   State holds (closed/abandoned included): id, `at`, outcome when set, and the time of its latest journal entry,
//   most recent first. With a delivery, its journal is rendered via `state journal <delivery>`. `--root` names the
//   main-line repo sharing an object store with a Delivery's worktree (`src/adapters/workspace/worktree.ts`) and
//   defaults to the repo's git root (none under a bare `--state` override without `--repo`): Implement's changeset
//   is also shown as `git show <sha>` (best-effort: a torn-down worktree/branch's commit may be unreachable).
//   `--step` filters to one step's calls (all sequences, e.g. both `define-1` and `define-2` after a fix-round
//   rerun); omitted shows every step-call in the journal, in the order the journal already keeps them.
// exit: 0 rendered/listed · 1 bad usage, or the repo/config cannot be resolved (message only) · other: a State
//   adapter failure (thrown)
//
// A CommandId is `<delivery>/<name>-<n>` (`src/core/ids.ts`); this is environment code (it must not import
// `src/core`), so the `<name>-<n>` split is re-derived locally, matching how `env/drive.ts` re-checks
// `isTerminal`'s literals rather than importing them.
//
// Usage (harlo-56): an ok/question/failed Result carries it as a `usage` evidence item; a crashed call (an
// `adapter_error` entry, no `result`) has it as the stderr tail's last `ship-usage: {json}` line in `info`, written
// by the agent adapter (src/adapters/agent/claude/index.ts) — re-matched here, not imported, like STEP_CALL_RE.
import type { CommandId, DeliveryId, EvidenceItem, Finding, RunnerStdin, Usage } from "../src/contracts/common";
import { schemaFor } from "../src/contracts/ports";
import type { TimedEntry } from "../src/contracts/snapshot";
import { check } from "../src/contracts/validate";
import { RepoConfigError, gitRoot, repoConfig } from "./repo-config";

/** Bad argv: the message (with usage) is printed, exit 1. */
class UsageError extends Error {}

const VALUE_FLAGS = ["--repo", "--delivery", "--root", "--step"];

type Args = {
  repo: string | undefined; delivery: string | undefined; root: string | undefined; step: string | undefined;
  state: string[];
};

/** Flags take the next arg; the one bare arg is the delivery; `--state` takes the rest. */
const parseArgs = (args: string[]): Args => {
  const stateAt = args.indexOf("--state");
  const head = stateAt === -1 ? args : args.slice(0, stateAt);
  const state = stateAt === -1 ? [] : args.slice(stateAt + 1);
  const flags = new Map<string, string>();
  const bare: string[] = [];
  for (let i = 0; i < head.length; i++) {
    const arg = head[i]!;
    if (VALUE_FLAGS.includes(arg)) {
      if (i + 1 >= head.length) throw new UsageError(`${arg} needs a value\n${USAGE}`);
      flags.set(arg, head[++i]!);
    }
    else if (arg.startsWith("--") || bare.length > 0) throw new UsageError(`unknown or extra argument: ${arg}\n${USAGE}`);
    else bare.push(arg);
  }
  return {
    repo: flags.get("--repo"), delivery: flags.get("--delivery") ?? bare[0], root: flags.get("--root"),
    step: flags.get("--step"), state,
  };
};

const USAGE = "usage: judge.ts [--repo <path>] [<delivery>] [--root <main-line-repo>] [--step <name>] "
  + "[--state <state-adapter argv…>]";

/** The State adapter's spawn argv, and the cwd it runs in: the repo root, as `ship` runs it (none: inherit ours). */
type StateSource = { argv: string[]; cwd: string | undefined };

/** One Runner-only `state <op>` call on the configured adapter, spawned exactly as the Runner spawns it
 *  (mirrors `env/poll/stalled.ts`'s own `journal()` helper), its stdout checked against the op's contract. */
const stateOp = async <Body>(state: StateSource, op: string, payload: { delivery?: DeliveryId }): Promise<Body> => {
  const delivery = payload.delivery ?? null;
  const what = `state ${op}${delivery === null ? "" : ` ${delivery}`}`;
  const stdin: RunnerStdin = {
    id: null, delivery, port: "state", op, workItem: null, workspace: null, payload, tools: [],
  };
  const proc = Bun.spawn([...state.argv, "state", op], {
    cwd: state.cwd, stdin: new Blob([JSON.stringify(stdin)]), stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  if (exitCode !== 0) throw new Error(`${what}: exit ${exitCode}\n${stderr}`);
  const reply = JSON.parse(stdout) as { status: string; body?: Body; info?: string };
  const contract = schemaFor("state", op);
  const invalid = contract && check(contract.stdout, reply);
  if (invalid) throw new Error(`${what}: stdout fails the contract: ${invalid}`);
  if (reply.status !== "ok") throw new Error(`${what}: ${reply.info ?? reply.status}`);
  return reply.body!;
};

const journal = async (state: StateSource, delivery: DeliveryId): Promise<TimedEntry[]> =>
  (await stateOp<{ entries: TimedEntry[] }>(state, "journal", { delivery })).entries;

// ── LIST (no delivery given) ──
type Listed = { delivery: DeliveryId; at: string; outcome: string | null; last: string };

/** Every Delivery the State holds, with its position, outcome and latest journal time; most recent first. */
const listDeliveries = async (source: StateSource): Promise<Listed[]> => {
  const { deliveries } = await stateOp<{ deliveries: DeliveryId[] }>(source, "list", {});
  const listed = await Promise.all(deliveries.map(async (delivery): Promise<Listed> => {
    const { state } = await stateOp<{ state: { at: string; outcome: string | null } | null }>(source, "load", { delivery });
    const entries = await journal(source, delivery);
    return { delivery, at: state?.at ?? "-", outcome: state?.outcome ?? null, last: entries.at(-1)?.time ?? "-" };
  }));
  return listed.sort((a, b) => b.last.localeCompare(a.last));
};

const listLines = (listed: Listed[]): string[] => {
  if (listed.length === 0) return ["no Deliveries"];
  const width = Math.max(...listed.map((l) => l.delivery.length));
  return listed.map((l) =>
    [l.delivery.padEnd(width), `at=${l.at}`, ...(l.outcome === null ? [] : [`outcome=${l.outcome}`]), `last=${l.last}`].join("  "));
};

// `<name>-<n>` (the local half of a CommandId), matching `src/core/ids.ts`'s COMMAND_ID_RE without importing it.
const STEP_CALL_RE = /^([a-z][a-z_]*)-([1-9][0-9]*)$/;
const parseStepCall = (id: CommandId): { step: string; sequence: number } | null => {
  const local = id.slice(id.indexOf("/") + 1);
  const match = STEP_CALL_RE.exec(local);
  return match ? { step: match[1]!, sequence: Number(match[2]) } : null;
};

type ResultEntry = TimedEntry & { signal: Extract<TimedEntry["signal"], { kind: "result" }> };
type SentEntry = TimedEntry & { signal: Extract<TimedEntry["signal"], { kind: "sent" }> };

/** How a step-call ended: its `result` entry, or the `adapter_error` entry's info when the adapter crashed. */
type Outcome = { kind: "result"; entry: ResultEntry } | { kind: "crash"; info: string };

/** One step-call to render: how it ended, its step/sequence, and (when found) the `sent` entry that named its
 *  payload. Journal order is already chronological, so a plain filter/map keeps it that way. */
type StepCall = { id: CommandId; step: string; sequence: number; outcome: Outcome; sent: SentEntry | undefined };

const stepCalls = (entries: TimedEntry[], step: string | undefined): StepCall[] => {
  const sentById = new Map<CommandId, SentEntry>(
    entries.filter((e): e is SentEntry => e.signal.kind === "sent").map((e) => [e.signal.id, e]),
  );
  const calls: StepCall[] = [];
  for (const entry of entries) {
    const signal = entry.signal;
    if (signal.kind !== "result" && signal.kind !== "adapter_error") continue;
    const parsed = parseStepCall(signal.id);
    if (!parsed) continue;
    if (step !== undefined && parsed.step !== step) continue;
    const outcome: Outcome = signal.kind === "result"
      ? { kind: "result", entry: entry as ResultEntry }
      : { kind: "crash", info: entry.info ?? "" };
    calls.push({ id: signal.id, ...parsed, outcome, sent: sentById.get(signal.id) });
  }
  return calls;
};

// ── INPUT ──
const inputLines = (call: StepCall): string[] => {
  const payload = call.sent?.signal.payload;
  if (payload === undefined) return ["(no payload recorded: this `sent` entry predates the `payload` field)"];
  return [JSON.stringify(payload, null, 2)];
};

// ── OUTPUT (per port, from each port's own Body shape in src/contracts/ports.ts) ──
const bullets = (title: string, items: string[] | undefined): string[] =>
  items && items.length > 0 ? [`${title}:`, ...items.map((i) => `  - ${i}`)] : [];

const findingLines = (findings: Finding[] | undefined): string[] =>
  findings && findings.length > 0 ? ["Findings:", ...findings.map((f) => `  - ${f.text}${f.ref ? ` (${f.ref})` : ""}`)] : [];

/** `ship/<delivery>@<sha>`'s sha, or the whole ref if it doesn't parse (defensive: never crash on a stray shape). */
const shaOf = (changeset: string): string => changeset.split("@").at(-1) ?? changeset;

const showCommit = (root: string, sha: string): string[] => {
  const proc = Bun.spawnSync(["git", "-C", root, "show", sha], { stdout: "pipe", stderr: "pipe" });
  if (proc.exitCode !== 0) return ["commit not reachable (worktree/branch likely torn down)"];
  return ["", proc.stdout.toString()];
};

const outputLines = (port: string, body: Record<string, unknown>, root: string | undefined): string[] => {
  switch (port) {
    case "define":
      return [...bullets("Criteria", body.criteria as string[] | undefined), ...bullets("Runbook", body.runbook as string[] | undefined)];
    case "implement": {
      const changeset = body.changeset as string;
      return [`Changeset: ${changeset}`, ...(root ? showCommit(root, shaOf(changeset)) : [])];
    }
    case "check": case "integrate": case "deploy": case "verify":
      return [`Verdict: ${body.verdict as string}`, ...findingLines(body.findings as Finding[] | undefined)];
    default:
      return [JSON.stringify(body)];
  }
};

// ── REASONING (Result.evidence other than usage, printed verbatim) ──
const reasoningLines = (evidence: EvidenceItem[] | undefined): string[] | null => {
  const items = (evidence ?? []).filter((e) => e.usage === undefined);
  return items.length > 0 ? items.map((e) => [e.label, e.text, e.url].filter(Boolean).join(": ")) : null;
};

// ── USAGE (the usage evidence item, or a crash's `ship-usage:` line) ──
const USAGE_LINE_PREFIX = "ship-usage: ";

/** The last `ship-usage: {json}` line of a crash's stderr tail; undefined when absent or unparseable. */
const crashUsage = (info: string): Usage | undefined => {
  const line = info.split("\n").findLast((l) => l.startsWith(USAGE_LINE_PREFIX));
  if (line === undefined) return undefined;
  try { return JSON.parse(line.slice(USAGE_LINE_PREFIX.length)) as Usage; } catch { return undefined; }
};

const usageOf = (outcome: Outcome): Usage | undefined =>
  outcome.kind === "crash"
    ? crashUsage(outcome.info)
    : outcome.entry.signal.result.evidence?.find((e) => e.usage !== undefined)?.usage;

/** Each figure's label and rendering, in display order; a figure the call didn't report is left out. */
const FIGURES: [keyof Usage, string, (n: number) => string][] = [
  ["inputTokens", "input tokens", String],
  ["outputTokens", "output tokens", String],
  ["cacheReadTokens", "cache-read tokens", String],
  ["cacheCreationTokens", "cache-write tokens", String],
  ["costUsd", "cost", (n) => `$${n.toFixed(4)}`],
  ["durationMs", "duration", (n) => `${(n / 1000).toFixed(1)}s`],
  ["turns", "turns", String],
];

const usageLines = (usage: Usage | undefined): string[] =>
  usage ? FIGURES.flatMap(([key, label, show]) => (usage[key] === undefined ? [] : [`${label}: ${show(usage[key])}`])) : [];

/** Every figure summed over the calls that reported it, and how many calls reported no usage at all. */
const totalLines = (delivery: string, calls: StepCall[]): string[] => {
  const usages = calls.map((c) => usageOf(c.outcome));
  const sum: Usage = {};
  for (const usage of usages) {
    for (const [key] of FIGURES) if (usage?.[key] !== undefined) sum[key] = (sum[key] ?? 0) + usage[key];
  }
  const without = usages.filter((u) => u === undefined).length;
  return [
    `=== TOTAL ${delivery} ===`,
    ...section("USAGE", usageLines(Object.keys(sum).length > 0 ? sum : undefined)),
    `calls: ${calls.length} (${calls.length - without} with usage, ${without} without usage data)`,
  ];
};

const section = (title: string, lines: string[]): string[] => [`-- ${title} --`, ...(lines.length > 0 ? lines : ["(none)"])];

/** The crash's stderr tail without its usage line (that has its own section). */
const crashLines = (info: string): string[] => [
  "crashed (adapter_error):", ...info.split("\n").filter((l) => l !== "" && !l.startsWith(USAGE_LINE_PREFIX)),
];

const render = (call: StepCall, root: string | undefined): string[] => {
  const lines = [`=== ${call.id} ===`, ...section("INPUT", inputLines(call))];
  const outcome = call.outcome;
  if (outcome.kind === "crash") {
    lines.push(...section("OUTPUT", crashLines(outcome.info)));
  } else {
    const result = outcome.entry.signal.result;
    if (result.status === "ok") {
      lines.push(...section("OUTPUT", outputLines(call.step, result.body as Record<string, unknown>, root)));
    } else if (result.status === "failed") {
      lines.push(...section("OUTPUT", [`failed: ${result.info}`]));
    } else {
      lines.push(...section("OUTPUT", [`question (${result.about}): ${result.prompt}`]));
    }
    const reasoning = reasoningLines(result.evidence);
    if (reasoning) lines.push(...section("REASONING", reasoning));
  }
  lines.push(...section("USAGE", usageLines(usageOf(outcome))));
  return lines;
};

/** The State argv and default `--root`: `--state` as given, else the repo's machine config (env/repo-config.ts). */
const resolveSource = (args: Args): { state: StateSource; root: string | undefined } => {
  const repoRoot = args.repo !== undefined || args.state.length === 0 ? gitRoot(args.repo ?? process.cwd()) : undefined;
  const argv = args.state.length > 0 ? args.state : repoConfig(repoRoot!).state;
  const state = { argv, cwd: repoRoot };
  return { state, root: args.root ?? repoRoot };
};

const main = async (): Promise<void> => {
  const args = parseArgs(process.argv.slice(2));
  const { state, root } = resolveSource(args);
  const { delivery, step } = args;
  if (delivery === undefined) {
    console.log(listLines(await listDeliveries(state)).join("\n"));
    return;
  }

  const entries = await journal(state, delivery);
  const calls = stepCalls(entries, step);
  for (const call of calls) console.log(`${render(call, root).join("\n")}\n`);
  console.log(totalLines(delivery, calls).join("\n"));
};

try {
  await main();
} catch (error) {
  if (!(error instanceof RepoConfigError || error instanceof UsageError)) throw error;
  console.error(error.message);
  process.exit(1);
}
