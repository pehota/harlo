// harlo-64: how the claude-running adapters run claude — argv parsing, isolation defaults, `--agent-arg` merge.
import { describe, expect, test } from "bun:test";
import { DEFAULT_AGENT_ARGS, PROTECTED_FLAGS, claudeArgv, mergeAgentArgs, parseAgentArg, parseAgentArgv } from "./run";

const DEFAULT_ARGV = [
  "--setting-sources", "project", "--settings", '{"disableAllHooks":true}', "--strict-mcp-config",
  "--mcp-config", '{"mcpServers":{}}', "--permission-mode", "bypassPermissions",
];

describe("agent args (harlo-64)", () => {
  test("harlo-64: with nothing configured, the default argv is exactly the isolation set, no --safe-mode", () => {
    expect(mergeAgentArgs(DEFAULT_AGENT_ARGS, [])).toEqual(DEFAULT_ARGV);
  });

  test("harlo-64: --flag=value splits on the first = only", () => {
    expect(parseAgentArg('--mcp-config={"a":"b=c"}')).toEqual({ flag: "--mcp-config", value: '{"a":"b=c"}' });
    expect(parseAgentArg("--x=")).toEqual({ flag: "--x", value: "" });
  });

  test("harlo-64: a token without = is a boolean flag", () => {
    expect(parseAgentArg("--disable-slash-commands")).toEqual({ flag: "--disable-slash-commands" });
    expect(mergeAgentArgs([], [parseAgentArg("--disable-slash-commands")])).toEqual(["--disable-slash-commands"]);
  });

  test("harlo-64: a configured flag replaces every default occurrence; repeated configured flags all survive", () => {
    const configured = ['--mcp-config={"mcpServers":{"docs":{}}}', "--plugin-dir=/a", "--plugin-dir=/b"].map(parseAgentArg);
    const defaults = [...DEFAULT_AGENT_ARGS, { flag: "--mcp-config", value: "second" }];
    const argv = mergeAgentArgs(defaults, configured);
    expect(argv.filter((a) => a === "--mcp-config")).toHaveLength(1);
    expect(argv[argv.indexOf("--mcp-config") + 1]).toBe('{"mcpServers":{"docs":{}}}');
    expect(argv.slice(-4)).toEqual(["--plugin-dir", "/a", "--plugin-dir", "/b"]);
    expect(argv).toContain("--strict-mcp-config");
  });

  test("harlo-64: a flag with no default is appended after the defaults, in configured order", () => {
    const argv = mergeAgentArgs(DEFAULT_AGENT_ARGS, ["--model=opus", "--add-dir=/tmp/x"].map(parseAgentArg));
    expect(argv).toEqual([...DEFAULT_ARGV, "--model", "opus", "--add-dir", "/tmp/x"]);
  });

  test("harlo-64: --permission-mode is overridable", () => {
    const argv = mergeAgentArgs(DEFAULT_AGENT_ARGS, [parseAgentArg("--permission-mode=acceptEdits")]);
    expect(argv.filter((a) => a === "--permission-mode")).toHaveLength(1);
    expect(argv.slice(-2)).toEqual(["--permission-mode", "acceptEdits"]);
  });

  for (const flag of PROTECTED_FLAGS) {
    test(`harlo-64: protected ${flag} is rejected, naming it`, () => {
      expect(() => parseAgentArg(`${flag}=x`)).toThrow(flag);
      expect(() => parseAgentArg(flag)).toThrow(flag);
    });
  }

  for (const flag of ["--verbose", "--continue", "--session-id", "--fork-session", "--input-format"]) {
    test(`harlo-64: ${flag} is protected and rejected, naming it`, () => {
      expect(PROTECTED_FLAGS).toContain(flag);
      expect(() => parseAgentArg(`${flag}=x`)).toThrow(flag);
      expect(() => parseAgentArg(flag)).toThrow(flag);
    });
  }

  test("harlo-64: a token not starting with -- is rejected, naming it", () => {
    expect(() => parseAgentArg("-p")).toThrow('"-p"');
    expect(() => parseAgentArg("plugin-dir=/a")).toThrow('"plugin-dir=/a"');
  });

  test("harlo-64: parseAgentArgv reads --agent-bin, one-token --agent-args, extra options and positionals", () => {
    const parsed = parseAgentArgv(
      ["--agent-bin=/bin/fake", "--agent-arg=--plugin-dir=/a", "--requirements", "dod", "--agent-arg=--add-dir=/tmp/x", "define", "run"],
      ["requirements"],
    );
    expect(parsed).toEqual({
      agentBin: "/bin/fake", agentArgs: [...DEFAULT_ARGV, "--plugin-dir", "/a", "--add-dir", "/tmp/x"],
      options: { requirements: "dod" }, positionals: ["define", "run"],
    });
  });

  test("harlo-64: parseAgentArgv defaults --agent-bin to claude and the agent args to the isolation set", () => {
    expect(parseAgentArgv(["principal", "decide"])).toEqual({
      agentBin: "claude", agentArgs: DEFAULT_ARGV, options: {}, positionals: ["principal", "decide"],
    });
  });

  test("harlo-64: parseAgentArgv rejects an unknown option, e.g. the old adapter --plugin-dir", () => {
    expect(() => parseAgentArgv(["--plugin-dir", "/a", "define", "run"])).toThrow("--plugin-dir");
  });

  test("harlo-64: parseAgentArgv rejects --agent-arg with its token given separately", () => {
    expect(() => parseAgentArgv(["--agent-arg", "--plugin-dir=/a", "define", "run"])).toThrow("--agent-arg");
  });

  test("harlo-64: parseAgentArgv rejects a protected flag via --agent-arg, naming it", () => {
    expect(() => parseAgentArgv(["--agent-arg=--resume=abc", "define", "run"])).toThrow("--resume");
  });

  test("harlo-64: claudeArgv is protocol part, then --resume, then the agent args, then --disallowedTools last", () => {
    const agentArgs = mergeAgentArgs(DEFAULT_AGENT_ARGS, []);
    const base = { agentBin: "claude", agentArgs, prompt: "hi", schema: { type: "object" } };
    const head = ["claude", "-p", "hi", "--output-format", "json", "--json-schema", '{"type":"object"}'];
    expect(claudeArgv(base)).toEqual([...head, ...DEFAULT_ARGV]);
    expect(claudeArgv({ ...base, resume: "s1", disallowedTools: ["Edit", "Write"] }))
      .toEqual([...head, "--resume", "s1", ...DEFAULT_ARGV, "--disallowedTools", "Edit", "Write"]);
  });
});
