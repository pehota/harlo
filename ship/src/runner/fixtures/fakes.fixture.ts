// In-process fakes for apply.test.ts: a State kept in memory and a spawn scripted per command id.
import type { DeliveryId } from "../../contracts/common";
import type { TimedEntry } from "../../contracts/snapshot";
import type { Command, Snapshot } from "../../core/types";
import type { Reply, Spawned } from "../spawn";
import type { State } from "../state";

type Version = { state: Snapshot; entries: TimedEntry[] };
type SaveCall = { delivery: DeliveryId; version: number; state: Snapshot; entries: TimedEntry[] };

/** Versions per Delivery, CAS on the version number. `conflict` forces a conflict for the saves it matches. */
export class FakeState implements State {
  readonly versions = new Map<DeliveryId, Version[]>();
  readonly saves: SaveCall[] = [];
  conflict: (call: SaveCall) => boolean = () => false;

  seed(state: Snapshot): void {
    this.versions.set(state.delivery, [{ state, entries: [] }]);
  }

  top(delivery: DeliveryId): Version | undefined {
    return this.versions.get(delivery)?.at(-1);
  }

  entries(delivery: DeliveryId): TimedEntry[] {
    return (this.versions.get(delivery) ?? []).flatMap((v) => v.entries);
  }

  async load(delivery: DeliveryId) {
    const all = this.versions.get(delivery) ?? [];
    return { version: all.length, state: all.at(-1)?.state ?? null };
  }

  async save(delivery: DeliveryId, version: number, state: Snapshot, entries: TimedEntry[]): Promise<boolean> {
    const call = { delivery, version, state, entries };
    this.saves.push(call);
    const all = this.versions.get(delivery) ?? [];
    if (this.conflict(call) || version !== all.length + 1) return false;
    this.versions.set(delivery, [...all, { state, entries }]);
    return true;
  }

  async list(key?: string): Promise<DeliveryId[]> {
    return [...this.versions.keys()].filter((d) => key === undefined || this.top(d)?.state.workItem.key === key);
  }

  async journal(delivery: DeliveryId): Promise<TimedEntry[]> {
    return this.entries(delivery);
  }
}

/** What the fake adapter for one command id does: reply at once, reply when `until` resolves, or fail to spawn. */
export type Script = { reply: Reply; until?: Promise<void> } | { enoent: string };

/** A spawn that plays `scripts` by command id; an unscripted fire exits 0, an unscripted awaited command accepts. */
export class FakeSpawn {
  readonly calls: { command: Command; saved: Snapshot | undefined }[] = [];
  private pid = 100;

  constructor(private readonly state: FakeState, private readonly scripts: Record<string, Script> = {}) {}

  readonly spawn = (snap: Snapshot, command: Command): Spawned => {
    this.calls.push({ command, saved: this.state.top(snap.delivery)?.state });
    const script = this.scripts[command.id] ?? { reply: command.await ? { kind: "accepted" } : { kind: "fired" } };
    if ("enoent" in script) {
      const info = `spawn failed: ${script.enoent}`;
      return { spawned: false, reply: command.await ? { kind: "result", result: { status: "failed", info } } : { kind: "fire_error", info } };
    }
    this.pid += 1;
    const done = (script.until ?? Promise.resolve()).then(() => script.reply);
    return { spawned: true, pid: this.pid, started: `start-of-${this.pid}`, done };
  };

  sent(): string[] {
    return this.calls.map((c) => c.command.id);
  }
}
