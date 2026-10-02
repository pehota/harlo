// M0.17: the apply loop (plan §5.2) with the real core, an in-process fake State and a fake spawn.
import { describe, expect, test } from "bun:test";
import type { TimedEntry } from "../contracts/snapshot";
import {
  D, awaited, changed, criteria, id, policy, runbook, snapshotAt, stop, withTracker, workItem,
} from "../core/fixtures/builders.fixture";
import type { Policy } from "../core/types";
import { type Deps, type Pending, apply } from "./apply";
import { FakeSpawn, FakeState, type Script } from "./fixtures/fakes.fixture";

const TIME = "2026-09-28T12:00:00.000Z";
const HOST = "test-host";

const setupOk: Script = { reply: { kind: "result", result: { status: "ok", body: { path: "/ws/k-1", base: "trunk" } } } };
const defineOk: Script = { reply: { kind: "result", result: { status: "ok", body: { criteria, runbook } } } };
const crash: Script = { reply: { kind: "crash", reason: "exit 1", stderr: "…the stderr tail" } };

const startK: Pending = { kind: "start", workItem };

const harness = (scripts: Record<string, Script> = {}, p: Policy = policy) => {
  const state = new FakeState();
  const spawn = new FakeSpawn(state, scripts);
  const deps: Deps = { policy: p, state, spawn: spawn.spawn, host: HOST, now: () => TIME };
  return { state, spawn, deps };
};

/** The Runner-written entries of a Delivery's journal, as `<kind> <id>`. */
const runnerEntries = (entries: TimedEntry[]): string[] =>
  entries.flatMap((e) => {
    const { kind } = e.signal;
    return kind === "sent" || kind === "accepted" || kind === "adapter_error" ? [`${kind} ${e.signal.id}`] : [];
  });

