// Core invariants I1–I6 (plan §3.3) over every row fixture, plus the core tool-name scan (M0.13).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import type { PrincipalKind } from "../contracts/common";
import { parseCommandId } from "./ids";
import { applyStart, applyTransition, startRows, transitionRows } from "./fixtures/rows.fixture";
import type { Command, Entry, Note, Signal, Snapshot } from "./types";

/** One applied row: what went in, what came out. `before` is null for a created start. */
type Applied = { label: string; before: Snapshot | null; signal: Signal | null; state: Snapshot; commands: Command[]; entry: Entry };

const startCases: Applied[] = startRows.flatMap((row) => {
  const out = applyStart(row);
  if (out.kind === "rejected") return []; // no state out, nothing issued
  return [{ label: `${row.id} ${row.name}`, before: null, signal: null, state: out.state, commands: out.commands, entry: out.entry }];
});
const transitionCases: Applied[] = transitionRows.map((row) => ({
  label: `${row.id} ${row.name}`, before: row.state, signal: row.signal, ...applyTransition(row),
}));
const cases = [...startCases, ...transitionCases];

const toCommand = ({ id, port, op, await: awaited, payload }: Command): Command => ({ id, port, op, await: awaited, payload });
const IGNORED: ReadonlySet<Note> = new Set(["ignored_stale", "ignored_terminal", "workitem_unchanged"]);

describe("core invariants over every row (§3.3)", () => {
  test.each(cases)("I1 at most one awaited command, and state.awaiting is it: $label", (c) => {
    const awaited = c.commands.filter((cmd) => cmd.await);
    expect(awaited.length).toBeLessThanOrEqual(1);
    const [issued] = awaited;
    if (issued) expect(c.state.awaiting && toCommand(c.state.awaiting)).toEqual(issued);
    else expect([null, c.before?.awaiting ?? null]).toContainEqual(c.state.awaiting); // cleared, or still the earlier wait
  });

  test.each(cases)("I2 ids are <delivery>/<name>-<n>, unique, and seq only grows: $label", (c) => {
    const ids = c.commands.map((cmd) => cmd.id);
    const prior = c.before?.seq ?? {};
    expect(new Set(ids).size).toBe(ids.length);
    expect(c.entry.issued).toEqual(ids);
    for (const commandId of ids) {
      const parsed = parseCommandId(commandId);
      expect(parsed).not.toBeNull();
      expect(parsed!.delivery).toBe(c.state.delivery);
      expect(parsed!.n).toBeGreaterThan(prior[parsed!.name] ?? 0);
      expect(parsed!.n).toBeLessThanOrEqual(c.state.seq[parsed!.name] ?? 0);
    }
    for (const [name, n] of Object.entries(prior)) expect(c.state.seq[name] ?? 0).toBeGreaterThanOrEqual(n);
  });

  test.each(cases)("I3 cancel only for the previous awaiting id, before everything else: $label", (c) => {
    const cancels = c.commands.filter((cmd) => cmd.op === "cancel");
    expect(cancels.length).toBeLessThanOrEqual(1);
    expect(c.commands.slice(0, cancels.length)).toEqual(cancels);
    for (const cancel of cancels) {
      expect(c.before?.awaiting).toBeTruthy();
      expect(cancel).toMatchObject({ port: c.before!.awaiting!.port, await: false, payload: { target: c.before!.awaiting!.id } });
    }
  });

  test.each(cases)("I4 Closed and Abandoned await nothing; Abandoned never tears down: $label", (c) => {
    if (c.state.at === "closed" || c.state.at === "abandoned") expect(c.commands.filter((cmd) => cmd.await)).toEqual([]);
    if (c.state.at === "abandoned") {
      expect(c.commands.filter((cmd) => cmd.port === "workspace" && cmd.op === "teardown")).toEqual([]);
    }
  });

  test.each(cases)("I5 ignored signals return the input state deep-equal: $label", (c) => {
    if (c.entry.note === undefined || !IGNORED.has(c.entry.note)) return;
    expect(c.state).toEqual(c.before!);
    expect(c.commands).toEqual([]);
  });

  test.each(cases)("I6 entries applying a principal.decide or principal.ask Result carry by: $label", (c) => {
    const sig = c.signal;
    const awaiting = c.before?.awaiting;
    const principalAnswer = sig?.kind === "result" && sig.result.status === "ok" && awaiting?.id === sig.id
      && awaiting.port === "principal" && (awaiting.op === "decide" || awaiting.op === "ask");
    if (!principalAnswer) return;
    expect(c.entry.by).toBe((sig.result as { body: { by: PrincipalKind } }).body.by);
  });

  test("the sweep covers every table", () => {
    const tables = new Set(transitionRows.map((row) => row.id.replace(/[0-9a-z]+$/, "")));
    expect([...tables].sort()).toEqual(["B", "D", "F", "H", "Q", "R", "W", "X"]);
    expect(startCases.length).toBeGreaterThan(0);
  });
});

// ---- tool-name scan: the core knows what work happens, never who does it (P5) ----

const TOOL_NAMES = /\b(claude|dod|jira|telegram|github|gh|git)\b/;
const stripComments = (source: string): string => source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
const offends = (source: string): boolean => TOOL_NAMES.test(stripComments(source));

describe("tool-name scan helper", () => {
  test.each([
    { source: `const x = 1; // runs git later`, fails: false },
    { source: `/* jira\n claude */ const x = 1;`, fails: false },
    { source: `const tool = "git";`, fails: true },
    { source: `const digit = "gitlab-free";`, fails: false },
  ])("$source → fails: $fails", ({ source, fails }) => {
    expect(offends(source)).toBe(fails);
  });
});

describe("src/core names no tool (P5)", () => {
  const coreDir = dirname(import.meta.path);
  const self = basename(import.meta.path); // holds the pattern itself
  const files = [...new Bun.Glob("**/*.ts").scanSync({ cwd: coreDir })].filter((file) => file !== self);

  test("scans the core's files", () => {
    expect(files).toContain("transition.ts");
  });

  test.each(files)("%s", (file) => {
    const source = readFileSync(join(coreDir, file), "utf8");
    expect(stripComments(source).match(TOOL_NAMES)?.[0] ?? null).toBeNull();
  });
});
