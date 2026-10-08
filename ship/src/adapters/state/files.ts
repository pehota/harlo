#!/usr/bin/env bun
// File State adapter (plan §3.4). Layout: <dir>/<delivery>/<version>.json = {state, entries}.
// argv: --dir <dir> state <op>; stdin: Stdin (§3.1); stdout: one Result JSON line.
// Save is CAS: write a tmp file, then link() it to <version>.json; EEXIST means another save won.
// A load never repairs: a corrupt highest version fails, it does not fall back to an older one.
import type { JSONSchemaType } from "ajv";
import { existsSync, linkSync, mkdirSync, readFileSync, readdirSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { DeliveryId } from "../../../src/contracts/common";
import type {
  StateJournalBody, StateJournalPayload, StateListBody, StateListPayload, StateLoadBody, StateLoadPayload,
  StateSaveBody, StateSavePayload,
} from "../../../src/contracts/ports";
import { schemaFor } from "../../../src/contracts/ports";
import { snapshotSchema, timedEntrySchema, type TimedEntry } from "../../../src/contracts/snapshot";
import { check } from "../../../src/contracts/validate";
import { KEY_RE } from "../../../src/core/ids";
import type { Snapshot } from "../../../src/core/types";

type Stored = { state: Snapshot; entries: TimedEntry[] };
const storedSchema: JSONSchemaType<Stored> = {
  type: "object",
  properties: { state: snapshotSchema, entries: { type: "array", items: timedEntrySchema } },
  required: ["state", "entries"],
  additionalProperties: false,
};

const VERSION_FILE = /^([1-9][0-9]*)\.json$/;

const expandHome = (dir: string): string =>
  dir === "~" ? homedir() : dir.startsWith("~/") ? join(homedir(), dir.slice(2)) : dir;

// A Delivery id names a directory, so it must be one safe path segment (no `/`, no leading `.`).
const deliveryDir = (root: string, delivery: DeliveryId): string => {
  if (!KEY_RE.test(delivery)) throw new Error(`not a Delivery id: ${JSON.stringify(delivery)}`);
  return join(root, delivery);
};

/** The saved versions of a Delivery, ascending (numeric, so 10 sorts after 2). */
const versionsOf = (dir: string): number[] => {
  if (!existsSync(dir)) return [];
  const versions = readdirSync(dir).flatMap((name) => {
    const match = VERSION_FILE.exec(name);
    return match ? [Number(match[1])] : [];
  });
  return versions.sort((x, y) => x - y);
};

/** A state persisted before harlo-58 (8b20b36) has top-level `criteria`/`runbook` and no `requirements`: read it
 *  as the requirements the shipped agent adapter's Define emits, null before Define. Translated on read; the file
 *  stays as it is. */
const upgradeLegacy = (stored: unknown): unknown => {
  const state = (stored as { state?: unknown })?.state;
  if (typeof state !== "object" || state === null || "requirements" in state) return stored;
  if (!("criteria" in state) && !("runbook" in state)) return stored;
  const { criteria = null, runbook = null, ...rest } = state as Record<string, unknown>;
  const requirements = criteria === null && runbook === null ? null : { criteria, runbook };
  return { ...(stored as object), state: { ...rest, requirements } };
};

const readVersion = (dir: string, version: number): Stored => {
  const path = join(dir, `${version}.json`);
  const parsed = upgradeLegacy(JSON.parse(readFileSync(path, "utf8")));
  const error = check(storedSchema, parsed);
  if (error) throw new Error(`corrupt ${path}: ${error}`);
  return parsed as Stored;
};

const load = (root: string, { delivery }: StateLoadPayload): StateLoadBody => {
  const dir = deliveryDir(root, delivery);
  const top = versionsOf(dir).at(-1);
  if (top === undefined) return { version: 0, state: null };
  return { version: top, state: readVersion(dir, top).state };
};

const save = (root: string, { delivery, version, state, entries }: StateSavePayload): StateSaveBody => {
  const dir = deliveryDir(root, delivery);
  mkdirSync(dir, { recursive: true });
  const tmp = join(dir, `.tmp-${process.pid}-${crypto.randomUUID()}`);
  writeFileSync(tmp, JSON.stringify({ state, entries } satisfies Stored));
  try {
    linkSync(tmp, join(dir, `${version}.json`));
    return { saved: true };
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") return { conflict: true };
    throw error;
  } finally {
    // Best effort: once linked, the save happened and must not turn into `failed`; a stray tmp file is ignored.
    try { unlinkSync(tmp); } catch {}
  }
};

const list = (root: string, { key }: StateListPayload): StateListBody => {
  const all = existsSync(root) ? readdirSync(root).filter((name) => KEY_RE.test(name)) : [];
  const saved = all.filter((delivery) => versionsOf(join(root, delivery)).length > 0);
  // By exact WorkItem key, read from the snapshot: `PROJ-1` must not match `PROJ-12-1` (plan S6).
  const matching = key === undefined
    ? saved
    : saved.filter((delivery) => load(root, { delivery }).state?.workItem.key === key);
  return { deliveries: matching.sort() };
};

const journal = (root: string, { delivery }: StateJournalPayload): StateJournalBody => {
  const dir = deliveryDir(root, delivery);
  return { entries: versionsOf(dir).flatMap((version) => readVersion(dir, version).entries) };
};

const ops: Record<string, (root: string, payload: never) => unknown> = {
  load, save, list, journal,
  cancel: () => ({}), // nothing runs in the background, so there is never anything to cancel
};

/** argv after the script: `--dir <dir> <port> <op>`. */
const parseArgs = (args: string[]): { dir: string | undefined; port: string | undefined; op: string | undefined } => {
  const at = args.indexOf("--dir");
  const dir = at === -1 ? undefined : args[at + 1];
  const positional = at === -1 ? args : [...args.slice(0, at), ...args.slice(at + 2)];
  const [port, op] = positional;
  return { dir, port, op };
};

/** Every error is caught: each op either changes nothing on failure (load/list/journal) or cleans its tmp file. */
const run = async (): Promise<unknown> => {
  const { dir, port, op } = parseArgs(process.argv.slice(2));
  if (!dir) throw new Error("usage: state/files.ts --dir <dir> state <op>");
  const contract = port === "state" && op ? schemaFor("state", op) : undefined;
  const handler = op && Object.hasOwn(ops, op) ? ops[op] : undefined;
  if (!contract || !handler) throw new Error(`unsupported: ${port} ${op}`);
  const stdin = JSON.parse(await Bun.stdin.text()) as { payload?: unknown };
  const invalid = check(contract.payload, stdin.payload);
  if (invalid) throw new Error(`invalid payload: ${invalid}`);
  return handler(expandHome(dir), stdin.payload as never);
};

try {
  console.log(JSON.stringify({ status: "ok", body: await run() }));
} catch (error) {
  console.log(JSON.stringify({ status: "failed", info: error instanceof Error ? error.message : String(error) }));
}
