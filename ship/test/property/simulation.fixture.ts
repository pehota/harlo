// Test data for lifecycle.property.test.ts: a simulated environment around the REAL core and apply loop.
// - SimState: the in-process FakeState with crash points on load and save (before and after the commit).
// - Sim.spawn: fake adapters as simulated processes (pid, start time, end time), with crash points before the
//   process starts, after it starts but before `sent` is written, and while the Runner waits on it (orphan).
// - The mailbox holds the Results that `accepted` commands deliver later; the environment may deliver them in
//   any order, twice, or drop them (a dropped one is followed by a `stop` in `finish`).
// - A simulated clock, read by the Runner's `now` and by the stall model only.
import { isDeepStrictEqual } from "node:util";
import type { DeliveryId, PrincipalKind, Result, WorkItem } from "../../src/contracts/common";
import type { TimedEntry } from "../../src/contracts/snapshot";
import { isTerminal, type Command, type Node, type Policy, type Signal, type Snapshot } from "../../src/core/types";
import { type Deps, type Pending, apply } from "../../src/runner/apply";
import { FakeState } from "../../src/runner/fixtures/fakes.fixture";
import type { Reply, Spawned } from "../../src/runner/spawn";
import { type Flag, type Poll, hasOutcome, isAccepted, sentOf, stallFlag, startedAt } from "./stall.fixture";

export const GRACE = 60_000;
export const MAX_RUNTIME = 600_000;
const HOST = "sim-host";
const QUICK = 1_000; // an adapter that prints `accepted` and exits
const SYNC_RUNS = [GRACE / 2, GRACE / 2, GRACE * 3, MAX_RUNTIME * 2]; // short, past grace, past maxRuntime
const SPAWN_BOUND = 300; // per Runner invocation: a runaway immediate-Result chain is a bug, not a hang
const BODIES = ["Say hello.", "Say hello in German too.", "Say hello twice."];
const WORK_ITEM: WorkItem = { key: "k", title: "Greet by name", body: BODIES[0]! };

/** One environment move. `crash`: the Runner dies at that crash point of its invocation (1-based). */
export type Action =
  | { kind: "start"; crash: number | null }
  | { kind: "deliver" | "duplicate"; pick: number; crash: number | null }
  | { kind: "drop"; pick: number }
  | { kind: "changed"; body: number; crash: number | null }
  | { kind: "stop"; crash: number | null }
  | { kind: "wait"; ms: number }
  | { kind: "reusePid"; pick: number };

export type Coverage = {
  syncPastGrace: number; orphanYoung: number; orphanHung: number; orphanGone: number; pidReused: number; crashes: number;
};
const noCoverage = (): Coverage => ({ syncPastGrace: 0, orphanYoung: 0, orphanHung: 0, orphanGone: 0, pidReused: 0, crashes: 0 });

type Proc = { pid: number; started: string; startT: number; endT: number; orphan: boolean };
type Mail = { delivery: DeliveryId; signal: Signal };
type Plan = { enoent: true } | { reply: Reply; run: number; later?: Result };

class Crash extends Error {}

class SimState extends FakeState {
  constructor(private readonly point: (name: string) => void) {
    super();
  }

  override async load(delivery: DeliveryId) {
    this.point("load");
    return super.load(delivery);
  }

  override async save(delivery: DeliveryId, version: number, state: Snapshot, entries: TimedEntry[]): Promise<boolean> {
    this.point("save");
    const saved = await super.save(delivery, version, state, entries);
    this.point("saved"); // committed, then died: e.g. between save and execute
    return saved;
  }
}

const ok = (body: unknown): Result => ({ status: "ok", body });
const failed: Result = { status: "failed", info: "could not run" };
const findings = [{ text: "greets nobody" }];

export class Sim {
  clock = Date.parse("2026-09-28T12:00:00.000Z");
  readonly state = new SimState((name) => this.point(name));
  readonly violations: string[] = [];
  readonly coverage = noCoverage();
  private readonly procs: Proc[] = [];
  private readonly mailbox: Mail[] = [];
  private readonly owedStops = new Set<DeliveryId>();
  private readonly spawned = new Set<string>();
  private cursor = 0;
  private serial = 0;
  private crashAt: number | null = null;
  private points = 0;
  private spawns = 0;
  private thisRun: Proc[] = [];

