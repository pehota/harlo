# Writing a ship adapter

An adapter is one executable. It serves one or more ports. The Runner spawns
it once per command, feeds it JSON on stdin, and reads one JSON line from
stdout. Types: [`plan.md`](plan.md) §3.1–§3.2, schemas in
[`../src/contracts/`](../src/contracts/). Terms: [`../CONTEXT.md`](../CONTEXT.md).

## The contract

| Channel | What |
|---|---|
| **argv** | `<config argv…> <port> <op>`. The config gives the prefix; the Runner appends port and op. |
| **stdin** | One `Stdin` JSON object (below). |
| **stdout** | One JSON line: a Result, or `{"status":"accepted"}`. |
| **stderr** | Your logs. The Runner keeps the last 2 KB and journals it on a crash. |
| **exit** | `0` whenever you printed a valid reply. Anything else is a crash. |
| **env** | Only `PATH`, `HOME` and your port's capability-profile `env` (secrets resolved). Nothing else is inherited. |

```ts
type Stdin = {
  id: CommandId | null;        // "<delivery>/<name>-<n>"; null on every Runner-only call
  delivery: DeliveryId | null; // "<key>-<attempt>"
  port: Port; op: string;
  workItem: WorkItem | null;
  workspace: string | null;    // the Workspace path, once Setup returned it
  payload: unknown;            // per port/op (plan §3.2)
  tools: string[];             // capability profile tools; secrets come only through env
};
```

**Core commands** always carry `id`, `delivery` and `workItem`.
**Runner-only calls** (`tracker.read`, `tracker.next`, `state.*`) are the Runner's own
reads and writes, not core commands:

| Runner-only call | `id` | `delivery` | `workItem` |
|---|---|---|---|
| `state.load`, `state.save`, `state.journal` | null | set | null |
| `tracker.read` from `ship changed` | null | set | null |
| `tracker.read` from `start` / `next` | null | null | null |
| `tracker.next`, `state.list` | null | null | null |

## Replies

| status | Meaning | Who may print it |
|---|---|---|
| `ok{body, evidence?}` | done; `body` per port/op | every port |
| `failed{info}` | **could not run and changed nothing** | every port |
| `question{prompt, about, options?, evidence?}` | need an answer from the Principal first | **step ports only** (define, implement, check, integrate, deploy, verify) |
| `accepted` | the Result comes later, through `ship signal` | core commands only, never Runner-only calls |

- A red verdict is an `ok`: `{"status":"ok","body":{"verdict":"fix","findings":[…]}}`.
- `accepted` means only "no Result yet". Someone (you, a bot, CI, a person)
  later runs `ship signal <delivery> <id> '<result-json>'` with the same `id`.
- `evidence` is passed to the Principal as is. The core never reads it.

## What the Runner makes of it

| Adapter behaviour | Runner turns it into |
|---|---|
| exit 0, `{"status":"accepted"}` | waiting (journaled `accepted`) |
| exit 0, a valid Result (incl. an explicit `failed`) | that Result, fed to the core as a signal |
| exit 0, invalid JSON, or fails the port/op schema (e.g. a `question` from a service port) | `adapter_error`, no signal; remaining commands run, then exit 5 |
| exit ≠ 0 | `adapter_error`, no signal; remaining commands run, then exit 5 |
| spawn error (executable not found) | `failed{info}` — it provably ran nothing |

Fire commands (notify, comment, `cancel`, tracker.update outside Close): stdout
is ignored. A non-zero exit shows up in the CLI output's `errors`; nothing else
changes.

## Crash vs `failed`

**Catch your own errors.** Print `failed` only when you changed nothing.
Otherwise report through `ok` or `question`.

- `failed` → the core re-issues the command (new id), up to the retry cap, then
  Blocked. Safe only because nothing happened.
- A crash may follow a side effect, so the core never re-issues it. It is
  journaled; the environment or a person resolves it with `ship signal` or
  `ship stop`.

## `cancel{target}`

Every adapter must accept op `cancel` with payload `{"target": "<command id>"}`.

