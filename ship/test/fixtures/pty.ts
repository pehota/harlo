// Thin TS wrapper around pty-harness.py: spawns a process attached to a REAL pty as its controlling terminal, so
// anything it (or a child it spawns, same session) opens as `/dev/tty` is real, not a pipe or a mock.
import { join } from "node:path";

const HARNESS = join(import.meta.dir, "pty-harness.py");

export type Turn = { wait?: string; send?: string };
export type PtyResult = { ptyOutput: string; stdout: string; exit: number };
export type PtyOpts = { cwd?: string; env?: Record<string, string>; turns?: Turn[] };

/** Spawn `argv` with `input` on its real stdin, feeding `opts.turns` to /dev/tty as prompts appear. */
export const runPty = async (argv: string[], input: string, opts: PtyOpts = {}): Promise<PtyResult> => {
  const manifest = { argv, cwd: opts.cwd, env: opts.env, input, turns: opts.turns ?? [] };
  const proc = Bun.spawn(["python3", HARNESS], { stdin: new Blob([JSON.stringify(manifest)]), stdout: "pipe", stderr: "pipe" });
  const [out, err, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  if (exit !== 0) throw new Error(`pty harness failed (exit ${exit}): ${err}`);
  return JSON.parse(out) as PtyResult;
};
