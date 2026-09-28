// M0.17: the State port client, driven against the real file State adapter.
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TimedEntry } from "../contracts/snapshot";
import { D, snapshotAt } from "../core/fixtures/builders.fixture";
import { RunnerCallError } from "./spawn";
import { stateClient } from "./state";

const ADAPTER = join(import.meta.dir, "..", "..", "adapters", "state-files.ts");

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-state-client-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const client = (dir: string) => stateClient({ argv: ["bun", ADAPTER, "--dir", dir], env: {}, tools: [] });
const snap = snapshotAt("implement", null);
const entry: TimedEntry = {
  delivery: D, signal: { kind: "accepted", id: `${D}/define-1` }, from: "implement", to: "implement", issued: [],
  time: "2026-09-28T12:00:00.000Z",
};

describe("State client", () => {
  test("save v1, load it, list with and without a key, journal", async () => {
    const state = client(tempDir());
    expect(await state.load(D)).toEqual({ version: 0, state: null });
    expect(await state.save(D, 1, snap, [entry])).toBe(true);
    expect(await state.load(D)).toEqual({ version: 1, state: snap });
    expect(await state.list()).toEqual([D]);
    expect(await state.list("k")).toEqual([D]);
    expect(await state.list("other")).toEqual([]);
    expect(await state.journal(D)).toEqual([entry]);
  });

  test("a save of an existing version is a conflict", async () => {
    const state = client(tempDir());
    await state.save(D, 1, snap, []);
    expect(await state.save(D, 1, snap, [])).toBe(false);
  });

  test("a corrupt snapshot fails the load; it is not repaired", async () => {
    const dir = tempDir();
    mkdirSync(join(dir, D));
    writeFileSync(join(dir, D, "1.json"), JSON.stringify({ state: { ...snap, at: "nowhere" }, entries: [] }));
    await expect(client(dir).load(D)).rejects.toBeInstanceOf(RunnerCallError);
  });

  test("an adapter that cannot be spawned fails the call", async () => {
    const state = stateClient({ argv: ["ship-no-such-state-adapter"], env: {}, tools: [] });
    await expect(state.list()).rejects.toBeInstanceOf(RunnerCallError);
  });
});