- It is sent to the port that ran the target, when a Delivery signal made that
  command moot (`stop`; or a WorkItem change before Land, which sends the
  Delivery back to Define and re-runs it).
- Stop the target's work if it is still running.
- **Nothing to cancel → exit 0** (print `{"status":"ok","body":{}}`). A finished,
  unknown or synchronous target is not an error.
- An orphaned target process may be killed by the `(pid, started)` pair from its
  `sent` journal entry, only while the pid's start time still equals `started`.

## Coding-agent CLI spike (M1.8, `claude` 2.1.283)

Real, timeboxed calls against the installed `claude` CLI, for `adapters/agent-claude/index.ts` (M1.9–M1.11):

- **Structured output.** `-p/--print --output-format json --json-schema '<inline
  JSON Schema>'` works, but `--json-schema` takes the schema **inline**, not a
  file path (`--json-schema /path/to.json` fails: `not valid JSON`). The
  top-level reply is one JSON object; the schema-validated payload is in its
  `structured_output` field (already parsed — don't re-parse the sibling
  `result` string, which is the same data JSON-encoded as text). On success:
  `is_error:false`, `structured_output` present, exit 0. **[verified]**
- **Session resume.** `--resume <session-id>` genuinely continues the prior
  session (confirmed: a follow-up call referenced specifics only visible to
  that session) and returns the same `session_id`, exit 0. Use the first
  call's `session_id` from its JSON reply — nothing needs to be invented or
  pre-assigned via `--session-id` for the resume case. **[verified]**
