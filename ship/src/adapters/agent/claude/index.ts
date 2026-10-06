#!/usr/bin/env bun
// Coding-agent adapter (plan §6 M1.9–M1.11; spike M1.8, docs/adapters.md). Cross-cutting: serves `define`,
// `implement` and `check` (plan §6 amendment), so it lives in its own module folder (adapters/agent/claude/)
// rather than a per-port folder — it isn't split into port-specific variants.
//
// argv: [--agent-bin <path>] [--plugin-dir <path>]... <port> <op>, port one of "define" | "implement" |
// "check"; --agent-bin defaults to `claude` on PATH (a fake executable in tests, per M1.9's own test spec).
// stdin: Stdin (§3.1); stdout: one Result JSON line.
//
// `run` builds a prompt, then calls `<agent-bin> -p <prompt> --output-format json --json-schema <schema>
// --safe-mode --permission-mode bypassPermissions [--plugin-dir <dir>]... [--resume <session-id>]
// [--disallowedTools Edit Write NotebookEdit]` (M1.8 spike shape), parses stdout as JSON unconditionally, and
// branches on `is_error` vs `.structured_output`. `--permission-mode bypassPermissions` is always passed,
// unconditionally, on every call: these are unattended calls with no person at a terminal to approve
// anything, so the loosest mode is simply always correct — found by dogfooding M1.12, headless `-p` mode with
// no permission mode set silently DENIES every Edit/Write prompt, so Implement kept "finishing without
// committing" no matter how clear the criteria were, until this was added. What actually keeps Define/Check
// read-only is `--disallowedTools Edit Write NotebookEdit`, not the permission mode: found by dogfooding
// M1.12, a fully-tooled real agent will otherwise just try to make the edit itself during Define (or poke at
// files during Check) rather than stay in its planning/review role. Implement is the only step allowed to
// touch files. `--safe-mode` is always passed too: found
// by dogfooding M1.12, a real agent invoked WITHOUT it auto-discovers the host machine's own CLAUDE.md and
// installed skills/plugins/hooks and can apply the invoking session's own operational rules (e.g. another
// project's "always self-invoke this before editing" skill) to the WorkItem it is meant to just define/
// implement/check — contamination from whatever happens to be on the machine, not the project. `--safe-mode`
// (not `--bare`) is the fix: it disables the same ambient customizations but leaves OAuth/keychain auth
// working, unlike `--bare` (auth-only, see docs/adapters.md's spike section). A project that WANTS the agent
// to have specific skills/plugins during these steps opts in explicitly via repeatable `--plugin-dir <path>`
// in its own adapter config, never by ambient accident. `define` and `implement` each keep their OWN session
// id, keyed by Delivery, in their own small state file (P5: adapters own their state, never read another's —
// `implement` never reads `define`'s file, and vice versa). `check` never stores or reads a session id: P8
// requires a fresh session on every call, so it simply never touches either state file.
//
// State file: ~/.local/state/ship/agent-claude/<port>.json = { [delivery]: { session, costUsd? } } (a bare
// session-id string, the pre-harlo-56 shape, still reads as `{ session }`). `check` has none.
//
// Crash vs `failed` (`implement` only): once the agent has made a real commit in the workspace, an error
// is never swallowed into `failed` (that would mean "changed nothing", which is false) — it escapes the
// top-level catch's `failed` instead, so the process exits non-zero: a crash, per docs/adapters.md.
//
// Usage per call (harlo-56): every Result built after a CLI reply was parsed — ok, question or failed — carries
// a `usage` evidence item (see USAGE_FIELDS), and a crash after a parsed reply writes it as the last stderr line,
// `ship-usage: {json}`, which the Runner journals as the `adapter_error` entry's info. Checked against the real
// CLI (2.1.287) on 2026-10-02 with a two-call `claude -p` / `claude -p --resume <id>` sequence: on the resumed
// call `usage`, `duration_ms` and `num_turns` cover THAT call only (input/output/cache tokens the size of one
// turn, 5.8s vs 15.2s, 1 turn), but `total_cost_usd` is the SESSION total (0.0415 then 0.0763, the sum of both
// calls; `modelUsage` is cumulative too). So tokens, duration and turns pass through as they come, and the cost
// is recorded as the difference from the session total stored next to the session id: `implement-1` never
// includes `define-1`'s cost, and a resumed `define-2` never includes `define-1`'s. A resumed call with no
// stored total (a pre-harlo-56 state file) leaves the cost out rather than guess it.
import { existsSync, mkdirSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import type { EvidenceItem, Finding, Stdin, Usage, WorkItem } from "../../../../src/contracts/common";
import type { CheckPayload, DefinePayload, ImplementFeedback, ImplementPayload } from "../../../../src/contracts/ports";
import { schemaFor } from "../../../../src/contracts/ports";
import { check } from "../../../../src/contracts/validate";
import { STEP_PORTS, type StepPort } from "../../../../src/core/ports/agent";

/** `usage` is set by callAgent once this run's CLI reply has parsed; every Result (and crash) after that carries it. */
type Ctx = { agentBin: string; pluginDirs: string[]; usage?: Usage };

/** Thrown instead of returning `failed`, once a real commit has happened (implement only): a crash, never `failed`. */
class Crash extends Error {}

/** The last stderr line of a crash after a parsed reply: this prefix, then the Usage as JSON. */
const USAGE_LINE_PREFIX = "ship-usage: ";

const expandHome = (dir: string): string =>
  dir === "~" ? homedir() : dir.startsWith("~/") ? join(homedir(), dir.slice(2)) : dir;

// ── Session state, per port, keyed by Delivery. `check` never calls these (P8). ──
/** A Delivery's session, and the CLI's cumulative `total_cost_usd` for it as of its last reply (harlo-56).
 *  `lastQuestion` (define only): the `clarify` question text asked on the most recent `question` reply, so a
 *  repeat of the same text on the next resumed call can be caught instead of asked again forever. */
type Session = { session: string; costUsd?: number; lastQuestion?: string };

const stateFile = (port: "define" | "implement"): string =>
  join(expandHome("~/.local/state/ship/agent-claude"), `${port}.json`);

const readState = (port: "define" | "implement"): Record<string, Session> => {
  const file = stateFile(port);
  if (!existsSync(file)) return {};
  const raw = JSON.parse(readFileSync(file, "utf8")) as Record<string, string | Session>;
  return Object.fromEntries(Object.entries(raw).map(([d, v]) => [d, typeof v === "string" ? { session: v } : v]));
};

/** Records this reply's session and its session-total cost, so the next resumed call can take the difference.
 *  `lastQuestion` (define only) overwrites the prior one, or is dropped once the reply carries no question. */
const saveSession = (
  port: "define" | "implement", state: Record<string, Session>, delivery: string, reply: AgentReply, lastQuestion?: string,
): void => {
  if (!reply.session_id) return;
  const total = figureOf(reply.total_cost_usd);
  const file = stateFile(port);
  mkdirSync(dirname(file), { recursive: true });
  const session: Session = { session: reply.session_id, ...(total === undefined ? {} : { costUsd: total }), ...(lastQuestion === undefined ? {} : { lastQuestion }) };
  writeFileSync(file, JSON.stringify({ ...state, [delivery]: session }));
};

// ── The agent binary ──
type AgentReply = {
  is_error: boolean; result: string; structured_output?: unknown; session_id?: string;
  usage?: Record<string, unknown>; total_cost_usd?: unknown; duration_ms?: unknown; num_turns?: unknown;
};

/** A reported figure, or undefined when absent or not a non-negative finite number (never trusted blindly). */
const figureOf = (value: unknown): number | undefined =>
  typeof value === "number" && Number.isFinite(value) && value >= 0 ? value : undefined;

/**
 * The one place the CLI's reply names map to the Usage item's (harlo-56):
 *   usage.input_tokens                → inputTokens
 *   usage.output_tokens               → outputTokens
 *   usage.cache_read_input_tokens     → cacheReadTokens
 *   usage.cache_creation_input_tokens → cacheCreationTokens
 *   total_cost_usd                    → costUsd (session total on the CLI; this call's share here, see header)
 *   duration_ms                       → durationMs
 *   num_turns                         → turns
 */
const USAGE_FIELDS: [keyof Usage, (reply: AgentReply) => unknown][] = [
  ["inputTokens", (r) => r.usage?.input_tokens],
  ["outputTokens", (r) => r.usage?.output_tokens],
  ["cacheReadTokens", (r) => r.usage?.cache_read_input_tokens],
  ["cacheCreationTokens", (r) => r.usage?.cache_creation_input_tokens],
  ["costUsd", (r) => r.total_cost_usd],
  ["durationMs", (r) => r.duration_ms],
  ["turns", (r) => r.num_turns],
];

/** This call's Usage: fields the reply left out stay out; undefined when it reported none. `costBefore` is the
 *  session's cost total before this call (0 for a fresh session, undefined when a resumed one's is unknown). */
const usageOf = (reply: AgentReply, costBefore: number | undefined): Usage | undefined => {
  const usage: Usage = {};
  for (const [name, read] of USAGE_FIELDS) {
    const value = figureOf(read(reply));
    if (value !== undefined) usage[name] = value;
  }
  if (usage.costUsd !== undefined) {
    // Rounded to 1e-9 USD so the difference of two floats doesn't print as 0.034725000000000006.
    const delta = costBefore === undefined ? -1 : Math.round((usage.costUsd - costBefore) * 1e9) / 1e9;
    if (delta >= 0) usage.costUsd = delta;
    else delete usage.costUsd;
  }
  return Object.keys(usage).length > 0 ? usage : undefined;
};

/** Define and Check are planning/review steps, never editors (P1: control flow, including whether a change
 *  happens, lives in the core, not the agent) — found by dogfooding M1.12: a fully-tooled real agent will
 *  otherwise just try to make the edit itself during Define, then get stuck when headless mode silently
 *  refuses the write. Implement is the only step allowed to touch files. */
const NO_EDIT_TOOLS = ["Edit", "Write", "NotebookEdit"];

type CallAgentArgs = {
  ctx: Ctx; prompt: string; schema: unknown; resume: Session | undefined; cwd?: string; disallowedTools?: string[];
};

/** Every real call runs unattended, so permission mode is always the loosest available
 *  (`bypassPermissions`, not `acceptEdits`) — there is no person at a terminal to approve anything, and
 *  --disallowedTools is what actually keeps Define/Check from touching files, not the permission mode. Found
 *  by dogfooding M1.12: threading a per-call permission-mode override through every call site added
 *  plumbing for a value that should just always be this. */
const callAgent = async ({ ctx, prompt, schema, resume, cwd, disallowedTools }: CallAgentArgs): Promise<AgentReply> => {
  const args = [
    ctx.agentBin, "-p", prompt, "--output-format", "json", "--json-schema", JSON.stringify(schema), "--safe-mode",
    "--permission-mode", "bypassPermissions",
    ...ctx.pluginDirs.flatMap((dir) => ["--plugin-dir", dir]),
    ...(resume ? ["--resume", resume.session] : []),
    ...(disallowedTools && disallowedTools.length > 0 ? ["--disallowedTools", ...disallowedTools] : []),
  ];
  const proc = Bun.spawn(args, { cwd, stdout: "pipe", stderr: "pipe" });
  // M1.8 spike: even a non-zero exit (e.g. auth failure) still prints one valid JSON object, so stdout is
  // always parsed as JSON first; the branch is on `is_error`, never on the exit code.
  const [out] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const reply = JSON.parse(out) as AgentReply;
  ctx.usage = usageOf(reply, resume ? resume.costUsd : 0);
  return reply;
};

/** This call's Usage as evidence, when the CLI reported any (P9: opaque, never read by the core). */
const usageEvidence = (ctx: Ctx): { evidence?: EvidenceItem[] } =>
  ctx.usage ? { evidence: [{ label: "usage", usage: ctx.usage }] } : {};

/** Define/Implement/Check success paths: the agent's raw reply text, surfaced as evidence (P9: opaque, never read
 *  by the core) so a human can later judge the real reasoning behind the structured body, then the usage item.
 *  The reasoning is omitted when empty, and never on the failure path (which already surfaces it via `info`). */
const evidenceOf = (ctx: Ctx, reply: AgentReply): { evidence?: EvidenceItem[] } => {
  const evidence: EvidenceItem[] = [
    ...(reply.result ? [{ label: "reasoning", text: reply.result }] : []), ...(usageEvidence(ctx).evidence ?? []),
  ];
  return evidence.length > 0 ? { evidence } : {};
};

/** `failed` with this call's usage, once a reply has parsed (changed nothing, but the call still cost). */
const failed = (ctx: Ctx, info: string): unknown => ({ status: "failed", info, ...usageEvidence(ctx) });

const git = (dir: string, args: string[]): { code: number; stdout: string; stderr: string } => {
  const proc = Bun.spawnSync(["git", "-C", dir, ...args], { stdout: "pipe", stderr: "pipe" });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
};

const headSha = (dir: string): string => {
  const head = git(dir, ["rev-parse", "HEAD"]);
  if (head.code !== 0) throw new Error(`git rev-parse HEAD failed in ${dir}: ${head.stderr}`);
  return head.stdout.trim();
};

// ── The Delivery workspace vs the main-line checkout (harlo-53) ──
// Found by dogfooding: Define ran in the adapter's own cwd — the main-line checkout — so its runbook named that
// path, and Implement followed it there and committed on the integration branch instead of `ship/<delivery>`.
// Every step now runs in, and is told to stay in, the Delivery workspace; Implement and Check also verify it.

/** The main-line checkout: the git toplevel of this adapter's own process cwd (the Runner spawns it from
 *  there). Undefined outside a repo, or when that toplevel IS the workspace — then there is nothing to forbid. */
const mainLineOf = (workspace: string): string | undefined => {
  const top = git(process.cwd(), ["rev-parse", "--show-toplevel"]);
  if (top.code !== 0) return undefined;
  const path = top.stdout.trim();
  const real = (dir: string): string => { try { return realpathSync(dir); } catch { return dir; } };
  return real(path) === real(workspace) ? undefined : path;
};

// ── The main-line branch (harlo-52) ──
// Found by dogfooding on a repo whose main line is `dogfood`: agents assumed `main`, so Define wrote
// `git diff main` into criteria and Check counted the main line's own newer commits as the changeset's files.
// The branch comes from workspace.setup (payload `base`); prompts never name a branch the payload didn't give.

/** The ref to diff against: the payload's `base`, or a placeholder for a Delivery that predates it. */
const baseRef = (base: string | undefined): string => base ?? "<main-line branch>";

/** The three-dot diff that is this Delivery's changeset: only commits on `ship/<delivery>` since it left the base. */
const scopeDiff = (base: string | undefined): string => `\`git diff ${baseRef(base)}...HEAD\``;

/** Stated in every prompt, fresh or resumed: a resumed session must get it too, it may predate this rule. */
const workspaceRule = (workspace: string, mainLine: string | undefined, delivery: string, base: string | undefined): string[] => [
  `Delivery workspace: ${workspace}`,
  `This is the only directory to read, edit, run commands or commit in. Never \`cd\` into any other checkout, ${
    mainLine ? `including the main-line checkout at ${mainLine}` : "including the main-line/integration checkout"}.`,
  base ? `Main-line branch: ${base}` : `Main-line branch: not recorded; it is the branch ship/${delivery} was created from.`,
  `This Delivery's branch is ship/${delivery}, branched off ${base ?? "the main-line branch"}. Scope and diffs compare `
    + `against it with a three-dot diff, ${scopeDiff(base)}; ${base
      ? "do not assume the main-line branch has any other name."
      : "find which branch that is rather than assuming a conventional default name."}`,
];

type MainLineMark = { path: string; head: string; changes: Set<string> };

/** Tracked-file changes only (`--untracked-files=no`): a pre-existing dirty tree is fine, only new entries count. */
const trackedChanges = (dir: string): Set<string> =>
  new Set(git(dir, ["status", "--porcelain", "--untracked-files=no"]).stdout.split("\n").filter((l) => l !== ""));

const headOrEmpty = (dir: string): string => git(dir, ["rev-parse", "-q", "--verify", "HEAD"]).stdout.trim();

const markMainLine = (path: string | undefined): MainLineMark | undefined =>
  path === undefined ? undefined : { path, head: headOrEmpty(path), changes: trackedChanges(path) };

/** Why the main-line checkout no longer matches its mark (HEAD moved or new tracked changes), else undefined. */
const mainLineStray = (mark: MainLineMark | undefined): string | undefined => {
  if (!mark) return undefined;
  const head = headOrEmpty(mark.path);
  if (head !== mark.head) return `agent moved HEAD of the main-line checkout ${mark.path} (${mark.head} -> ${head})`;
  const added = [...trackedChanges(mark.path)].filter((line) => !mark.changes.has(line));
  if (added.length > 0) return `agent changed tracked files in the main-line checkout ${mark.path}: ${added.join(", ")}`;
  return undefined;
};

// ── define ──
const defineSchema = {
  type: "object",
  properties: {
    criteria: { type: "array", items: { type: "string" }, description: "Acceptance criteria, each one independently checkable." },
    runbook: {
      type: "array", items: { type: "string" },
      description: "Steps or commands, run from the Delivery workspace without modifying it, that show each criterion holds.",
    },
    question: {
      type: "string",
      description: "Set instead of criteria and runbook only when the WorkItem cannot be defined without an answer: one question for the Principal.",
    },
  },
  required: [],
  additionalProperties: false,
} as const;

/** Fresh call: the full WorkItem framing. A resumed call sends ONLY the new delta (feedback/answer) — the
 *  resumed session already has the original task in its history; resending the whole thing on top of "here's
 *  an answer" reads as a brand-new ambiguous request and was found, by dogfooding M1.12, to make the agent
 *  re-enter its confirm-first loop indefinitely instead of proceeding. */
type DefinePromptArgs = {
  workItem: WorkItem; payload: DefinePayload; resume: boolean; workspace: string; mainLine: string | undefined;
  delivery: string; priorQuestion?: string;
};

const definePrompt = ({ workItem, payload, resume, workspace, mainLine, delivery, priorQuestion }: DefinePromptArgs): string => {
  const delta: string[] = [];
  if (payload.feedback !== undefined) delta.push(`Feedback from a prior review: ${payload.feedback}`);
  if (payload.answer !== undefined) {
    delta.push(
      priorQuestion !== undefined
        ? `Answer to your previous question ("${priorQuestion}"): ${payload.answer}. Do not repeat this or any `
          + "earlier question — it is answered. Proceed to a criteria/runbook verdict."
        : `Answer to your previous question: ${payload.answer}`,
    );
  }
  // harlo-53: Implement and Check follow the runbook literally, so a hard-coded path sends them out of the workspace.
  const rule = [
    ...workspaceRule(workspace, mainLine, delivery, payload.base),
    "The runbook must run from the Delivery workspace and must not hard-code any other checkout path.",
    // harlo-52: Implement and Check run these commands as written, so a wrong base or a two-dot diff mis-scopes them.
    `Any diff or scope command in the criteria and runbook must use ${scopeDiff(payload.base)}: never another branch `
      + `name, and never a two-dot diff against ${baseRef(payload.base)}.`,
  ].join("\n");
  if (resume) {
    return [rule, ...delta, "Reply now with the criteria/runbook (or question) fields — no further questions."].join("\n\n");
  }
  return [
    `WorkItem ${workItem.key}: ${workItem.title}`,
    workItem.body,
    "Define acceptance criteria and a runbook for verifying them.",
    rule,
    ...delta,
  ].join("\n\n");
};

const defineRun = async (ctx: Ctx, stdin: Stdin): Promise<unknown> => {
  const payload = stdin.payload as DefinePayload;
  // harlo-53: never fall back to the adapter's own cwd — that is the main-line checkout.
  const workspace = stdin.workspace;
  if (!workspace) throw new Error("define run requires a workspace (from workspace.setup)");
  const mainLine = mainLineOf(workspace);
  // Resume only a session this delivery already has: a delta with no stored session gets the full framing.
  const delta = payload.feedback !== undefined || payload.answer !== undefined;
  const state = readState("define");
  const session = delta ? state[stdin.delivery] : undefined;
  const resume = session !== undefined;
  const priorQuestion = session?.lastQuestion;
  const reply = await callAgent({
    ctx, prompt: definePrompt({ workItem: stdin.workItem, payload, resume, workspace, mainLine, delivery: stdin.delivery, priorQuestion }), schema: defineSchema,
    resume: session, cwd: workspace, disallowedTools: NO_EDIT_TOOLS,
  });
  if (reply.is_error) {
    saveSession("define", state, stdin.delivery, reply);
    return failed(ctx, reply.result);
  }
  const out = reply.structured_output as { criteria?: string[]; runbook?: string[]; question?: string } | undefined;
  if (out?.question) {
    // The agent was just told its previous question was answered, yet asked the identical one again: it is
    // stuck in a confirm-first loop (M1.12's original failure mode, recurring). Fail instead of re-asking
    // forever — a human/principal already answered this once and the answer did not register.
    if (payload.answer !== undefined && out.question === priorQuestion) {
      saveSession("define", state, stdin.delivery, reply, out.question);
      return failed(ctx, `define repeated its question after being answered: ${out.question}`);
    }
    saveSession("define", state, stdin.delivery, reply, out.question);
    return { status: "question", about: "clarify", prompt: out.question, ...usageEvidence(ctx) };
  }
  saveSession("define", state, stdin.delivery, reply);
  if (!out?.criteria || !out?.runbook) throw new Error(`agent reply missing criteria/runbook: ${reply.result}`);
  return { status: "ok", body: { criteria: out.criteria, runbook: out.runbook }, ...evidenceOf(ctx, reply) };
};

// ── implement ──
const implementSchema = {
  type: "object",
  properties: { summary: { type: "string" } },
  required: [],
  additionalProperties: false,
} as const;

/** Asked for only when the payload carried `feedback`: what the agent did with the Principal's comment, so the
 *  outcome is journaled in the `ok` body rather than buried in free-text reasoning (harlo-38). */
const implementFeedbackSchema = {
  type: "object",
  properties: {
    summary: { type: "string" },
    feedback: {
      type: "object",
      properties: { outcome: { type: "string", enum: ["applied", "declined"] }, reason: { type: "string" } },
      required: ["outcome", "reason"],
      additionalProperties: false,
    },
  },
  required: ["feedback"],
  additionalProperties: false,
} as const;

/** The Principal's comment, framed as a directive, not context. Found by dogfooding (harlo-38): a bare
 *  `Feedback: …` line next to the same finding let a resumed agent re-explain the code it already wrote instead
 *  of changing it — so the framing ranks the comment above the agent's own earlier reading and names the only
 *  two acceptable replies. */
const feedbackDirective = (feedback: string): string[] => [
  "PRINCIPAL DIRECTIVE — this takes priority over your earlier reading of the same finding:",
  "<<<",
  feedback,
  ">>>",
  "Either make the requested change and commit it, or explicitly decline it with a stated reason.",
  "Re-explaining or defending the existing code is not an acceptable response.",
  'Report what you did in the `feedback` field: outcome "applied" or "declined", with a non-empty reason.',
];

/** Fresh call: the full task framing, then any delta. A resumed call sends ONLY the new delta
 *  (findings/feedback/answer) — see definePrompt's comment for why resending the whole task on a resumed session
 *  backfires. A delta can arrive fresh: Define-gate `accept` with a comment is the first Implement (harlo-51). */
type ImplementPromptArgs = {
  workItem: WorkItem; payload: ImplementPayload; resume: boolean; workspace: string; mainLine: string | undefined;
  delivery: string;
};

const implementPrompt = ({ workItem, payload, resume, workspace, mainLine, delivery }: ImplementPromptArgs): string => {
  const rule = workspaceRule(workspace, mainLine, delivery, payload.base);
  const delta: string[] = [];
  if (payload.findings.length > 0) {
    delta.push("Findings from a prior check:", ...payload.findings.map((f) => `- ${f.text}${f.ref ? ` (${f.ref})` : ""}`));
  }
  if (payload.feedback !== undefined) delta.push(...feedbackDirective(payload.feedback));
  if (payload.answer !== undefined) delta.push(`Answer to your previous question: ${payload.answer}`);
  if (resume) return [...rule, ...delta, "Continue implementing and commit your changes — no further questions."].join("\n");
  return [
    `WorkItem ${workItem.key}: ${workItem.title}`,
    "Implement it in this working directory and commit your changes.",
    ...rule,
    "Criteria:", ...payload.criteria.map((c) => `- ${c}`),
    ...delta,
  ].join("\n");
};

/** The agent's `feedback` report, or undefined when it is missing or malformed (outcome outside the enum,
 *  empty reason) — never trusted blindly, the schema is guidance the agent may not follow. */
const feedbackOutcome = (out: unknown): ImplementFeedback | undefined => {
  const fb = (out as { feedback?: { outcome?: unknown; reason?: unknown } } | undefined)?.feedback;
  if (fb?.outcome !== "applied" && fb?.outcome !== "declined") return undefined;
  if (typeof fb.reason !== "string" || fb.reason.trim() === "") return undefined;
  return { outcome: fb.outcome, reason: fb.reason };
};

const implementRun = async (ctx: Ctx, stdin: Stdin): Promise<unknown> => {
  const payload = stdin.payload as ImplementPayload;
  const workspace = stdin.workspace;
  if (!workspace) throw new Error("implement run requires a workspace (from workspace.setup)");
  const before = headSha(workspace);
  // harlo-53: defence in depth behind the prompt rule — mark the main-line checkout, verify it after the call.
  const mainLine = mainLineOf(workspace);
  const mark = markMainLine(mainLine);
  /** A stray main-line change is never `ok`: `failed` if the workspace has no new commit, else a crash. */
  const strayResult = (committed: boolean): unknown => {
    const stray = mainLineStray(mark);
    if (stray === undefined) return undefined;
    if (committed) throw new Crash(stray);
    return failed(ctx, stray);
  };

  // A re-issue after a fix round, feedback or a question answer resumes this delivery's own Implement session.
  // With no stored session yet (the first call, even one carrying Define-gate feedback) it starts fresh.
  const delta = payload.findings.length > 0 || payload.feedback !== undefined || payload.answer !== undefined;
  const state = readState("implement");
  const session = delta ? state[stdin.delivery] : undefined;
  const resume = session !== undefined;
  const prompt = implementPrompt({ workItem: stdin.workItem, payload, resume, workspace, mainLine, delivery: stdin.delivery });
  const withFeedback = payload.feedback !== undefined;
  const schema = withFeedback ? implementFeedbackSchema : implementSchema;

  let reply: AgentReply;
  try {
    reply = await callAgent({ ctx, prompt, schema, resume: session, cwd: workspace });
  } catch (error) {
    const committed = headSha(workspace) !== before;
    const stray = strayResult(committed);
    if (stray !== undefined) return stray;
    if (committed) throw new Crash(`agent call errored after a commit: ${String(error)}`);
    throw error;
  }

  const after = headSha(workspace);
  const committed = after !== before;
  saveSession("implement", state, stdin.delivery, reply);
  const stray = strayResult(committed);
  if (stray !== undefined) return stray;

  if (reply.is_error) {
    if (committed) throw new Crash(`agent reported is_error after a commit: ${reply.result}`);
    return failed(ctx, reply.result); // nothing committed: safe, changed nothing
  }
  const changeset = `ship/${stdin.delivery}@${after}`;
  if (!withFeedback) {
    if (!committed) return failed(ctx, "agent finished without committing any changes");
    return { status: "ok", body: { changeset }, ...evidenceOf(ctx, reply) };
  }

  // Feedback given: a reply without a valid outcome never passes as a normal ok. Validated HERE, in the
  // adapter (the contract can't see the payload, so it can't require the field): `failed` when nothing was
  // committed, a crash once a commit happened (the crash-vs-`failed` rule above).
  const outcome = feedbackOutcome(reply.structured_output);
  if (!outcome) {
    const info = `agent reply to feedback has no valid feedback.outcome (applied|declined) with a reason: ${reply.result}`;
    if (committed) throw new Crash(info);
    return failed(ctx, info);
  }
  // A stated decline is a real answer, so it may leave HEAD where it was; an "applied" with no commit is not.
  if (!committed && outcome.outcome === "applied") {
    return failed(ctx, "agent reported feedback applied but committed no changes");
  }
  return { status: "ok", body: { changeset, feedback: outcome }, ...evidenceOf(ctx, reply) };
};

// ── check ──
// Keyed on `verdict`, mirroring `checkBody` in src/contracts/ports.ts: only the "decide" branch requires
// `about`, so a schema-conformant "decide" reply can never omit it (a plain `enum`+`required: ["verdict"]`
// shape let a conformant reply carry `verdict:"decide"` with no `about`, which checkRun then forwarded
// unchecked into a Result that violated `checkBody`'s own schema).
const findingSchema = {
  type: "object",
  properties: {
    text: { type: "string", description: "One specific problem, stated so Implement can act on it." },
    ref: { type: "string", description: "Where it is: prefer a file:line; a criterion or command only when no file location applies." },
  },
  required: ["text"],
} as const;

// Flat, not a top-level oneOf: found by dogfooding M1.12, the real API rejects a tool input_schema with
// oneOf/allOf/anyOf at its root ("400 ... does not support oneOf, allOf, or anyOf at the top level") — the
// f3 fix's schema shape worked only against the fake test bin, never the real CLI. The runtime guard in
// checkRun below (not the schema) is what actually enforces "about" on a "decide" verdict; this schema is
// best-effort guidance for the agent, not a contract the API can validate structurally.
const checkSchema = {
  type: "object",
  properties: {
    verdict: {
      type: "string", enum: ["pass", "fix", "decide"],
      description: "pass: every criterion holds. fix: specific problems Implement can fix; list them in findings. "
        + "decide: the Principal must choose to keep going, accept as is, or stop; set about and list findings.",
    },
    about: {
      type: "string", enum: ["scope", "advisory"],
      description: "Required with decide, omitted otherwise. scope: what the WorkItem should cover is in question. "
        + "advisory: the findings are judgment calls that need not block landing.",
    },
    findings: { type: "array", items: findingSchema },
  },
  required: ["verdict"],
  additionalProperties: false,
} as const;

const checkPrompt = (workItem: WorkItem, payload: CheckPayload, workspace: string, delivery: string): string => {
  const lines = [
    `WorkItem ${workItem.key}: ${workItem.title}`,
    "Check this changeset against the acceptance criteria.",
    ...workspaceRule(workspace, mainLineOf(workspace), delivery, payload.base),
    // harlo-52: a two-dot diff, or the wrong base, counts the main line's own newer commits as this changeset's.
    `Judge scope by ${scopeDiff(payload.base)} only: commits on ${baseRef(payload.base)} that are not on `
      + `ship/${delivery} are not part of this changeset, and their files never count as its files.`,
    `Changeset: ${payload.changeset}`,
    "Criteria:", ...payload.criteria.map((c) => `- ${c}`),
  ];
  if (payload.answer !== undefined) lines.push(`Answer to your previous question: ${payload.answer}`);
  return lines.join("\n");
};

/** harlo-53: a changeset committed anywhere but `ship/<delivery>` in the workspace (e.g. on the main-line
 *  checkout) is not this Delivery's work — reviewing it would pass work that integrate never lands. */
const changesetMismatch = (workspace: string, delivery: string, changeset: string): string | undefined => {
  const at = changeset.lastIndexOf("@");
  const branch = changeset.slice(0, at);
  const sha = changeset.slice(at + 1);
  const expected = `ship/${delivery}`;
  if (at === -1 || branch !== expected) return `changeset ${changeset} is not on this Delivery's branch ${expected}`;
  if (git(workspace, ["merge-base", "--is-ancestor", sha, expected]).code !== 0) {
    return `changeset commit ${sha} is not on branch ${expected} in the workspace ${workspace}`;
  }
  return undefined;
};

const checkRun = async (ctx: Ctx, stdin: Stdin): Promise<unknown> => {
  const payload = stdin.payload as CheckPayload;
  const workspace = stdin.workspace;
  if (!workspace) throw new Error("check run requires a workspace (from workspace.setup)");
  const mismatch = changesetMismatch(workspace, stdin.delivery, payload.changeset);
  if (mismatch !== undefined) return { status: "failed", info: mismatch };
  const prompt = checkPrompt(stdin.workItem, payload, workspace, stdin.delivery);
  // P8: Check runs independently of the worker that implemented — always a fresh session, so no `--resume`
  // and no read of either `define`'s or `implement`'s state file, ever.
  const reply = await callAgent({
    ctx, prompt, schema: checkSchema, resume: undefined, cwd: workspace, disallowedTools: NO_EDIT_TOOLS,
  });
  if (reply.is_error) return failed(ctx, reply.result);
  const out = reply.structured_output as { verdict?: string; about?: string; findings?: Finding[] } | undefined;
  let result: unknown;
  if (out?.verdict === "pass") result = { status: "ok", body: { verdict: "pass" } };
  else if (out?.verdict === "fix") result = { status: "ok", body: { verdict: "fix", findings: out.findings ?? [] } };
  else if (out?.verdict === "decide") {
    // A schema-conformant reply can't get here with `about` missing/invalid any more (see checkSchema above),
    // but the agent's actual reply is never trusted blindly: guard again at runtime, never forward an `about`
    // that isn't one of the two values `checkBody` accepts, so a bad reply can't produce a contract-violating
    // Result. Nothing has been committed at Check time, so `failed` (via the top-level catch, below) is safe.
    if (out.about !== "scope" && out.about !== "advisory") {
      throw new Error(`agent reply had verdict "decide" without a valid "about" (scope|advisory): ${reply.result}`);
    }
    result = { status: "ok", body: { verdict: "decide", about: out.about, findings: out.findings ?? [] } };
  } else {
    throw new Error(`agent reply had an unexpected verdict: ${reply.result}`);
  }
  result = { ...(result as Record<string, unknown>), ...evidenceOf(ctx, reply) };
  // Belt-and-braces: validate the mapped Result against the port's own stdout contract before printing it,
  // mirroring how adapters/state/files.ts validates its own stored payload on the way in.
  const invalid = check(schemaFor("check", "run")!.stdout, result);
  if (invalid) throw new Error(`agent-claude check would have printed a contract-violating Result: ${invalid}`);
  return result;
};

const RUN: Record<StepPort, (ctx: Ctx, stdin: Stdin) => Promise<unknown>> = {
  define: defineRun, implement: implementRun, check: checkRun,
};
const cancelOp = async (): Promise<unknown> => ({ status: "ok", body: {} }); // nothing runs in the background

/** argv after the script: `[--agent-bin <path>] [--plugin-dir <path>]... <port> <op>`; --agent-bin defaults
 *  to `claude` on PATH; --plugin-dir is repeatable and defaults to none (a clean --safe-mode agent). */
const parseArgs = (
  args: string[],
): { agentBin: string; pluginDirs: string[]; port: string | undefined; op: string | undefined } => {
  let agentBin = "claude";
  const pluginDirs: string[] = [];
  const positional: string[] = [];
  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === "--agent-bin") { agentBin = args[i + 1] ?? agentBin; i += 1; }
    else if (args[i] === "--plugin-dir") { if (args[i + 1] !== undefined) pluginDirs.push(args[i + 1] as string); i += 1; }
    else positional.push(args[i] as string);
  }
  const [port, op] = positional;
  return { agentBin, pluginDirs, port, op };
};