  constructor(readonly policy: Policy, private readonly choices: number[]) {}

  private readonly deps = (): Deps => ({
    policy: this.policy, state: this.state, spawn: this.spawn, host: HOST, now: () => new Date(this.clock).toISOString(),
  });

  /** The next scripted choice in [0, n). */
  private pick(n: number): number {
    const choice = this.choices[this.cursor % this.choices.length] ?? 0;
    this.cursor += 1;
    return choice % n;
  }

  private point(name: string): void {
    this.points += 1;
    if (this.points === this.crashAt) throw new Crash(name);
  }

  // ── Processes ──

  /** `ps`: the start time of whatever holds the pid at time t. */
  private startOf(pid: number, t: number): string | null {
    return this.procs.filter((p) => p.pid === pid && p.startT <= t && t < p.endT).at(-1)?.started ?? null;
  }

  private startProcess(run: number): Proc {
    let pid = 100;
    while (this.startOf(pid, this.clock) !== null) pid += 1; // lowest free pid: dead pids are reused
    this.serial += 1;
    const proc = { pid, started: `${this.clock}#${this.serial}`, startT: this.clock, endT: this.clock + run, orphan: false };
    this.procs.push(proc);
    this.thisRun.push(proc);
    return proc;
  }

  private poll(t: number): Poll {
    return { now: t, host: HOST, grace: GRACE, maxRuntime: () => MAX_RUNTIME, startOf: (pid) => this.startOf(pid, t) };
  }

  // ── Fake adapters ──

  private by(min: PrincipalKind): PrincipalKind {
    return min === "person" || this.pick(2) === 0 ? "person" : "model"; // at or above the min it was sent
  }

  private resultFor(command: Command): Result {
    const payload = command.payload as { options?: string[]; min: PrincipalKind };
    const r = this.pick(10);
    switch (`${command.port}.${command.op}`) {
      case "principal.decide":
      case "principal.ask": {
        const options = payload.options;
        const answer = options && r > 0 ? options[this.pick(options.length)]! : "free text"; // may be invalid
        return ok({ answer, by: this.by(payload.min) });
      }
      case "workspace.setup": return r === 0 ? failed : ok({ path: "/ws/sim" });
      case "workspace.teardown": return r === 0 ? failed : ok({});
      case "tracker.update": return r === 0 ? failed : ok({});
      case "define.run":
        return r === 0 ? failed : r === 1 ? question("clarify") : ok({ requirements: { criteria: ["greets"], runbook: ["run greet"] } });
      case "implement.run": return r === 0 ? failed : r === 1 ? question("clarify") : ok({ changeset: "cs" });
      case "check.run":
        if (r === 0) return failed;
        if (r === 1) return question("clarify");
        if (r <= 4) return ok({ verdict: "fix", findings });
        if (r === 5) return ok({ verdict: "decide", about: this.pick(2) ? "scope" : "advisory", findings });
        return ok({ verdict: "pass" });
      case "integrate.run":
        if (r === 0) return failed;
        if (r === 1) return question("conflict");
        return r <= 3 ? ok({ verdict: "fix", findings }) : ok({ verdict: "landed" });
      case "deploy.run": return r === 0 ? failed : r <= 2 ? ok({ verdict: "not_live" }) : ok({ verdict: "live" });
      case "verify.run": return r === 0 ? failed : r <= 2 ? ok({ verdict: "fail", findings }) : ok({ verdict: "pass" });
      default: throw new Error(`simulation has no adapter for awaited ${command.port}.${command.op}`);
    }
  }

