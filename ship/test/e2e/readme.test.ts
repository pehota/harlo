// M0.23: the README's happy path is a runnable claim. Extract the block fenced ```bash readme-happy-path, run it
// with bash from the bundle root (as the README says), then read the Delivery back with `ship status` ourselves.
import { afterAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const ROOT = join(import.meta.dir, "..", "..");
const FENCE = /^```bash readme-happy-path\n([\s\S]*?)^```$/m;

const happyPathBlock = (): string => {
  const readme = readFileSync(join(ROOT, "README.md"), "utf8");
  const block = FENCE.exec(readme)?.[1];
  if (block === undefined) throw new Error("README.md has no ```bash readme-happy-path block");
  return block;
};

// The block makes its demo project under $TMPDIR; a TMPDIR of its own lets the test find and remove it.
const tmp = mkdtempSync(join(tmpdir(), "ship-readme-"));
const home = join(tmp, "home"); // bun writes caches under HOME, so keep it apart from TMPDIR
const demos = join(tmp, "demos");
for (const dir of [home, demos]) mkdirSync(dir);
afterAll(() => rmSync(tmp, { recursive: true, force: true }));

test("the README happy path reaches Closed", async () => {
  const env = { PATH: process.env.PATH ?? "", HOME: home, TMPDIR: demos };
  const script = `set -euo pipefail\n${happyPathBlock()}`;
  const proc = Bun.spawn(["bash", "-c", script], { cwd: ROOT, env, stdout: "pipe", stderr: "pipe" });
  const [stdout, stderr, exit] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited]);
  expect({ exit, stderr }).toEqual({ exit: 0, stderr: "" });

  const [demo, ...more] = readdirSync(demos);
  expect(more).toEqual([]);
  const projectDir = join(demos, demo!);
  const status = Bun.spawnSync(["bun", join(ROOT, "bin", "ship"), "status", "hello-1"], {
    cwd: projectDir, env: { ...env, SHIP_MACHINE_CONFIG: join(projectDir, "machine.json") },
  });
  expect({ exit: status.exitCode, stderr: status.stderr.toString() }).toEqual({ exit: 0, stderr: "" });
  expect(JSON.parse(status.stdout.toString())).toEqual({ deliveries: [{ delivery: "hello-1", at: "closed", awaiting: null }] });
  expect(stdout).toContain('"at":"closed"');
}, 60_000);
