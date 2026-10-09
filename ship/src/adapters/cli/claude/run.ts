// How every adapter that runs the claude CLI runs it (harlo-64): agent/claude/index.ts and principal/claude.ts
// both parse their argv with `parseAgentArgv` and call the CLI with `runClaude`, so the argv, the isolation
// defaults and the spawn are the same everywhere; reply interpretation (usage, sessions, answers) stays in each
// adapter. Adapter argv: `[--agent-bin=<path>] [--agent-arg=<--flag[=value]>]... [<extra string options>] <port>
// <op>`, parsed strictly by node:util, so an unknown option throws. Unit-tested in run.test.ts.
import { type ParseArgsOptionsConfig, parseArgs } from "node:util";

/** One claude flag, with its value when it takes one (`--strict-mcp-config` takes none). */
export type AgentArg = { flag: string; value?: string };

/** Isolation without `--safe-mode` (harlo-64): only the repo's own settings load, with every hook off, and no
 *  MCP server unless configured — so the host machine's plugins, hooks and MCP servers never reach the agent,
 *  while `--plugin-dir` plugins still load and OAuth/keychain auth still works. */
export const DEFAULT_AGENT_ARGS: readonly AgentArg[] = [
  { flag: "--setting-sources", value: "project" },
  { flag: "--settings", value: JSON.stringify({ disableAllHooks: true }) },
  { flag: "--strict-mcp-config" },
  { flag: "--mcp-config", value: JSON.stringify({ mcpServers: {} }) },
  { flag: "--permission-mode", value: "bypassPermissions" },
];

/** The adapter's own protocol depends on these, so configuring one is a startup error, never an override:
 *  output parsing (`--output-format`, `--json-schema`; `--verbose` turns `--output-format json` into a message
 *  array the reply parser can't read), session ownership (`--resume`; `--continue`, `--session-id` and
 *  `--fork-session` break it — Check must always start fresh (P8), Define/Implement own their session ids), the
 *  prompt (`--print`; `--input-format` changes how it is read) and Define/Check's read-only guard
 *  (`--disallowedTools` in either spelling). */
export const PROTECTED_FLAGS: readonly string[] = [
  "--print", "--output-format", "--json-schema", "--resume", "--disallowedTools", "--disallowed-tools",
  "--verbose", "--continue", "--session-id", "--fork-session", "--input-format",
];

/** One `--agent-arg` value: `--flag=value` splits on the FIRST `=` (the value may contain more), `--flag` alone
 *  is a boolean flag. Throws, naming the value, on a token not starting with `--` or a protected flag. */
export const parseAgentArg = (token: string): AgentArg => {
  if (!token.startsWith("--")) throw new Error(`--agent-arg must start with "--"; got ${JSON.stringify(token)}`);
  const at = token.indexOf("=");
  const arg: AgentArg = at === -1 ? { flag: token } : { flag: token.slice(0, at), value: token.slice(at + 1) };
  if (PROTECTED_FLAGS.includes(arg.flag)) {
    throw new Error(`--agent-arg cannot set ${arg.flag}: the adapter's own protocol owns it`);
  }
  return arg;
};

/** Defaults merged with configured args, flattened to argv tokens: a flag configured at all drops EVERY default
 *  occurrence of it, and all configured args follow the remaining defaults in configured order (so two
 *  `--plugin-dir`s both survive, and a flag with no default is simply appended). */
export const mergeAgentArgs = (defaults: readonly AgentArg[], configured: readonly AgentArg[]): string[] => {
  const configuredFlags = new Set(configured.map((arg) => arg.flag));
  const keptDefaults = defaults.filter((arg) => !configuredFlags.has(arg.flag));
  return [...keptDefaults, ...configured].flatMap((arg) => (arg.value === undefined ? [arg.flag] : [arg.flag, arg.value]));
};

/** What `parseAgentArgv` returns: the CLI to run, the merged claude args, the caller's own extra options and the
 *  positionals (`<port> <op>`). */
export type AgentArgv = {
  agentBin: string; agentArgs: string[]; options: Record<string, string | undefined>; positionals: string[];
};

/** Parses an adapter's argv: `--agent-bin` (default `claude` on PATH), each `--agent-arg` as ONE token
 *  (`--agent-arg=--plugin-dir=/x`; strict parsing rejects a dash-leading value given as a separate token) merged
 *  into DEFAULT_AGENT_ARGS, plus the caller's `extraOptions` (string-valued, e.g. agent/claude's `requirements`).
 *  Throws on an unknown option, a missing value, or a bad/protected --agent-arg: the caller exits 2. */
export const parseAgentArgv = (args: string[], extraOptions: readonly string[] = []): AgentArgv => {
  const spec: ParseArgsOptionsConfig = {
    ...Object.fromEntries(extraOptions.map((name) => [name, { type: "string" as const }])),
    "agent-bin": { type: "string" },
    "agent-arg": { type: "string", multiple: true },
  };
  const { values, positionals } = parseArgs({ args, options: spec, allowPositionals: true, strict: true });
  const configured = ((values["agent-arg"] ?? []) as string[]).map(parseAgentArg);
  const agentArgs = mergeAgentArgs(DEFAULT_AGENT_ARGS, configured);
  const options = Object.fromEntries(extraOptions.map((name) => [name, values[name] as string | undefined]));
  return { agentBin: (values["agent-bin"] as string | undefined) ?? "claude", agentArgs, options, positionals };
};

/** The CLI's one JSON reply (M1.8 spike shape); the usage figures are passed through untrusted (harlo-56). */
export type ClaudeReply = {
  is_error: boolean; result: string; structured_output?: unknown; session_id?: string;
  usage?: Record<string, unknown>; total_cost_usd?: unknown; duration_ms?: unknown; num_turns?: unknown;
};

/** One CLI call. `resume` is a session id to continue; `disallowedTools` keeps a call read-only (Define/Check). */
export type RunClaude = {
  agentBin: string; agentArgs: string[]; prompt: string; schema: unknown;
  resume?: string; disallowedTools?: string[]; cwd?: string;
};

/** The full argv: the protocol part (`-p`, `--output-format json`, `--json-schema`, `--resume`), the merged agent
 *  args, then `--disallowedTools` last, since it is variadic and would otherwise swallow what follows it. */
export const claudeArgv = (run: RunClaude): string[] => [
  run.agentBin, "-p", run.prompt, "--output-format", "json", "--json-schema", JSON.stringify(run.schema),
  ...(run.resume ? ["--resume", run.resume] : []),
  ...run.agentArgs,
  ...(run.disallowedTools && run.disallowedTools.length > 0 ? ["--disallowedTools", ...run.disallowedTools] : []),
];

/** Spawns the CLI and parses its stdout as JSON unconditionally: M1.8 spike, even a non-zero exit (e.g. an auth
 *  failure) prints one valid JSON object, so callers branch on `is_error`, never on the exit code. */
export const runClaude = async (run: RunClaude): Promise<ClaudeReply> => {
  const proc = Bun.spawn(claudeArgv(run), { cwd: run.cwd, stdout: "pipe", stderr: "pipe" });
  const [out] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  return JSON.parse(out) as ClaudeReply;
};