  /** What the adapter for this command does: Principal always `accepted`; step/service ports sync, accepted or ENOENT. */
  private plan(command: Command): Plan {
    if (!command.await) return { reply: { kind: "fired" }, run: 0 };
    const later = this.resultFor(command);
    if (command.port === "principal") return { reply: { kind: "accepted" }, run: QUICK, later };
    const mode = this.pick(10);
    if (mode === 0) return { enoent: true };
    if (mode <= 4) return { reply: { kind: "accepted" }, run: QUICK, later };
    return { reply: { kind: "result", result: later }, run: SYNC_RUNS[this.pick(SYNC_RUNS.length)]! };
  }

  readonly spawn = (snap: Snapshot, command: Command): Spawned => {
    this.point("spawn"); // died between save and execute: the command is lost
    this.spawns += 1;
    if (this.spawns > SPAWN_BOUND) throw new Error(`simulation bound: ${SPAWN_BOUND} spawns in one invocation`);
    if (this.spawned.has(command.id)) this.violations.push(`command spawned twice: ${command.id}`);
    this.spawned.add(command.id);

    const plan = this.plan(command);
    if ("enoent" in plan) return { spawned: false, reply: { kind: "result", result: { status: "failed", info: "ENOENT" } } };
    const proc = this.startProcess(plan.run);
    if (plan.later) this.mailbox.push({ delivery: snap.delivery, signal: { kind: "result", id: command.id, result: plan.later } });
    this.point("spawned"); // died after the process started, before `sent`: the remaining window

    const exit = async (): Promise<Reply> => {
      this.point("waiting"); // died while waiting on the adapter: it is orphaned and its Result is lost
      if (command.await) this.midRun(snap.delivery, proc);
      this.clock = Math.max(this.clock, proc.endT);
      return plan.reply;
    };
    // Lazy: the process's exit is observed only when the Runner waits on it (after journaling `sent`).
    let exited: Promise<Reply> | undefined;
    const done = { then: (res: (r: Reply) => unknown, rej: (e: unknown) => unknown) => (exited ??= exit()).then(res, rej) };
    return { spawned: true, pid: proc.pid, started: proc.started, done: done as unknown as Promise<Reply> };
  };

  /** Poll just before a synchronous adapter exits: running past grace but within maxRuntime is not flagged. */
  private midRun(delivery: DeliveryId, proc: Proc): void {
    const t = proc.endT - 1;
    const age = t - proc.startT;
    if (age <= GRACE || age > MAX_RUNTIME) return;
    this.coverage.syncPastGrace += 1;
    const flag = this.flagAt(delivery, t);
    if (flag !== null) this.violations.push(`sync adapter at age ${age} flagged "${flag}" (${delivery})`);
  }

  // ── The Runner ──

  private async invoke(pending: Pending, crash: number | null): Promise<void> {
    this.crashAt = crash;
    this.points = 0;
    this.spawns = 0;
    this.thisRun = [];
    try {
      await apply(this.deps(), pending);
    } catch (error) {
      if (!(error instanceof Crash)) throw error;
      this.coverage.crashes += 1;
      for (const p of this.thisRun) if (p.endT > this.clock) p.orphan = true; // adapters do not die with the Runner
    } finally {
      this.crashAt = null;
    }
  }

  private deliveries(): DeliveryId[] {
    const attempt = (d: DeliveryId) => Number(d.split("-").at(-1));
    return [...this.state.versions.keys()].sort((a, b) => attempt(a) - attempt(b));
  }

  private latest(): DeliveryId | undefined {
    return this.deliveries().at(-1);
  }

