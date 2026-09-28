// M0.22: property tests. The REAL core and apply loop run against a simulated environment (simulation.fixture.ts):
// Runner crashes at any load/save/spawn/wait point, signals delivered out of order, twice or never (then a
// `stop`), `workItem_changed` and `stop` at any time, orphaned adapters and reused pids. Invariants are checked
// over the journal and every saved snapshot; "no silent stall" uses the poller model in stall.fixture.ts.
import { describe, expect, test } from "bun:test";
import fc from "fast-check";
import { awaited, policy, snapshotAt } from "../../src/core/fixtures/builders.fixture";
import type { TimedEntry } from "../../src/contracts/snapshot";
import type { Entry, Snapshot } from "../../src/core/types";
import { type Action, type Coverage, GRACE, MAX_RUNTIME, runScenario } from "./simulation.fixture";
import { type Flag, type Poll, stallFlag } from "./stall.fixture";

const crash = fc.oneof(
  { weight: 6, arbitrary: fc.constant(null) },
  { weight: 1, arbitrary: fc.integer({ min: 1, max: 12 }) },
);
const action: fc.Arbitrary<Action> = fc.oneof(
  { weight: 2, arbitrary: fc.record({ kind: fc.constant("start" as const), crash }) },
  { weight: 20, arbitrary: fc.record({ kind: fc.constant("deliver" as const), pick: fc.nat(), crash }) },
  { weight: 2, arbitrary: fc.record({ kind: fc.constant("duplicate" as const), pick: fc.nat(), crash }) },
  { weight: 1, arbitrary: fc.record({ kind: fc.constant("drop" as const), pick: fc.nat() }) },
  { weight: 1, arbitrary: fc.record({ kind: fc.constant("changed" as const), body: fc.nat(), crash }) },
  { weight: 1, arbitrary: fc.record({ kind: fc.constant("stop" as const), crash }) },
  { weight: 3, arbitrary: fc.record({ kind: fc.constant("wait" as const), ms: fc.integer({ min: 0, max: 2 * MAX_RUNTIME }) }) },
  { weight: 3, arbitrary: fc.record({ kind: fc.constant("reusePid" as const), pick: fc.nat() }) },
);
const actions = fc.array(action, { minLength: 10, maxLength: 80, size: "max" });
const choices = fc.array(fc.nat(99), { minLength: 32, maxLength: 32 }); // the fake adapters' scripted choices

const START: Action = { kind: "start", crash: null };

describe("lifecycle under a simulated environment", () => {
  test("every invariant holds over the journal and the final snapshots", async () => {
    await fc.assert(
      fc.asyncProperty(actions, choices, async (acts, picks) => {
        const sim = await runScenario(policy, [START, ...acts], picks);
        expect(sim.violations).toEqual([]);
      }),
    );
  }, 60_000);
});

// ── The stall cases, scripted through the same simulation ──
// Choices per awaited step command: [result (5 = ok), mode (9 = synchronous), run (2 = 3×grace, 3 = 2×maxRuntime)].
// Crash point 8 of a start: save, saved, spawn, spawned, load, save, saved (`sent`), then waiting on setup-1.
const WAITING_ON_SETUP = 8;
type StallCase = { name: string; actions: Action[]; choices: number[]; covers: (keyof Coverage)[] };
const stallCases: StallCase[] = [
  {
    name: "a synchronous adapter running past grace, within maxRuntime, is not flagged",
    actions: [START],
    choices: [5, 9, 2],
    covers: ["syncPastGrace"],
  },
  {
    name: "an orphan: young (no flag), older than maxRuntime (hung?), gone with its Result lost (dead), pid reused (dead)",
    actions: [
      { kind: "start", crash: WAITING_ON_SETUP },
      { kind: "wait", ms: MAX_RUNTIME + 1 },
      { kind: "wait", ms: MAX_RUNTIME },
      { kind: "reusePid", pick: 0 },
    ],
    choices: [5, 9, 3],
    covers: ["crashes", "orphanYoung", "orphanHung", "orphanGone", "pidReused"],
  },
];

describe("stall cases in the simulation", () => {
  test.each(stallCases)("$name", async ({ actions: acts, choices: picks, covers }) => {
    const sim = await runScenario(policy, acts, picks);
    expect(sim.violations).toEqual([]); // includes: the stall model agrees with the process table at every check
    expect(covers.filter((c) => sim.coverage[c] === 0)).toEqual([]);
  });
});

// ── The stall model on its own, one row per poller case (plan M1.4) ──
const T0 = Date.parse("2026-09-28T12:00:00.000Z");
const HOST = "sim-host";
const run1 = awaited("implement-1", "implement", "run", {}, "implement", "run");
const at = (ms: number) => new Date(T0 + ms).toISOString();
const entry = (signal: Entry["signal"], ms = 0): TimedEntry => ({ delivery: "k-1", signal, from: "implement", to: "implement", issued: [], time: at(ms) });
const sent = (host = HOST): TimedEntry => entry({ kind: "sent", id: run1.id, pid: 101, host, started: `${T0}#1` });
const issued = entry({ kind: "start", workItem: snapshotAt("implement", run1).workItem });

type Row = { name: string; state: Snapshot; entries: TimedEntry[]; now: number; ps: string | null; expected: Flag | null };
const rows: Row[] = [
  { name: "sent, alive, younger than maxRuntime", state: snapshotAt("implement", run1), entries: [issued, sent()], now: MAX_RUNTIME, ps: `${T0}#1`, expected: null },
  { name: "sync adapter past grace, within maxRuntime", state: snapshotAt("implement", run1), entries: [issued, sent()], now: GRACE * 3, ps: `${T0}#1`, expected: null },
  { name: "sent, alive, older than maxRuntime", state: snapshotAt("implement", run1), entries: [issued, sent()], now: MAX_RUNTIME + 1, ps: `${T0}#1`, expected: "hung?" },
  { name: "not sent, past grace", state: snapshotAt("implement", run1), entries: [issued], now: GRACE + 1, ps: null, expected: "never sent" },
  { name: "not sent, within grace", state: snapshotAt("implement", run1), entries: [issued], now: GRACE, ps: null, expected: null },
  { name: "awaiting null", state: snapshotAt("blocked", null), entries: [issued], now: GRACE * 10, ps: null, expected: null },
  { name: "accepted, pid gone", state: snapshotAt("implement", run1), entries: [issued, sent(), entry({ kind: "accepted", id: run1.id })], now: GRACE * 10, ps: null, expected: null },
  { name: "sent from another host", state: snapshotAt("implement", run1), entries: [issued, sent("other-host")], now: 1, ps: `${T0}#1`, expected: "unknown host" },
  { name: "orphan exited, Result lost", state: snapshotAt("implement", run1), entries: [issued, sent()], now: GRACE, ps: null, expected: "dead" },
  { name: "pid reused with another start time", state: snapshotAt("implement", run1), entries: [issued, sent()], now: GRACE, ps: `${T0 + 5}#9`, expected: "dead" },
];

describe("stall model", () => {
  test.each(rows)("$name", ({ state, entries, now, ps, expected }) => {
    const poll: Poll = { now: T0 + now, host: HOST, grace: GRACE, maxRuntime: () => MAX_RUNTIME, startOf: (pid) => (pid === 101 ? ps : null) };
    expect(stallFlag(state, entries, poll)).toBe(expected);
  });
});
