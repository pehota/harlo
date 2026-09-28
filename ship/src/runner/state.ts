// State port client (plan §3.2): load/save/list/journal, each a Runner-only call on the State adapter.
// The stdout schemas validate every reply, so a corrupt snapshot fails `load` (the CLI's exit 4, §5.2).
import type { DeliveryId } from "../contracts/common";
import type {
  StateJournalBody, StateListBody, StateLoadBody, StateSaveBody, StateSavePayload,
} from "../contracts/ports";
import type { TimedEntry } from "../contracts/snapshot";
import type { Snapshot } from "../core/types";
import { type AdapterSpec, callRunnerOnly } from "./spawn";

/** What the apply loop and the CLI need from State. Failures throw RunnerCallError. */
export type State = {
  load(delivery: DeliveryId): Promise<StateLoadBody>; // version 0 and state null when nothing is saved
  save(delivery: DeliveryId, version: number, state: Snapshot, entries: TimedEntry[]): Promise<boolean>; // false: CAS conflict
  list(key?: string): Promise<DeliveryId[]>; // no key: every Delivery
  journal(delivery: DeliveryId): Promise<TimedEntry[]>;
};

export const stateClient = (spec: AdapterSpec): State => ({
  load: (delivery) => callRunnerOnly<StateLoadBody>(spec, "state", "load", { delivery }, delivery),
  save: async (delivery, version, state, entries) => {
    const payload: StateSavePayload = { delivery, version, state, entries };
    const body = await callRunnerOnly<StateSaveBody>(spec, "state", "save", payload, delivery);
    return "saved" in body;
  },
  list: async (key) => {
    const body = await callRunnerOnly<StateListBody>(spec, "state", "list", key === undefined ? {} : { key });
    return body.deliveries;
  },
  journal: async (delivery) => {
    const body = await callRunnerOnly<StateJournalBody>(spec, "state", "journal", { delivery }, delivery);
    return body.entries;
  },
});