  async act(action: Action): Promise<void> {
    switch (action.kind) {
      case "start": return this.invoke({ kind: "start", workItem: WORK_ITEM }, action.crash);
      case "deliver":
      case "duplicate": {
        if (this.mailbox.length === 0) return;
        const i = action.pick % this.mailbox.length;
        const mail = this.mailbox[i]!;
        if (action.kind === "deliver") this.mailbox.splice(i, 1);
        return this.invoke({ kind: "signal", ...mail }, action.crash);
      }
      case "drop": {
        if (this.mailbox.length === 0) return;
        const [mail] = this.mailbox.splice(action.pick % this.mailbox.length, 1);
        this.owedStops.add(mail!.delivery);
        return;
      }
      case "changed": {
        const delivery = this.latest();
        if (!delivery) return;
        const workItem = { ...WORK_ITEM, body: BODIES[action.body % BODIES.length]! };
        return this.invoke({ kind: "signal", delivery, signal: { kind: "workItem_changed", workItem } }, action.crash);
      }
      case "stop": {
        const delivery = this.latest();
        if (!delivery) return;
        return this.invoke({ kind: "signal", delivery, signal: { kind: "stop", outcome: "abandoned", reason: "sim" } }, action.crash);
      }
      case "wait":
        this.clock += action.ms;
        return;
      case "reusePid": {
        const gone = this.procs.filter((p) => p.orphan && p.endT <= this.clock && this.startOf(p.pid, this.clock) === null);
        const reused = gone[action.pick % Math.max(gone.length, 1)];
        if (!reused) return;
        this.serial += 1; // an unrelated process: same pid, another start time, never exits
        this.procs.push({ pid: reused.pid, started: `${this.clock}#${this.serial}`, startT: this.clock, endT: Infinity, orphan: false });
        return;
      }
    }
  }

  /** Every dropped signal is eventually followed by a `stop`; then the poller runs once the grace period is over. */
  async finish(): Promise<void> {
    for (const delivery of this.owedStops) {
      await this.invoke({ kind: "signal", delivery, signal: { kind: "stop", outcome: "abandoned", reason: "signal lost" } }, null);
      const at = this.top(delivery).at;
      if (!isTerminal(at)) this.violations.push(`${delivery} still ${at} after the stop for its dropped signal`);
    }
    this.clock += GRACE + 1;
    this.settle(false);
  }

  // ── Checks at quiescent points ──

  top(delivery: DeliveryId): Snapshot {
    const top = this.state.top(delivery);
    if (!top) throw new Error(`no Delivery ${delivery}`);
    return top.state;
  }

  private flagAt(delivery: DeliveryId, t: number): Flag | null {
    return stallFlag(this.top(delivery), this.state.entries(delivery), this.poll(t));
  }

  /**
   * At most one non-terminal Delivery per WorkItem, and no silent stall. `inGrace`: a command not yet sent is
   * allowed while its Delivery's last entry is within the grace period (the poller's own allowance).
   */
  settle(inGrace: boolean): void {
    const open = this.deliveries().filter((d) => !isTerminal(this.top(d).at));
    if (open.length > 1) this.violations.push(`more than one non-terminal Delivery: ${open.join(", ")}`);
    for (const delivery of open) this.stallCheck(delivery, inGrace);
  }

  private stallCheck(delivery: DeliveryId, inGrace: boolean): void {
    const s = this.top(delivery);
    if (s.at === "blocked") return;
    const awaiting = s.awaiting;
    if (awaiting === null) {
      this.violations.push(`silent stall: ${delivery} at ${s.at} awaits nothing`);
      return;
    }
    const entries = this.state.entries(delivery);
    const flag = this.flagAt(delivery, this.clock);
    const sent = sentOf(entries, awaiting.id);
    const proc = sent && this.procs.find((p) => p.started === sent.started);
    const alive = proc !== undefined && proc.startT <= this.clock && this.clock < proc.endT;
    const young = sent !== undefined && this.clock - startedAt(sent.started) <= MAX_RUNTIME;
    const last = entries.at(-1);
    const quiet = last === undefined || this.clock - Date.parse(last.time) <= GRACE;

    const covered = flag !== null || isAccepted(entries, awaiting.id) || (alive && young) || (!sent && inGrace && quiet);
    if (!covered) this.violations.push(`silent stall: ${delivery} at ${s.at} awaiting ${awaiting.id}`);

    // Ground truth from the process table, against the model's view through (pid, started).
    if (!sent || hasOutcome(entries, awaiting.id)) return;
    const expected: Flag | null = !alive ? "dead" : young ? null : "hung?";
    if (flag !== expected) this.violations.push(`${awaiting.id}: expected ${expected}, stall check says ${flag}`);
    if (proc?.orphan) {
      if (alive && young) this.coverage.orphanYoung += 1;
      if (alive && !young) this.coverage.orphanHung += 1;
      if (!alive) this.coverage.orphanGone += 1;
    }
    if (!alive && this.startOf(sent.pid, this.clock) !== null) this.coverage.pidReused += 1;
  }

