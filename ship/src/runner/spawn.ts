// Run one adapter (plan §5.3): argv `<config argv…> <port> <op>`, stdin = Stdin, env = PATH, HOME and the
// port's capability-profile env only. Returns as soon as the process exists, so the caller can journal
// `sent{id, pid, host, started}` before awaiting `done` (§5.2).
import { readFileSync } from "node:fs";
import type { Port, Result, RunnerStdin, Stdin } from "../contracts/common";
import { schemaFor } from "../contracts/ports";
import { check } from "../contracts/validate";
import type { Command, Snapshot } from "../core/types";

/** How one port is served: the config argv prefix and its capability profile (secrets already resolved). */
export type AdapterSpec = { argv: string[]; env: Record<string, string>; tools: string[] };

/** What the adapter's run amounts to for the Runner. */
export type Reply =
  | { kind: "result"; result: Result } // awaited: a valid Result, fed back as a signal
  | { kind: "accepted" } // awaited: the reply comes later through `ship signal`
  | { kind: "crash"; reason: string; stderr: string } // awaited: exit ≠ 0 or invalid stdout → adapter_error, exit 5
  | { kind: "fired" } // fire, exit 0; stdout ignored
  | { kind: "fire_error"; info: string }; // fire that failed → the CLI's `errors`

export type Spawned =
  | { spawned: true; pid: number; started: string; done: Promise<Reply> }
  | { spawned: false; reply: Reply }; // spawn error: provably ran nothing, so no `sent` entry

const STDERR_TAIL = 2048;

/**
 * The start time of a live process (the pid-reuse guard in `sent`), or "" when the pid is gone.
 * macOS: `ps -o lstart=`; Linux: field 22 (`starttime`) of /proc/<pid>/stat [unverified on Linux].
 */
export const processStartTime = (pid: number): string => {
  if (process.platform === "linux") {
    try {
      const stat = readFileSync(`/proc/${pid}/stat`, "utf8");
      const afterComm = stat.slice(stat.lastIndexOf(")") + 2).split(" "); // comm may hold spaces; fields from 3 on
      return afterComm[22 - 3] ?? "";
    } catch {
      return "";
    }
  }
  return Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)]).stdout.toString().trim();
};

/** The last STDERR_TAIL bytes of a stream, read while the process runs so its pipe never fills. */
const tail = async (stream: ReadableStream<Uint8Array>): Promise<string> => {
  let kept = new Uint8Array(0);
  for await (const chunk of stream) {
    const joined = new Uint8Array(kept.length + chunk.length);
    joined.set(kept);
    joined.set(chunk, kept.length);
    kept = joined.slice(-STDERR_TAIL);
  }
  return new TextDecoder().decode(kept);
};

/** Only PATH and HOME are inherited; nothing else from the Runner's env reaches the adapter. */
const adapterEnv = (profileEnv: Record<string, string>): Record<string, string> => {
  const { PATH, HOME } = process.env;
  return { ...(PATH === undefined ? {} : { PATH }), ...(HOME === undefined ? {} : { HOME }), ...profileEnv };
};

const parseJson = (text: string): { ok: true; value: unknown } | { ok: false } => {
  try {
    return { ok: true, value: JSON.parse(text) };
  } catch {
    return { ok: false };
  }
};

/** Awaited: map exit code and stdout per the §5.3 table. */
const awaitedReply = (stdoutSchema: object, exitCode: number, stdout: string, stderr: string): Reply => {
  if (exitCode !== 0) return { kind: "crash", reason: `exit ${exitCode}`, stderr };
  const parsed = parseJson(stdout.trim());
  if (!parsed.ok) return { kind: "crash", reason: "stdout is not JSON", stderr };
  const invalid = check(stdoutSchema, parsed.value);
  if (invalid) return { kind: "crash", reason: `stdout fails the schema: ${invalid}`, stderr };
  const reply = parsed.value as Result | { status: "accepted" };
  return reply.status === "accepted" ? { kind: "accepted" } : { kind: "result", result: reply };
};

/** Fire: stdout is ignored; only a non-zero exit matters. */
const fireReply = (exitCode: number, stderr: string): Reply =>
  exitCode === 0 ? { kind: "fired" } : { kind: "fire_error", info: `exit ${exitCode}: ${stderr}` };

/**
 * Spawn `spec` for `stdin.port`/`stdin.op`. Only a Runner-only call may leave id, Delivery and WorkItem null.
 * Throws on a Stdin the contracts reject: that is a Runner bug.
 */
export const spawnAdapter = (spec: AdapterSpec, stdin: RunnerStdin, awaited: boolean): Spawned => {
  const contract = schemaFor(stdin.port, stdin.op);
  if (!contract) throw new Error(`runner bug: no contract for ${stdin.port}.${stdin.op}`);
  const invalid = check(contract.stdin, stdin) ?? check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`runner bug: invalid stdin for ${stdin.port}.${stdin.op}: ${invalid}`);

  let proc: Bun.Subprocess<Blob, "pipe", "pipe">;
  try {
    proc = Bun.spawn([...spec.argv, stdin.port, stdin.op], {
      stdin: new Blob([JSON.stringify(stdin)]),
      stdout: "pipe",
      stderr: "pipe",
      env: adapterEnv(spec.env),
    });
  } catch (error) {
    const info = `spawn failed: ${error instanceof Error ? error.message : String(error)}`;
    const reply: Reply = awaited ? { kind: "result", result: { status: "failed", info } } : { kind: "fire_error", info };
    return { spawned: false, reply };
  }

  const started = processStartTime(proc.pid);
  const done = Promise.all([new Response(proc.stdout).text(), tail(proc.stderr), proc.exited]).then(
    ([stdout, stderr, exitCode]) =>
      awaited ? awaitedReply(contract.stdout, exitCode, stdout, stderr) : fireReply(exitCode, stderr),
  );
  return { spawned: true, pid: proc.pid, started, done };
};

/**
 * Spawn a core Command on its port's adapter. A `cancel` carries the target's port (§3.2), so it reaches the
 * adapter that runs the target.
 */
export const spawnCommand = (
  adapters: Record<Port, AdapterSpec>,
  delivery: Pick<Snapshot, "delivery" | "workItem" | "workspace">,
  command: Command,
): Spawned => {
  const spec = adapters[command.port];
  const stdin: Stdin = {
    id: command.id, delivery: delivery.delivery, port: command.port, op: command.op,
    workItem: delivery.workItem, workspace: delivery.workspace, payload: command.payload, tools: spec.tools,
  };
  return spawnAdapter(spec, stdin, command.await);
};