const main = async (ctx: Ctx): Promise<unknown> => {
  const { port, op } = parseArgs(process.argv.slice(2));
  const stepPort = (STEP_PORTS as readonly string[]).includes(port ?? "") ? (port as StepPort) : undefined;
  const contract = stepPort && op ? schemaFor(stepPort, op) : undefined;
  const handler = op === "run" ? RUN[stepPort as StepPort] : op === "cancel" ? cancelOp : undefined;
  if (!stepPort || !contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as Stdin;
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return op === "cancel" ? cancelOp() : RUN[stepPort](ctx, stdin);
};

const { agentBin, pluginDirs } = parseArgs(process.argv.slice(2));
const ctx: Ctx = { agentBin, pluginDirs };
try {
  console.log(JSON.stringify(await main(ctx)));
} catch (error) {
  if (error instanceof Crash) {
    // A crash, never `failed`: a commit already happened. The usage line goes last, after the error, so it is
    // the last line of the stderr tail the Runner journals; exitCode (not process.exit) lets stderr flush.
    console.error(error.stack ?? error.message);
    if (ctx.usage) console.error(`${USAGE_LINE_PREFIX}${JSON.stringify(ctx.usage)}`);
    process.exitCode = 1;
  } else {
    console.log(JSON.stringify(failed(ctx, error instanceof Error ? error.message : String(error))));
  }
}
