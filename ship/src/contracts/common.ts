// Shapes shared by the core, the Runner and every adapter (plan §3.1, §3.2).

export type DeliveryId = string; // "<key>-<attempt>", e.g. "PROJ-123-2"
export type CommandId = string; // "<delivery>/<name>-<n>", e.g. "PROJ-123-2/land-1"
export type PrincipalKind = "person" | "model";

export type Port =
  | "define" | "implement" | "check" | "integrate" | "deploy" | "verify"
  | "tracker" | "principal" | "workspace" | "state";

export type WorkItem = { key: string; title: string; body: string; url?: string };
export type Finding = { text: string; ref?: string };
export type EvidenceItem = { label: string; text?: string; url?: string }; // P9: opaque, never read

export type Result<Body = unknown> =
  | { status: "ok"; body: Body; evidence?: EvidenceItem[] }
  | { status: "failed"; info: string } // could not run, changed nothing
  | { status: "question"; prompt: string; about: string; options?: string[]; evidence?: EvidenceItem[] };
export type Stdout<Body = unknown> = Result<Body> | { status: "accepted" };

export type Stdin = {
  id: CommandId;
  delivery: DeliveryId;
  port: Port;
  op: string;
  workItem: WorkItem;
  workspace: string | null;
  payload: unknown;
  tools: string[]; // capability profile tools; secrets go in env only
};

export type DecidePoint = "accept" | "decision" | "land" | "failure" | "blocked"; // blocked is a state, not a Gate
export type GateEvidence = {
  workItem: WorkItem;
  criteria: string[] | null;
  runbook: string[] | null;
  changeset: string | null;
  findings: Finding[];
  evidence: EvidenceItem[];
  note?: string;
};
export type Decide = { on: DecidePoint; options: string[]; min: PrincipalKind; evidence: GateEvidence };
