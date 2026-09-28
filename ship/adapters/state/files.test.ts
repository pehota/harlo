// M0.14: the file State adapter, driven as an executable (JSON piped into stdin, one JSON line out).
import { afterEach, describe, expect, test } from "bun:test";
import Ajv from "ajv";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Stdin, WorkItem } from "../../src/contracts/common";
import { schemaFor } from "../../src/contracts/ports";
import type { TimedEntry } from "../../src/contracts/snapshot";
import type { Snapshot } from "../../src/core/types";
import { snapshotAt, workItem as baseWorkItem } from "../../src/core/fixtures/builders.fixture";

const ADAPTER = join(import.meta.dir, "files.ts");
const ajv = new Ajv();

const dirs: string[] = [];
const tempDir = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "ship-state-"));
  dirs.push(dir);
  return dir;
};
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const workItemFor = (key: string): WorkItem => ({ ...baseWorkItem, key });
const snap = (delivery: string, key: string, over: Partial<Snapshot> = {}): Snapshot =>
  snapshotAt("implement", null, { delivery, workItem: workItemFor(key), ...over });
const entry = (delivery: string, info: string): TimedEntry => ({
  delivery, signal: { kind: "start", workItem: workItemFor("PROJ-1") }, from: null, to: "setup", issued: [],
  info, time: "2026-09-28T12:00:00.000Z",
});

type Call = { op: string; payload: unknown };
type Out = { exitCode: number; stdout: unknown };

/** Run `state/files.ts --dir <dir> state <op>` with a Stdin envelope, as the Runner does. */
const call = async (dirArg: string, { op, payload }: Call, env: Record<string, string> = {}): Promise<Out> => {
  const stdin: Stdin = {
    id: "PROJ-1-1/state-1", delivery: "PROJ-1-1", port: "state", op,
    workItem: workItemFor("PROJ-1"), workspace: null, payload, tools: [],
  };
  const proc = Bun.spawn(["bun", ADAPTER, "--dir", dirArg, "state", op], {
    stdin: new Blob([JSON.stringify(stdin)]),
    stdout: "pipe",
    stderr: "pipe",
    env: { PATH: process.env.PATH ?? "", HOME: process.env.HOME ?? "", ...env },
  });
  const [text, exitCode] = await Promise.all([new Response(proc.stdout).text(), proc.exited]);
  const stdout: unknown = JSON.parse(text);
  const contract = schemaFor("state", op);
  if (contract && !ajv.validate(contract.stdout, stdout)) throw new Error(`stdout breaks the contract: ${text}`);
  return { exitCode, stdout };
};

const save = (delivery: string, version: number, state: Snapshot, entries: TimedEntry[] = []): Call =>
  ({ op: "save", payload: { delivery, version, state, entries } });
const load = (delivery: string): Call => ({ op: "load", payload: { delivery } });
const list = (key?: string): Call => ({ op: "list", payload: key === undefined ? {} : { key } });
const journal = (delivery: string): Call => ({ op: "journal", payload: { delivery } });
const ok = (body: unknown) => ({ exitCode: 0, stdout: { status: "ok", body } });
const saved = ok({ saved: true });

const s1 = snap("PROJ-1-1", "PROJ-1");
const s2 = snap("PROJ-1-1", "PROJ-1", { at: "check" });
const s10 = snap("PROJ-1-1", "PROJ-1", { at: "land" });
const [a, b, c, d] = ["a", "b", "c", "d"].map((info) => entry("PROJ-1-1", info)) as [TimedEntry, TimedEntry, TimedEntry, TimedEntry];

type Row = {
  name: string;
  seed?: (dir: string) => void; // files written before the calls
  steps: { call: Call; expect: Out }[];
  after?: (dir: string) => void; // checks on the files after the calls
};

const corrupt = (version: number, text: string) => (dir: string) => {
  mkdirSync(join(dir, "PROJ-1-1"), { recursive: true });
  writeFileSync(join(dir, "PROJ-1-1", `${version}.json`), text);
};
const seedV1 = (dir: string) => {
  mkdirSync(join(dir, "PROJ-1-1"), { recursive: true });
  writeFileSync(join(dir, "PROJ-1-1", "1.json"), JSON.stringify({ state: s1, entries: [] }));
};

