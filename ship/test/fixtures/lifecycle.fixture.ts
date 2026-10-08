// Test data for test/e2e/lifecycle.test.ts and terminal-principal.test.ts: a project whose every port is the
// scripted fake adapter except State (the real file adapter) and, when asked, the Principal (the real tty
// adapter), plus readers that go through the adapters, never around them.
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { RunnerStdin } from "../../src/contracts/common";
import type { TimedEntry } from "../../src/contracts/snapshot";
import type { Snapshot } from "../../src/core/types";
import { runPty, type Turn } from "./pty";

const ROOT = join(import.meta.dir, "..", "..");
const BIN = join(ROOT, "bin", "ship");
const FAKE = join(ROOT, "src", "adapters", "fake.ts");
const STATE = join(ROOT, "src", "adapters", "state", "files.ts");
const TTY = join(ROOT, "src", "adapters", "principal", "tty.ts");
const MD = join(ROOT, "src", "adapters", "tracker", "md.ts");

export const D = "k-1"; // every scenario runs WorkItem `k`, so its first Delivery

// ── Scripted stdouts ──
export const ok = (body: unknown = {}) => ({ status: "ok", body });
export const workItem = (title = "Greet by name", body = "Say hello.") => ok({ workItem: { key: "k", title, body } });
export const criteria = ["greets Ada by name"];
export const runbook = ["run greet Ada, see Hello, Ada"];
export const requirements = { criteria, runbook };
export const defined = ok({ requirements });
export const implemented = (changeset: string) => ok({ changeset });
export const verdict = (v: string, findings?: { text: string }[]) => ok(findings ? { verdict: v, findings } : { verdict: v });
export const question = (prompt: string, about: string) => ({ status: "question", prompt, about });
export const failed = (info: string) => ({ status: "failed", info });

/** Every step succeeds at once: Define → Accept → … → Land → … → Closed, with only the gates awaited. */
export const HAPPY = {
  "workspace.setup": ok({ path: "/ws/k-1", base: "trunk" }), "define.run": [defined], "implement.run": [implemented("c1")],
  "check.run": [verdict("pass")], "integrate.run": [verdict("landed")], "deploy.run": [verdict("live")],
  "verify.run": [verdict("pass")],
};

/** A Principal's answer as pasted into `ship signal`. */
export const answer = (text: string, comment?: string) =>
  JSON.stringify(ok({ answer: text, by: "person", ...(comment === undefined ? {} : { comment }) }));

const POLICY = {
  tracker: {
    outcomes: {
      delivered: { status: "done" }, accepted_with_failure: { status: "done-with-failure" },
      rolled_back: { status: "reopened", comment: true }, abandoned: { comment: true },
    },
  },
};

type Ran = { exit: number; out: Record<string, unknown> | null; stderr: string };
/** What the fake recorded: one Stdin per call, in call order. */
export type Logged = RunnerStdin;

/**
 * A temp project. `replies` is the fake's script ("<port>.<op>" → stdout or list of stdouts); the tracker
 * reads WorkItem `k` and teardown and Close's tracker.update succeed unless the scenario scripts otherwise.
 * Unscripted awaited calls (every Principal decide/ask) print `accepted`: the test answers with `ship signal`.
 * `principal: "tty"` puts the real tty Principal on that port instead, blocking on /dev/tty: drive it with
 * `shipPty()`, which answers gates inline via a real pty as they appear, in the same `ship` invocation.
 * `items` (key → frontmatter status) puts the real md Tracker on the tracker port instead, one `<key>.md` each
 * in `trackerDir`, so `ship next` and the tracker's status/comment writes are real.
 */