- **A `question` field in the structured output.** Ran the real `defineSchema`
  (`{criteria: string[], runbook: string[], question: string}`, none required)
  against a deliberately underspecified WorkItem ("Make it better" / "Fix the
  thing so it works properly"), instructing the agent to set `question` and
  leave `criteria`/`runbook` empty when the request is too ambiguous. Two
  separate calls both came back well-behaved: exit 0, `is_error:false`,
  `structured_output.question` populated with a real clarifying question,
  `criteria`/`runbook` both `[]`. e.g. `structured_output:
  {"question":"Which thing needs fixing, and what does \"not working
  properly\" look like — a specific error message, failing test, broken
  feature, or file/component? Please point to the concrete symptom or
  file.","criteria":[],"runbook":[]}`. Only tested with an explicit ad hoc
  prompt instruction to ask when ambiguous, added on top of the spike's test
  prompt — the shipped `definePrompt` (agent-claude/index.ts) does **not** currently
  include any such instruction, so this does not mirror production; an
  ambiguous WorkItem run through the real `definePrompt` as it ships today
  was not tried, so it's unverified whether the agent volunteers a question
  unprompted, and the `question` branch below may never actually trigger in
  production until `definePrompt` is given an ask-when-ambiguous instruction.
  **[verified]** only that `defineRun`'s `if (out?.question) return
  {status:"question", ...}` branch is reachable and correctly wired against
  the real CLI (not just the fake test binary) when the agent is explicitly
  told to ask — **not** that the shipped define op will ask clarifying
  questions on ambiguous WorkItems today.
- **Fresh session (P8, for Check).** A plain `claude -p ...` with no
  `--resume`/`--session-id` starts a new session every call; this is all
  Check needs to guarantee independence from Implement's session.
  **[verified]**
- **Working directory.** `Bun.spawn([...], { cwd: <dir> })` genuinely runs the
  agent inside `<dir>`: a call with a distinct `cwd` and a prompt asking the
  agent to run `pwd` and report it (schema `{"type":"object","properties":
  {"cwd":{"type":"string"}},"required":["cwd"]}`) returned
  `structured_output.cwd` equal to the launch directory, byte-for-byte, both
  via a plain `cd <dir> && claude -p ...` and via `Bun.spawn`'s own `cwd`
  option. This is what `implement`/`check` rely on to run the agent inside
  the Delivery's workspace. **[verified]**
- **Auth failure.** With `--bare` (which forces `ANTHROPIC_API_KEY`/
  `apiKeyHelper` and never reads OAuth/keychain) and no key configured: process
  exit code **1**, and stdout is still one valid JSON object
  (`is_error:true`, `result:"Not logged in · Please run /login"`,
  `structured_output` absent). The adapter can therefore always parse stdout
  as JSON first and branch on `is_error`/presence of `structured_output`,
  rather than needing a separate path for a non-JSON failure. **[verified]**
- **Tool permissions in headless mode.** A plain `-p` call without
  `--allowedTools`/`--permission-mode` had several of its own `Bash` calls
  denied by this machine's existing shell hook (it rewrites `find`/`ls` to
  `rtk find`/`rtk ls`, and those got denied under the default headless
  permission set) — the agent adapted around it, but a real adapter should
  pass an explicit permission mode (e.g. `--permission-mode` suited to running
  unattended inside an isolated git worktree) rather than rely on whatever the
  ambient host's hooks/permissions default to. **[unverified]** which mode is
  right for production use — flagged for the adapter's own config, not
  resolved by this spike.
- **Cost/latency.** A single `-p` call (no `--bare`) pulled in ~48k tokens of
  cache-creation context (project CLAUDE.md, skills, hooks, etc. via normal
  auto-discovery) before doing any work, at real dollar cost. `--bare` (skip
  hooks, LSP, plugin sync, auto-memory, CLAUDE.md auto-discovery) is worth
  using for the adapter's real invocations to avoid paying for and being
  steered by this host's unrelated tooling — **but** `--bare` also disables
  OAuth/keychain auth, so it only works when the adapter's capability-profile
  env supplies `ANTHROPIC_API_KEY` directly. **[verified]** the tradeoff
  exists; **resolved by M1.12 dogfooding**, see the next bullet.
- **Skill/plugin contamination, and `--safe-mode` as the fix (M1.12
  dogfood finding).** Running the real agent WITHOUT `--bare`/`--safe-mode`
  (to keep OAuth auth working, per the bullet above) let it auto-discover
  this machine's own installed skills/plugins — including an unrelated
  project's `dod:dod-define` skill, whose "MANDATORY self-invoke before any
  edit" rule the agent then applied to the WorkItem it was merely asked to
  *define*. It spontaneously opened its own DoD contract, tried to spawn a
  context-collector sub-agent (denied, no permission mode configured), and
  got stuck referencing an internal "verification table" that never reached
  the `question` field's schema — the ship Principal saw a dangling
  reference with no way to see the table. **[verified]** real, reproducible:
  the exact same host machine, same install, contaminates a plain `-p`
  call. **Fix:** always pass `--safe-mode` (not `--bare`) — it disables the
  same ambient CLAUDE.md/skills/plugins/hooks but, unlike `--bare`, leaves
  OAuth/keychain auth working normally. A project that wants specific
  skills/plugins available during define/implement/check opts in
  explicitly via repeatable `--plugin-dir <path>`, never by ambient
  accident. **[verified]** `--safe-mode` is documented to keep "auth, model
  selection, built-in tools and plugins, and permissions" working; adopted
  in `agent-claude/index.ts` (M1.9-M1.11) accordingly.

Net for `agent-claude/index.ts`: build the payload → prompt text, call `claude -p
--output-format json --json-schema '<schema for the op>' --safe-mode
[--plugin-dir <dir>]... [--resume <stored-session-id>]`, parse stdout as
JSON unconditionally, and branch on `is_error` (→ `failed`, nothing
committed yet, or a crash if a commit already happened per the
crash-vs-`failed` rule above) vs. `structured_output` present (→ map its
fields to the op's `ok`/`question` body).

## Idempotency on the command id

- The `id` names one instance of one step or gate. The core never reuses it: a
  retry or re-ask gets a new id.
- If the same `id` reaches you again (a person re-ran a command by hand), treat
  it as the same command: reuse what the first call made (e.g. an existing pull
  request) and do not repeat side effects.
- Put the `id` wherever an external system lets you tag work (branch, PR, message),
  so a later `ship signal` can carry it back.