describe("apply loop", () => {
  test("an immediate-result chain runs until `accepted`", async () => {
    const { state, deps } = harness({ [id("setup-1")]: setupOk, [id("define-1")]: defineOk });
    const report = await apply(deps, startK);
    expect(report).toEqual({
      exit: 0,
      output: { delivery: D, issued: [id("setup-1"), id("define-1"), id("accept-1")], awaiting: id("accept-1") },
    });
    expect(state.top(D)?.state.at).toBe("accept");
    expect(state.entries(D).every((e) => e.time === TIME)).toBe(true);
  });

  test("save happens before execute: each spawn sees the saved state that awaits it", async () => {
    const { spawn, deps } = harness({ [id("setup-1")]: setupOk, [id("define-1")]: defineOk });
    await apply(deps, startK);
    expect(spawn.calls.map((c) => [c.command.id, c.saved?.awaiting?.id])).toEqual([
      [id("setup-1"), id("setup-1")],
      [id("define-1"), id("define-1")],
      [id("accept-1"), id("accept-1")],
    ]);
  });

  test("a persistent conflict after an immediate Result gives exit 3 with `unapplied`", async () => {
    const { state, deps } = harness({ [id("setup-1")]: setupOk });
    state.conflict = ({ entries }) => entries.some((e) => e.signal.kind === "result");
    const report = await apply(deps, startK);
    expect(report.exit).toBe(3);
    expect(report.output.unapplied).toEqual([
      { kind: "result", id: id("setup-1"), result: { status: "ok", body: { path: "/ws/k-1", base: "trunk" } } },
    ]);
    expect(state.saves.filter((s) => s.entries.some((e) => e.signal.kind === "result"))).toHaveLength(5);
    expect(state.top(D)?.state.at).toBe("setup");
  });

  test("a journal save that never clears gives exit 3 after 5 tries, with the pending Result in `unapplied`", async () => {
    const { state, spawn, deps } = harness({ [id("setup-1")]: setupOk });
    const isJournal = (e: TimedEntry): boolean => runnerEntries([e]).length > 0;
    state.conflict = ({ entries }) => entries.every(isJournal);
    const report = await apply(deps, startK);
    expect(report).toMatchObject({
      exit: 3,
      output: {
        delivery: D, issued: [id("setup-1")],
        unapplied: [{ kind: "result", id: id("setup-1"), result: { status: "ok", body: { path: "/ws/k-1", base: "trunk" } } }],
      },
    });
    expect(state.saves.filter((s) => s.entries.every(isJournal))).toHaveLength(5);
    expect(spawn.sent()).toEqual([id("setup-1")]);
  });

  test("an awaited adapter crash gives exit 5 and an adapter_error entry with the stderr tail", async () => {
    const { state, deps } = harness({ [id("setup-1")]: crash });
    const report = await apply(deps, startK);
    expect(report.exit).toBe(5);
    const error = state.entries(D).find((e) => e.signal.kind === "adapter_error");
    expect(error).toMatchObject({
      signal: { kind: "adapter_error", id: id("setup-1") }, from: "setup", to: "setup", issued: [], time: TIME,
    });
    expect(error?.info).toContain("…the stderr tail");
    expect(state.top(D)?.state.awaiting?.id).toBe(id("setup-1")); // no signal applied
  });

  test("a failed fire command lands in `errors`", async () => {
    const implement1 = awaited("implement-1", "implement", "run", { criteria, findings: [] }, "implement", "run");
    const { state, deps } = harness({ [id("notify-1")]: { reply: { kind: "fire_error", info: "exit 2: no tty" } } });
    state.seed(snapshotAt("implement", implement1));
    const report = await apply(deps, { kind: "signal", delivery: D, signal: stop("abandoned", "not needed") });
    expect(report.exit).toBe(0);
    expect(report.output.errors).toEqual([{ id: id("notify-1"), info: "exit 2: no tty" }]);
    expect(report.output.issued).toContain(id("notify-1"));
  });

  test("sent{id, pid, host, started} per started process; accepted adds accepted{id}; ENOENT journals no sent", async () => {
    const { state, deps } = harness({ [id("setup-1")]: { enoent: "no such adapter" } });
    const report = await apply(deps, startK);
    expect(report.output.issued).toEqual([id("setup-1"), id("setup-2")]); // failed → re-issued once (retryCap 1)
    expect(runnerEntries(state.entries(D))).toEqual([`sent ${id("setup-2")}`, `accepted ${id("setup-2")}`]);
    const sent = state.entries(D).find((e) => e.signal.kind === "sent");
    expect(sent).toMatchObject({
      signal: { kind: "sent", id: id("setup-2"), pid: 101, host: HOST, started: "start-of-101" },
      from: "setup", to: "setup", issued: [],
    });
  });

  test("journal order: sent{id} is written before the adapter exits", async () => {
    let exit = (): void => {};
    const until = new Promise<void>((resolve) => { exit = resolve; });
    const { state, deps } = harness({ [id("setup-1")]: { reply: { kind: "accepted" }, until } });
    const running = apply(deps, startK);
    const sawSent = async (): Promise<boolean> => {
      for (let i = 0; i < 200; i += 1) {
        if (runnerEntries(state.entries(D)).includes(`sent ${id("setup-1")}`)) return true;
        await Bun.sleep(1);
      }
      return false;
    };
    const seen = await sawSent();
    exit(); // the adapter exits only now
    expect(seen).toBe(true);
    expect((await running).exit).toBe(0);
  });

  // No core row issues [cancel, decide, notify]; W3 with a tracker status for define gives the same shape:
  // [cancel A (fire), run B (awaited), tracker.update C (fire)].
  const define1 = awaited("define-1", "define", "run", {}, "define", "run");
  const w3 = () => {
    const scripts = (b: Script) => ({ [id("define-2")]: b });
    return { policy: withTracker({ steps: { define: "defining" } }), scripts };
  };

  test("[cancel A, B → accepted, fire C]: C is sent; journal sent A, sent B, accepted B, sent C", async () => {
    const { policy: p, scripts } = w3();
    const { state, spawn, deps } = harness(scripts({ reply: { kind: "accepted" } }), p);
    state.seed(snapshotAt("define", define1));
    const report = await apply(deps, { kind: "signal", delivery: D, signal: changed({ body: "in German too" }) });
    expect(report.exit).toBe(0);
    expect(spawn.sent()).toEqual([id("cancel-1"), id("define-2"), id("update-1")]);
    expect(runnerEntries(state.entries(D))).toEqual([
      `sent ${id("cancel-1")}`, `sent ${id("define-2")}`, `accepted ${id("define-2")}`, `sent ${id("update-1")}`,
    ]);
  });

  test("[cancel A, B → crash, fire C]: C is still sent, then exit 5", async () => {
    const { policy: p, scripts } = w3();
    const { state, spawn, deps } = harness(scripts(crash), p);
    state.seed(snapshotAt("define", define1));
    const report = await apply(deps, { kind: "signal", delivery: D, signal: changed({ body: "in German too" }) });
    expect(report.exit).toBe(5);
    expect(spawn.sent()).toEqual([id("cancel-1"), id("define-2"), id("update-1")]);
    expect(runnerEntries(state.entries(D))).toEqual([
      `sent ${id("cancel-1")}`, `sent ${id("define-2")}`, `adapter_error ${id("define-2")}`, `sent ${id("update-1")}`,
    ]);
  });

  test("a start while the key has a non-terminal Delivery is rejected and journaled on it", async () => {
    const { state, spawn, deps } = harness();
    state.seed(snapshotAt("implement", null));
    const report = await apply(deps, startK);
    expect(report).toEqual({
      exit: 0,
      output: { delivery: D, issued: [], awaiting: null, rejected: true, reason: "an open Delivery already exists for this key" },
    });
    expect(state.top(D)?.entries).toMatchObject([{ note: "rejected_start", time: TIME }]);
    expect(spawn.calls).toHaveLength(0);
  });

  test("a stale Result is ignored, journaled, and reported as ignored", async () => {
    const setup1 = awaited("setup-1", "workspace", "setup", {}, "setup", "run");
    const { state, deps } = harness();
    state.seed(snapshotAt("setup", setup1));
    const stale = { kind: "result", id: id("setup-9"), result: { status: "failed", info: "late" } } as const;
    const report = await apply(deps, { kind: "signal", delivery: D, signal: stale });
    expect(report).toEqual({ exit: 0, output: { delivery: D, issued: [], awaiting: id("setup-1"), ignored: true } });
    expect(state.top(D)?.entries).toMatchObject([{ note: "ignored_stale" }]);
  });
});
