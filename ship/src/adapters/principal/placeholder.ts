// The terminal Principal's printed placeholder for an option-less answer (index.ts's `answerLines`),
// shared with env/text-to-signal-mapper.ts so the two can never silently drift apart. Side-effect-free:
// unlike index.ts, importing this triggers no CLI execution.
export const PLACEHOLDER = "…";