  // ── Checks over the journal and every saved snapshot ──

  /** Per Delivery, each saved version with the snapshot before it (null for the created version). */
  private steps(delivery: DeliveryId) {
    const versions = this.state.versions.get(delivery) ?? [];
    return versions.map((v, i) => ({ before: i === 0 ? null : versions[i - 1]!.state, after: v.state, entries: v.entries }));
  }

  checkJournal(): void {
    const issued = new Set<string>();
    for (const delivery of this.deliveries()) {
      let rounds = 0; // fix rounds since the last Principal decision
      for (const { before, after, entries } of this.steps(delivery)) {
        for (const entry of entries) {
          for (const id of entry.issued) {
            if (issued.has(id)) this.violations.push(`command id reused: ${id}`);
            issued.add(id);
          }
        }
        if (before === null) continue;
        const entry = entries[0]!;
        const why = (rule: string) => this.violations.push(`${delivery}: ${rule} (${before.at} → ${after.at}, ${JSON.stringify(entry.signal)})`);

        if (isTerminal(before.at) && !isDeepStrictEqual(before, after)) why("terminal Delivery changed");
        const signal = entry.signal;
        if (signal.kind === "result" && before.awaiting?.id !== signal.id && !isDeepStrictEqual(before, after)) {
          why("a Result not awaited was applied");
        }

        const entering = (node: Node) => inNode(after, node) && !inNode(before, node);
        const byRank = (min: PrincipalKind) => entry.by !== undefined && RANK[entry.by] >= RANK[min];
        if (entering("integrate") && !(before.at === "land" && answerOf(entry) === "approve" && byRank(this.policy.minimum.land))) {
          why("Integrate issued without a Land approve at or above the Land minimum");
        }
        if (entering("deploy") && !(before.at === "integrate" && verdictOf(entry) === "landed")) why("Deploy issued without Integrate landed");
        const closeOk = (before.at === "verify" && verdictOf(entry) === "pass") || (before.at === "failure" && answerOf(entry) === "accept");
        if (entering("close") && !closeOk) why("Close entered without Verify pass or Failure accept");
        if (entering("teardown") && !inNode(before, "close")) why("Teardown entered without Close");
        if (after.at === "closed" && before.at !== "closed" && before.at !== "teardown") why("Closed entered without Teardown");

        if (entry.by !== undefined) rounds = 0;
        const applied = signal.kind === "result" && before.awaiting?.id === signal.id; // not a stale duplicate
        if (applied && verdictOf(entry) === "fix" && after.at === "implement") rounds += 1;
        if (rounds > this.policy.fixRounds || after.fixRounds > this.policy.fixRounds) why(`more than ${this.policy.fixRounds} fix rounds`);
      }
    }
  }
}

const RANK: Record<PrincipalKind, number> = { model: 0, person: 1 };
const inNode = (s: Snapshot, node: Node): boolean => s.at === node || (s.at === "blocked" && s.blockedAt === node);
const question = (about: string): Result => ({ status: "question", prompt: "which name?", about });

const okBody = (entry: TimedEntry): Record<string, unknown> | null =>
  entry.signal.kind === "result" && entry.signal.result.status === "ok" ? (entry.signal.result.body as Record<string, unknown>) : null;
const answerOf = (entry: TimedEntry): unknown => okBody(entry)?.answer;
const verdictOf = (entry: TimedEntry): unknown => okBody(entry)?.verdict;

/** Run the actions, checking at every quiescent point, then the final checks. */
export const runScenario = async (policy: Policy, actions: Action[], choices: number[]): Promise<Sim> => {
  const sim = new Sim(policy, choices);
  for (const action of actions) {
    await sim.act(action);
    sim.settle(true);
  }
  await sim.finish();
  sim.checkJournal();
  return sim;
};