const rows: Row[] = [
  {
    name: "save v1, then load returns it",
    steps: [
      { call: save("PROJ-1-1", 1, s1, [a]), expect: saved },
      { call: load("PROJ-1-1"), expect: ok({ version: 1, state: s1 }) },
    ],
  },
  {
    name: "load of an unknown Delivery is version 0, state null",
    steps: [{ call: load("PROJ-9-1"), expect: ok({ version: 0, state: null }) }],
  },
  {
    name: "saving an existing version is a conflict (EEXIST), and the first save stays",
    steps: [
      { call: save("PROJ-1-1", 1, s1), expect: saved },
      { call: save("PROJ-1-1", 1, s2), expect: ok({ conflict: true }) },
      { call: load("PROJ-1-1"), expect: ok({ version: 1, state: s1 }) },
    ],
  },
  {
    name: "load returns the highest version (numeric, 10 > 2)",
    steps: [
      { call: save("PROJ-1-1", 1, s1), expect: saved },
      { call: save("PROJ-1-1", 2, s2), expect: saved },
      { call: save("PROJ-1-1", 10, s10), expect: saved },
      { call: load("PROJ-1-1"), expect: ok({ version: 10, state: s10 }) },
    ],
  },
  {
    name: "list by key matches workItem.key exactly (PROJ-1 excludes PROJ-12)",
    steps: [
      { call: save("PROJ-1-1", 1, snap("PROJ-1-1", "PROJ-1")), expect: saved },
      { call: save("PROJ-1-2", 1, snap("PROJ-1-2", "PROJ-1")), expect: saved },
      { call: save("PROJ-12-1", 1, snap("PROJ-12-1", "PROJ-12")), expect: saved },
      { call: list("PROJ-1"), expect: ok({ deliveries: ["PROJ-1-1", "PROJ-1-2"] }) },
      { call: list("PROJ-12"), expect: ok({ deliveries: ["PROJ-12-1"] }) },
    ],
  },
  {
    name: "list with no key returns every Delivery",
    steps: [
      { call: list(), expect: ok({ deliveries: [] }) },
      { call: save("PROJ-1-1", 1, snap("PROJ-1-1", "PROJ-1")), expect: saved },
      { call: save("PROJ-12-1", 1, snap("PROJ-12-1", "PROJ-12")), expect: saved },
      { call: list(), expect: ok({ deliveries: ["PROJ-1-1", "PROJ-12-1"] }) },
    ],
  },
  {
    name: "journal concatenates entries in version order",
    steps: [
      { call: save("PROJ-1-1", 1, s1, [a]), expect: saved },
      { call: save("PROJ-1-1", 2, s2, [b, c]), expect: saved },
      { call: save("PROJ-1-1", 10, s10, [d]), expect: saved },
      { call: journal("PROJ-1-1"), expect: ok({ entries: [a, b, c, d] }) },
      { call: journal("PROJ-9-1"), expect: ok({ entries: [] }) },
    ],
  },
  {
    name: "a file that is not JSON fails load",
    seed: corrupt(1, "{not json"),
    steps: [{ call: load("PROJ-1-1"), expect: { exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) } }],
  },
  {
    name: "a corrupt highest version fails load; no fall back to v1, nothing repaired",
    seed: (dir) => { seedV1(dir); corrupt(2, JSON.stringify({ state: { v: 1 }, entries: [] }))(dir); },
    steps: [
      { call: load("PROJ-1-1"), expect: { exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) } },
      { call: list("PROJ-1"), expect: { exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) } },
    ],
    after: (dir) => expect(readFileSync(join(dir, "PROJ-1-1", "2.json"), "utf8")).toBe('{"state":{"v":1},"entries":[]}'),
  },
  {
    name: "a Delivery id that is not a safe name fails and writes nothing",
    steps: [{ call: save("../evil-1", 1, s1), expect: { exitCode: 0, stdout: expect.objectContaining({ status: "failed" }) } }],
  },
  {
    name: "cancel has nothing to cancel: ok {}",
    steps: [{ call: { op: "cancel", payload: { target: "PROJ-1-1/land-1" } }, expect: ok({}) }],
  },
];

describe("state/files adapter", () => {
  test.each(rows)("$name", async (row) => {
    const dir = tempDir();
    row.seed?.(dir);
    for (const step of row.steps) expect(await call(dir, step.call)).toEqual(step.expect);
    row.after?.(dir);
  });

  test("~ in --dir expands to HOME", async () => {
    const home = tempDir();
    expect(await call("~/state", save("PROJ-1-1", 1, s1), { HOME: home })).toEqual(saved);
    expect(existsSync(join(home, "state", "PROJ-1-1", "1.json"))).toBe(true);
    expect(await call("~/state", load("PROJ-1-1"), { HOME: home })).toEqual(ok({ version: 1, state: s1 }));
  });
});
