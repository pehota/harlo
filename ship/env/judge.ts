#!/usr/bin/env bun
// Judge tool (plan Part 2, "A judge tool for step output quality"; Bun/TS, environment code, mirroring
// env/poll/stalled.ts's shape). Reads a Delivery's journal straight off the configured State adapter (the same
// Stdin/Stdout contract the Runner uses; this is environment code, not core/runner, so it shells out to the
// adapter directly rather than importing runner internals) and renders, per step-call, what the adapter was
// asked, what it returned, and — when the adapter populates it — the raw reasoning behind that answer. Purely a
// read/render tool: no gating, no verdict of its own.
//
// argv: --delivery <id> --state <state-adapter argv…> [--root <main-line-repo>] [--step <name>]
//   `--state` takes the rest of argv (same convention as `poll/stalled.ts`): spawns `state journal <delivery>`
//   directly against the configured adapter. `--root` names the main-line repo sharing an object store with a
//   Delivery's worktree (`src/adapters/workspace/worktree.ts`); when given, Implement's changeset is also shown
//   as `git show <sha>` (best-effort: a torn-down worktree/branch's commit may be unreachable). `--step` filters
//   to one step's calls (all sequences, e.g. both `define-1` and `define-2` after a fix-round rerun); omitted
//   shows every step-call in the journal, in the order the journal already keeps them (chronological).
//
// A CommandId is `<delivery>/<name>-<n>` (`src/core/ids.ts`); this is environment code (it must not import
// `src/core`), so the `<name>-<n>` split is re-derived locally, matching how `env/drive.ts` re-checks
// `isTerminal`'s literals rather than importing them.
import type { CommandId, DeliveryId, EvidenceItem, Finding, RunnerStdin } from "../src/contracts/common";
import { schemaFor } from "../src/contracts/ports";
import type { TimedEntry } from "../src/contracts/snapshot";
import { check } from "../src/contracts/validate";

const parseArgs = (
  args: string[],
): { delivery: string | undefined; root: string | undefined; step: string | undefined; state: string[] } => {
  const stateAt = args.indexOf("--state");
  const head = stateAt === -1 ? args : args.slice(0, stateAt);
  const state = stateAt === -1 ? [] : args.slice(stateAt + 1);
  const flag = (name: string) => { const at = head.indexOf(name); return at === -1 ? undefined : head[at + 1]; };
  return { delivery: flag("--delivery"), root: flag("--root"), step: flag("--step"), state };
};

/** `state journal {delivery}` on the configured adapter, spawned exactly as the Runner spawns it
 *  (mirrors `env/poll/stalled.ts`'s own `journal()` helper). */
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

// `<name>-<n>` (the local half of a CommandId), matching `src/core/ids.ts`'s COMMAND_ID_RE without importing it.
const STEP_CALL_RE = /^([a-z][a-z_]*)-([1-9][0-9]*)$/;
const parseStepCall = (id: CommandId): { step: string; sequence: number } | null => {
  const local = id.slice(id.indexOf("/") + 1);
  const match = STEP_CALL_RE.exec(local);
  return match ? { step: match[1]!, sequence: Number(match[2]) } : null;
};

type ResultEntry = TimedEntry & { signal: Extract<TimedEntry["signal"], { kind: "result" }> };
type SentEntry = TimedEntry & { signal: Extract<TimedEntry["signal"], { kind: "sent" }> };

/** One step-call to render: a `result` entry, its step/sequence, and (when found) the `sent` entry that named
 *  its payload. Journal order is already chronological, so a plain filter/map keeps it that way. */
type StepCall = { id: CommandId; step: string; sequence: number; result: ResultEntry; sent: SentEntry | undefined };

const stepCalls = (entries: TimedEntry[], step: string | undefined): StepCall[] => {
  const sentById = new Map<CommandId, SentEntry>(
    entries.filter((e): e is SentEntry => e.signal.kind === "sent").map((e) => [e.signal.id, e]),
  );
  const calls: StepCall[] = [];
  for (const entry of entries) {
    if (entry.signal.kind !== "result") continue;
    const parsed = parseStepCall(entry.signal.id);
    if (!parsed) continue;
    if (step !== undefined && parsed.step !== step) continue;
    calls.push({ id: entry.signal.id, ...parsed, result: entry as ResultEntry, sent: sentById.get(entry.signal.id) });
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

// ── REASONING (Result.evidence, printed verbatim) ──
const reasoningLines = (evidence: EvidenceItem[] | undefined): string[] | null =>
  evidence && evidence.length > 0 ? evidence.map((e) => [e.label, e.text, e.url].filter(Boolean).join(": ")) : null;

const section = (title: string, lines: string[]): string[] => [`-- ${title} --`, ...(lines.length > 0 ? lines : ["(none)"])];

const render = (call: StepCall, root: string | undefined): string[] => {
  const result = call.result.signal.result;
  const lines = [`=== ${call.id} ===`, ...section("INPUT", inputLines(call))];
  if (result.status === "ok") {
    lines.push(...section("OUTPUT", outputLines(call.step, result.body as Record<string, unknown>, root)));
    const reasoning = reasoningLines(result.evidence);
    if (reasoning) lines.push(...section("REASONING", reasoning));
  } else if (result.status === "failed") {
    lines.push(...section("OUTPUT", [`failed: ${result.info}`]));
  } else {
    lines.push(...section("OUTPUT", [`question (${result.about}): ${result.prompt}`]));
    const reasoning = reasoningLines(result.evidence);
    if (reasoning) lines.push(...section("REASONING", reasoning));
  }
  return lines;
};

const main = async (): Promise<void> => {
  const { delivery, root, step, state } = parseArgs(process.argv.slice(2));
  if (!delivery || state.length === 0) {
    throw new Error("usage: judge.ts --delivery <id> --state <state-adapter argv…> [--root <main-line-repo>] [--step <name>]");
  }

  const entries = await journal(state, delivery);
  const calls = stepCalls(entries, step);
  for (const call of calls) console.log(`${render(call, root).join("\n")}\n`);
};

await main();
