// Port subset served by the cross-cutting agent adapter (adapters/agent/claude/index.ts).
export type StepPort = "define" | "implement" | "check";
export const STEP_PORTS = ["define", "implement", "check"] as const satisfies readonly StepPort[];