export const lifecycle = (
  replies: Record<string, unknown>, policy: Record<string, unknown> = {},
  { principal = "fake", items }: { principal?: "fake" | "tty"; items?: Record<string, string> } = {},
) => {
  const dir = mkdtempSync(join(tmpdir(), "ship-e2e-"));
  const stateDir = join(dir, "state");
  const script = join(dir, "script.json");
  const machinePath = join(dir, "machine.json");
  const fake = ["bun", FAKE, "--script", script];
  const trackerDir = join(dir, "tracker");
  mkdirSync(trackerDir);
  for (const [key, status] of Object.entries(items ?? {})) {
    writeFileSync(join(trackerDir, `${key}.md`), `---\nstatus: ${status}\ntitle: Item ${key}\n---\nDo ${key}.\n`);
  }

  const scriptReplies = { "tracker.read": workItem(), "tracker.update": ok(), "workspace.teardown": ok(), ...replies };
  writeFileSync(script, JSON.stringify({ replies: scriptReplies }));
  const adapters = Object.fromEntries(
    ["tracker", "workspace", "define", "implement", "check", "integrate", "deploy", "verify"].map((port) => [port, fake]),
  );
  if (items) adapters.tracker = ["bun", MD, "--dir", trackerDir];
  writeFileSync(join(dir, "ship.config.json"), JSON.stringify({ projectId: "e2e", adapters, policy: { ...POLICY, ...policy } }));
  const principalArgv = principal === "tty" ? ["bun", TTY] : fake;
  writeFileSync(machinePath, JSON.stringify({ principal: principalArgv, state: ["bun", STATE, "--dir", stateDir] }));

  const run = async (argv: string[], cwd: string, env: Record<string, string>, stdin?: string) => {
    const proc = Bun.spawn(argv, { cwd, env, stdout: "pipe", stderr: "pipe", stdin: stdin === undefined ? "ignore" : new Blob([stdin]) });
    const [stdout, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
    return { stdout, stderr, exit };
  };
  const env = { PATH: process.env.PATH ?? "", HOME: dir };
  const shipEnv = { ...env, SHIP_MACHINE_CONFIG: machinePath };

  const ship = async (...args: string[]): Promise<Ran> => {
    const { stdout, stderr, exit } = await run(["bun", BIN, ...args], dir, shipEnv);
    const line = stdout.trim();
    return { exit, out: line ? (JSON.parse(line) as Record<string, unknown>) : null, stderr };
  };

  /**
   * Run `bin/ship <args>` through a real pty (`principal: "tty"` only): as the Runner answers each gate
   * synchronously, `apply()`'s own queue drives straight through to the next one, so `turns` here may span
   * several gates in one call. Returns the same shape as `ship`, plus the raw pty transcript for assertions.
   */
  const shipPty = async (args: string[], turns: Turn[]): Promise<Ran & { ptyOutput: string }> => {
    const ran = await runPty(["bun", BIN, ...args], "", { cwd: dir, env: shipEnv, turns });
    const line = ran.stdout.trim();
    return { exit: ran.exit, out: line ? (JSON.parse(line) as Record<string, unknown>) : null, stderr: "", ptyOutput: ran.ptyOutput };
  };

  /** One Runner-only call on the file State adapter, exactly as the Runner makes it. */
  const state = async <Body>(op: string, payload: unknown): Promise<Body> => {
    const stdin: RunnerStdin = { id: null, delivery: D, port: "state", op, workItem: null, workspace: null, payload, tools: [] };
    const { stdout } = await run(["bun", STATE, "--dir", stateDir, "state", op], dir, env, JSON.stringify(stdin));
    const reply = JSON.parse(stdout) as { status: string; body: Body };
    if (reply.status !== "ok") throw new Error(`state ${op}: ${stdout}`);
    return reply.body;
  };
  const journal = async (): Promise<TimedEntry[]> => (await state<{ entries: TimedEntry[] }>("journal", { delivery: D })).entries;
  const snapshot = async (): Promise<Snapshot> => (await state<{ state: Snapshot }>("load", { delivery: D })).state;

  const log = (): Logged[] =>
    readFileSync(`${script}.stdin.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line) as Logged);

  /** Run a shell line verbatim with bash in the project, `ship` on PATH, as a person pasting it would. */
  const bash = (line: string) => run(["bash", "-c", line], dir, { ...shipEnv, PATH: `${join(ROOT, "bin")}:${env.PATH}` });
  /** Re-script the fake mid-scenario: `replies` replace those ports' replies; call counts carry on. */
  const rescript = (replies: Record<string, unknown>) => {
    const current = JSON.parse(readFileSync(script, "utf8")) as { replies: Record<string, unknown> };
    writeFileSync(script, JSON.stringify({ replies: { ...current.replies, ...replies } }));
  };

  const cleanup = () => rmSync(dir, { recursive: true, force: true });
  // The State adapter's own spawn argv, exactly as the machine config's `state` entry: for env scripts
  // (poll/stalled.ts, drive.ts) that take `--state <state-adapter argv…>` directly rather than reading config.
  const stateArgv = ["bun", STATE, "--dir", stateDir];
  return { ship, shipPty, bash, journal, snapshot, log, rescript, cleanup, stateArgv, dir, trackerDir };
};

const RUNNER_KINDS = new Set(["sent", "accepted", "adapter_error"]);
const local = (id: string | null): string => (id === null ? "-" : id.slice(`${D}/`.length));

/** The core's journal entries, one line each: `<signal> <id>: <from>→<to> [note]`. */
export const coreSequence = (entries: TimedEntry[]): string[] =>
  entries.filter((e) => !RUNNER_KINDS.has(e.signal.kind)).map((e) => {
    const s = e.signal;
    const what = s.kind === "result" ? `result ${local(s.id)}` : s.kind === "workItem_changed" ? "changed" : s.kind;
    return `${what}: ${e.from ?? "∅"}→${e.to}${e.note ? ` [${e.note}]` : ""}`;
  });

/** Every id the core issued, and every id the Runner journaled as `sent`, in order. */
export const issuedAndSent = (entries: TimedEntry[]): { issued: string[]; sent: string[] } => ({
  issued: entries.flatMap((e) => e.issued),
  sent: entries.flatMap((e) => (e.signal.kind === "sent" ? [e.signal.id] : [])),
});

/** The fake's calls, one line each: `<port>.<op> <id>`. */
export const calls = (logged: Logged[]): string[] => logged.map((s) => `${s.port}.${s.op} ${local(s.id)}`);

/** The payload the fake received for command `<D>/<suffix>`. */
export const payloadOf = (logged: Logged[], suffix: string): unknown => logged.find((s) => s.id === `${D}/${suffix}`)?.payload;
