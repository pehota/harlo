// Core types (plan §3.3). Only types come from contracts/; the core never imports ajv.
import type {
  CommandId, DeliveryId, EvidenceItem, Finding, Port, PrincipalKind, Result, WorkItem,
} from "../contracts/common";

export const STEPS = [
  "setup", "define", "implement", "check", "integrate", "deploy", "verify", "close", "teardown",
] as const;
export const GATES = ["accept", "decision", "land", "failure"] as const;

export type Step = (typeof STEPS)[number];
export type Gate = (typeof GATES)[number];
export type Node = Step | Gate; // names are disjoint
export type Position = Node | "blocked" | "closed" | "abandoned"; // where the Delivery is now
export const isTerminal = (at: Position): boolean => at === "closed" || at === "abandoned";
export type Outcome = string; // core derives "delivered" | "accepted_with_failure"; others come from stop

export type Command = {
  id: CommandId;
  port: Port;
  op: string;
  await: boolean;
  payload: unknown;
};
export type Awaiting = Command & {
  node: Node | "blocked"; // step/gate this command belongs to
  kind: "run" | "decide" | "ask";
  options?: string[]; // decide + ask with options: the allowed answers
  about?: string; // ask: from the question
};

export type Snapshot = {
  v: 1;
  delivery: DeliveryId;
  workItem: WorkItem;
  at: Position;
  blockedAt: Node | null; // set iff at = "blocked"
  awaiting: Awaiting | null; // at most one awaited command
  lastRun: Awaiting | null; // last step command issued; re-issued with the answer (Q3)
  blockedCmd: Awaiting | null; // the failed command; re-issued on Blocked → retry (B3)
  seq: Record<string, number>; // per id name, never reset
  retries: number; // consecutive `failed` on the current node
  fixRounds: number;
  workspace: string | null;
  criteria: string[] | null;
  runbook: string[] | null;
  changeset: string | null;
  findings: Finding[]; // latest verdict's findings
  evidence: EvidenceItem[]; // appended, never read (P9)
  outcome: Outcome | null;
  reason: string | null;
};

export type Signal =
  | { kind: "result"; id: CommandId; result: Result }
  | { kind: "stop"; outcome: Outcome; reason: string }
  | { kind: "workItem_changed"; workItem: WorkItem };

export type Note =
  | "ignored_stale" | "ignored_terminal" | "invalid_answer" | "rejected_start"
  | "workitem_changed_late" | "workitem_unchanged";

// Runner-written entries (never produced by the core): from = to = Snapshot.at, issued = []
export type RunnerSignal =
  | { kind: "sent"; id: CommandId; pid: number; host: string; started: string } // started: process start time (pid-reuse guard)
  | { kind: "accepted"; id: CommandId } // the adapter printed `accepted`
  | { kind: "adapter_error"; id: CommandId }; // crash or invalid stdout; `info` = stderr tail

export type Entry = {
  delivery: DeliveryId;
  signal: Signal | { kind: "start"; workItem: WorkItem } | RunnerSignal;
  from: Position | null;
  to: Position;
  issued: CommandId[];
  by?: PrincipalKind; // on Principal answers (ADR 0005)
  note?: Note;
  info?: string;
}; // the Runner adds `time` (the core has no clock)

export type Policy = {
  fixRounds: number;
  retryCap: { default: number } & Partial<Record<Node, number>>;
  minimum: {
    accept: PrincipalKind;
    land: PrincipalKind;
    failure: PrincipalKind;
    blocked: PrincipalKind;
    decision: { scope: PrincipalKind; advisory: PrincipalKind };
    question: Record<string, PrincipalKind>; // by question.about; unknown → "person"
  };
  outcomes: Outcome[]; // stop outcomes
  tracker: {
    steps: Partial<Record<Step, string>>; // status set when a step is entered
    outcomes: Record<Outcome, { status?: string; comment?: boolean }>;
  };
};

export type StartOutput =
  | { kind: "created"; state: Snapshot; commands: Command[]; entry: Entry }
  | { kind: "rejected"; delivery: DeliveryId; entry: Entry }; // entry journaled on the existing Delivery
export type TransitionOutput = { state: Snapshot; commands: Command[]; entry: Entry };
