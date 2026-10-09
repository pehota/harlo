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

## `workspace.setup` and the main-line `base`

`ok` body: `{path, base}`. `path` is the Delivery workspace; `base` is the
main-line branch `ship/<delivery>` was branched off (`workspace/worktree.ts`
returns its `--main` value, on a fresh and an idempotent re-setup alike). The
core records `base` in the Delivery's state next to `workspace` and passes it to
every `define.run`, `implement.run` and `check.run` as `payload.base` (fresh runs
and feedback/answer/findings re-runs). A Delivery persisted before `base`
existed has none, and its payloads omit the key.

`agent/claude/index.ts` names the branch in every prompt's workspace rule
(`Main-line branch: <base>`), and says scope and diffs compare against it with a
three-dot diff, `git diff <base>...HEAD`, never an assumed default branch name.
Define must write any diff or scope command in its criteria and runbook that way;
Check judges scope by it, so commits on the main line that are not on
`ship/<delivery>` never count as the changeset's files. With no `base` it falls
back to generic wording ("the main-line branch").

## `agent/claude/index.ts`: `--requirements plain|dod` and declared files (harlo-61)

The requirements object is opaque to the core (harlo-58). The core carries Define's
`body.requirements` unchanged to Implement, Check and Verify. Its shape is the Define
adapter's choice, and `agent/claude/index.ts` offers two, picked by an argv flag
parsed next to `--agent-bin` and `--agent-arg` (see the next section):

```
agent/claude/index.ts [--agent-bin=<path>] [--requirements=plain|dod] [--agent-arg=<--flag[=value]>]... <port> <op>
```

- **`plain`** (the default, also what you get with no flag):
  `{requirements: {criteria: string[], runbook: string[]}}`.
- **`dod`**: `{requirements: <contract>}`, the shape `dod/lib/contract.sh` enforces:

  ```ts
  {
    works_when: string;            // non-empty: "how will we know it works?"
    requirements: {
      id: string;                  // tests, e2e, scenario, docs, review must all be present; extra ids pass through as-is
      type: "check" | "judgement";
      cmd?: string | null;         // check: the command; null only on docs and on an inapplicable e2e/scenario
      expect_exit?: number | null;
      source: string;              // protocol | task | auto-detected | …
      proves: string;              // non-empty: which part of works_when it proves
      applicable?: boolean;        // explicit on e2e, scenario, docs; absent elsewhere means applicable
      reason?: string;             // non-empty whenever applicable is false
      agent?: string;              // judgement: who judges it, e.g. dod-reviewer
      doc_paths?: string[];        // docs, when applicable: repo-relative doc FILE paths this change must update
    }[];
  }
  ```

  A reply that breaks any `contract.sh` write rule is `failed`, never `ok`. The rules:
  `works_when` missing or empty; a protocol id missing; an empty or missing `proves`;
  `applicable:false` without a non-empty `reason`; a `check` without
  `cmd`/`expect_exit` (only `docs`, and `e2e`/`scenario` when `applicable:false`, are
  exempt — any other check entry needs them even when `applicable:false`); `e2e`/`scenario`/`docs` without an explicit
  `applicable`; an applicable `docs` without non-empty `doc_paths`; a `doc_paths` entry
  that is not a repo-relative file path (empty, absolute, ending in `/`, with
  surrounding whitespace, a `..` segment, or an empty or `.` segment such as
  `docs//x.md` or `docs/./x.md`; one leading `./` is fine), named in the `failed` info. Check never matches
  directories, so such a path could never be satisfied.
  [`../test/fixtures/dod-requirements.json`](../test/fixtures/dod-requirements.json) is
  a valid example.

Any other `--requirements` value, or the flag with no value, makes the adapter exit
`2` at startup, before it reads stdin. The message names `--requirements`. It never
falls back to `plain`.

**Check's declared-files rule.** This runs whatever the mode, on any requirements
object. A requirement *declares files* when it is an object with a `doc_paths` array
of strings and is not marked `applicable:false`. Check finds these by walking the
whole object under any key or nesting. It never looks at requirement ids. An
`applicable:false` object is skipped along with everything inside it. For each
declared path, Check runs `git diff --name-only <base>...<sha>` in the workspace,
where `<base>` is the payload's `base` (the Delivery's main line, see above) and
`<sha>` is the changeset's commit. Then:

- Every declared path is in the diff: nothing is added, and Check's verdict is
  the two agent passes' composed verdict, unchanged.
- Any declared path is missing: the verdict is at least `fix`, with one finding
  per missing path (`ref` is the path). This holds even when both agent passes
  reply `pass`. Missing-path findings are added to the agents' own findings and
  never replace them. A `decide` from an agent still outranks `fix`.
- Paths are declared but the payload has no `base`: `failed`, saying the base is
  missing, and no agent call is made. The adapter never assumes a branch name.
  With no declared paths, a missing `base` changes nothing.

## How the claude adapters run `claude`: isolation defaults and `--agent-arg` (harlo-64)

`agent/claude/index.ts` and `principal/claude.ts` run the CLI the same way, through
one shared module, `cli/claude/run.ts`: the same argv parser, the same argv and
the same spawn. Each adapter keeps only how it reads the reply.

**argv of every call:**

```
<agent-bin> -p <prompt> --output-format json --json-schema <schema> [--resume <session>]
  <agent args> [--disallowedTools Edit Write NotebookEdit]
```

The protocol part (`-p`, `--output-format`, `--json-schema`, `--resume`,
`--disallowedTools`) is adapter-owned. `<agent args>` is the default set below,
merged with the adapter's configured `--agent-arg`s.

**Default set:**

| Flag | Why |
|---|---|
| `--setting-sources project` | only the repo's own settings load, never the user's (their plugins, hooks, MCP servers) |
| `--settings '{"disableAllHooks":true}'` | no hook fires: a Stop-gate hook (e.g. dod's) would block a non-interactive turn |
| `--strict-mcp-config` | only MCP servers from `--mcp-config` load |
| `--mcp-config '{"mcpServers":{}}'` | so, by default, none |
| `--permission-mode bypassPermissions` | unattended: nobody can approve a prompt (see ADR 0006) |

Why not `--safe-mode` (used until harlo-64): dogfooding harlo-62 (2026-10-08)
found it disables every plugin skill and agent, `--plugin-dir` ones included, so a
Delivery could never use the project's own skills. `--bare` loads them but cannot
authenticate with OAuth/keychain. Probed with claude 2.1.295: the default set plus
`--plugin-dir <harlo>/dod` loads dod's skills and agents, no user-installed
plugin, no hook, and the repo's CLAUDE.md; auth works. Always loaded, whatever the
flags: the four built-in `cc-plugin-*` plugins, the user's global CLAUDE.md header
(not its `@` imports), and plugins the repo enables in its own `.claude/settings.json`.

**`--agent-arg=<token>`** (repeatable) passes one claude flag through:

- Give it as ONE argv entry, `--agent-arg=<token>`. The parser is strict
  (`node:util` `parseArgs`): `--agent-arg <token>` with a token starting with `-`
  is rejected as ambiguous.
- `<token>` must start with `--`. `--flag=value` splits on the FIRST `=`, so the
  value may contain `=`. `--flag` alone is a boolean flag.
- **Replace rule:** a flag given in any `--agent-arg` drops EVERY default
  occurrence of that flag; all its configured occurrences are kept, in order. A
  flag with no default is appended. So two `--agent-arg=--plugin-dir=…` both pass.
- Replacing `--settings` drops the default `disableAllHooks`: include it in your
  own value if you still want hooks off.
- `--permission-mode` is overridable (at your own risk).
- **Protected**, rejected: `--print` (and `-p`, which fails the `--` rule),
  `--output-format`, `--json-schema`, `--resume`, `--disallowedTools`,
  `--disallowed-tools`, `--verbose` (turns `--output-format json` into a message
  array the reply parser can't read), `--continue`, `--session-id`,
  `--fork-session` (break session ownership: Check always starts fresh, Define
  and Implement own their session ids), `--input-format` (changes how the
  prompt is read). The adapter's own protocol depends on them.

**Failure:** a bad token, a protected flag, or an unknown adapter option (e.g. the
pre-harlo-64 `--plugin-dir <dir>`) fails at startup: exit 2, before stdin is read,
nothing on stdout, the reason on stderr naming the offending value.

**Example**, in `ship.config.json` (edit it by hand; `env/setup.ts` writes the bare
adapter): give Define and Check the dod plugin, and Check one MCP server:

```json
"define": ["bun", "<ship>/src/adapters/agent/claude/index.ts", "--requirements=dod",
  "--agent-arg=--plugin-dir=<harlo>/dod"],
"check": ["bun", "<ship>/src/adapters/agent/claude/index.ts",
  "--agent-arg=--plugin-dir=<harlo>/dod",
  "--agent-arg=--mcp-config={\"mcpServers\":{\"docs\":{\"command\":\"npx\",\"args\":[\"some-mcp\"]}}}"]
```

The `--mcp-config` replaces the empty default; `--strict-mcp-config` stays, so
only `docs` loads.

## `implement.run` and Principal feedback

Payload: `{base?, requirements, findings, feedback?, answer?}` (harlo-58: `requirements` is
whatever the Define adapter's own `ok` body returned, carried through unchanged — the core
never names or constrains its shape, only that it exists). `feedback` is the Principal's
comment, verbatim, from any gate answer that sends the Delivery back to Implement
with one: Accept `accept`, Land `rework`, Decision `keep_going`, Failure
`fix_forward`, and Blocked `retry` when the block is at Implement (harlo-62). No
comment, no `feedback` key. A Blocked `retry` re-issues the saved Implement command
unchanged except for `feedback`: the comment, appended after a blank line to any
`feedback` that command already carried. Which answers carry a comment, and
where it goes, is the `comments` map of each `principal.decide` payload (see below).

`ok` body: `{changeset, feedback?}`.

- `changeset` is an opaque ref the core passes on to Check, Integrate and Deploy.
- `feedback: {outcome: "applied" | "declined", reason}` says what the adapter did
  with the payload's `feedback`. Include it **exactly when** the payload carried
  `feedback`, never otherwise. `reason` is non-empty. The core does not read it.
- Both ends land in the journal. The comment is on the command's `sent` entry
  (`signal.payload.feedback`). The outcome is on the entry for the implement `ok`
  result (`signal.result.body.feedback`). Together they show whether a comment
  was acted on, without reading the agent's reasoning.
- The schema alone cannot require the field, because it never sees the payload.
  So **the adapter validates it**. In `agent/claude/index.ts`, a reply to feedback
  with a missing outcome, an outcome outside `applied`/`declined`, or an empty
  `reason` never becomes `ok`. It is `failed` if nothing was committed, and a crash
  once a commit happened (the crash-vs-`failed` rule above). The schema still
  rejects a bad outcome or an empty `reason` as a backstop. An `applied` with no
  new commit is `failed`. A `declined` may leave HEAD unchanged; then the changeset
  is the current HEAD.
- harlo-60: `agent/claude/index.ts` also asks every Implement reply, with or without
  feedback, for a `commit` attestation: the SHA from `git rev-parse HEAD` after the
  agent commits. The adapter checks it against the workspace's real HEAD. A full SHA
  must equal HEAD; an abbreviated one needs 7+ hex chars and must be a prefix of HEAD.
  A missing, malformed or mismatched `commit` is never `ok`. It is `failed` if nothing
  was committed and a crash once a commit happened. This check is added to the
  before/after HEAD comparison and does not replace it. A correct `commit` with no
  new commit is still `failed`, unless it is a `declined` feedback reply. The `ok`
  body does not change.

## `principal.decide` and comments

`principal/claude.ts` takes `[--agent-bin=<path>] [--agent-arg=<token>]...
principal <op>` and runs `claude` exactly as described in "How the claude adapters
run `claude`" above (no `--resume`, no `--disallowedTools`).

Payload: `{on, options, comments, min, evidence}`. `comments` has one entry per
option, saying where a comment on that answer goes:

- `{goes: "feedback", to}`: to step `to` (`implement` or `define`) as `payload.feedback`.
- `{goes: "reason"}`: to the Delivery's `reason`, so it shows in the outcome's
  tracker comment and notify text.
- `{goes: "dropped"}`: nowhere. Do not send a `comment` with this answer. If one
  arrives anyway, the core applies the answer as if there were none and journals
  the entry with note `ignored_comment`.

The core fills `comments` from `COMMENT_ROUTES` (`src/core/gates.ts`). The one
route that depends on more than the gate is Blocked `retry` (harlo-62): blocked at
Implement it is `{goes: "feedback", to: "implement"}`, so the Principal's guidance
reaches the re-issued Implement as `payload.feedback` and the agent adapter frames
it as a PRINCIPAL DIRECTIVE (its `feedbackDirective`), the same as any other
feedback. Blocked anywhere else, `retry`'s comment is `dropped`, since no other
blockable step takes `feedback`. `ship signal <d> --blocked retry --comment <text>`
routes the comment exactly as the decide answer does (dropped ones are journaled
`ignored_comment` too).

A Principal should show the person, per option, whether a comment is kept.
`principal/tty.ts` marks each option line (`rework  [+ comment → Implement]`,
and blocked at Implement `retry  [+ comment → Implement]`). It drops free text
after a `dropped` option and says so.

## Coding-agent CLI spike (M1.8, `claude` 2.1.283)

Real, timeboxed calls against the installed `claude` CLI, for `src/adapters/agent/claude/index.ts` (M1.9–M1.11).
A historical record of what was tested, kept as-is below: the agent's own `defineSchema` still asks the model
for `criteria`/`runbook` fields exactly as described here — that part is unchanged by harlo-58. What changed is
only how `defineRun` wraps that reply into the port's `ok` body: `{requirements: {criteria, runbook}}`, not
`{criteria, runbook}` directly — the adapter's own choice of what the opaque `requirements` field holds, not a
change to what the model is asked for.

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
  prompt — the shipped `definePrompt` (agent/claude/index.ts) does **not** currently
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
  permission set). **Resolved by M1.12 dogfooding:** every real call
  passes `--permission-mode bypassPermissions` by default, overridable via
  `--agent-arg` (see the harlo-64 section above, the "Skill/plugin
  contamination" bullet below and `agent/claude/index.ts`'s header comment)
  — there is no person at a terminal to approve anything, so the loosest
  mode is simply correct. **[verified]** this unblocks Implement, which
  otherwise silently "finishes without committing" on every real run.
  `bypassPermissions` removing every safety prompt is a real exposure for a
  non-dogfood deployment; see `docs/adr/0006-bypassed-permissions-need-a-sandbox.md`
  for the requirement this creates (process-level sandboxing, not adapter
  code).
- **Cost/latency.** A single `-p` call (no `--bare`) pulled in ~48k tokens of
  cache-creation context (project CLAUDE.md, skills, hooks, etc. via normal
  auto-discovery) before doing any work, at real dollar cost. `--bare` (skip
  hooks, LSP, plugin sync, auto-memory, CLAUDE.md auto-discovery) is worth
  using for the adapter's real invocations to avoid paying for and being
  steered by this host's unrelated tooling — **but** `--bare` also disables
  OAuth/keychain auth, so it only works when the adapter's capability-profile
  env supplies `ANTHROPIC_API_KEY` directly. **[verified]** the tradeoff
  exists; **resolved by M1.12 dogfooding**, see the next bullet.
- **Skill/plugin contamination (M1.12 dogfood finding).** Running the real
  agent WITHOUT `--bare`/`--safe-mode` (to keep OAuth auth working, per the
  bullet above) let it auto-discover this machine's own installed
  skills/plugins — including an unrelated project's `dod:dod-define` skill,
  whose "MANDATORY self-invoke before any edit" rule the agent then applied to
  the WorkItem it was merely asked to *define*. It spontaneously opened its own
  DoD contract, tried to spawn a context-collector sub-agent (denied, no
  permission mode configured), and got stuck referencing an internal
  "verification table" that never reached the `question` field's schema — the
  ship Principal saw a dangling reference with no way to see the table.
  **[verified]** real, reproducible. M1.12's fix was `--safe-mode`; harlo-64
  replaced it, because `--safe-mode` also disables `--plugin-dir` skills. The
  current fix is the isolation default set: see "How the claude adapters run
  `claude`" above.

Net for `agent/claude/index.ts`: build the payload → prompt text, call `claude`
with the argv in "How the claude adapters run `claude`", parse stdout as
JSON unconditionally, and branch on `is_error` (→ `failed`, nothing
committed yet, or a crash if a commit already happened per the
crash-vs-`failed` rule above) vs. `structured_output` present (→ map its
fields to the op's `ok`/`question` body).

## Dogfood driver run findings (M1.13, `env/drive.ts` + `env/text-to-signal-mapper.ts`)

Found running `env/drive.ts` unattended against a real `claude` agent, in a background
process launched from an interactive coding session (not a login shell):

- **Keychain-backed OAuth auth needs `USER` in the adapter's env, not just
  `PATH`/`HOME`.** `runner/spawn.ts`'s `adapterEnv` deliberately strips every env var
  except `PATH`/`HOME` before spawning an adapter (§5.3). This is correct isolation, but
  it silently breaks `agent/claude/index.ts`'s real `claude` calls for anyone
  authenticated via the macOS login keychain rather than `ANTHROPIC_API_KEY`: `claude`
  reports `"Not logged in · Please run /login"` even though the same command run
  directly (any cwd, any process ancestry, backgrounded or not) succeeds. Bisected with
  `env -i PATH=... HOME=... claude -p ...` — adding `USER` alone is sufficient; no other
  var was needed. **Workaround, no code change:** set `capabilities.<port>.env.USER` in
  machine config for `define`/`implement`/`check` (or whichever ports run the real
  agent). No fix landed in `runner/spawn.ts` — flagged here rather than silently
  broadening the stripped env, since that's a real security boundary (P5) and widening
  it deserves its own decision, not a side effect of one dogfood session's auth method.
- **The Decision gate's `keep_going` comment did not reach Implement as an
  actionable code change.** Across 3 fix rounds on the same Check finding (a
  `PLACEHOLDER`-string hardcode that fights the mapper's own genericity goal), first a
  prose description and then an exact, literal code diff were both given as the
  `comment` on `keep_going` — neither produced the requested code change. The only
  effect was two doc-comment-only commits explaining the existing (unchanged) behavior.
  Check re-raised the identical finding, near-verbatim, each round. **Cause: a wiring
  gap in the core** (harlo-38). `decision.keep_going` and `failure.fix_forward` in
  `src/core/transition.ts` never forwarded `b.comment`, unlike `land.rework` and
  `accept.adjust`. So the comment never reached Implement's payload; the resumed agent
  saw only the same finding again. **Fix:** both branches now issue `implement.run`
  with `payload.feedback` set to the comment, verbatim. `agent/claude/index.ts` frames
  it as a Principal directive that takes priority over the agent's earlier reading of
  the finding: make the change, or decline it with a reason; re-explaining the code
  does not count. The agent must report `feedback: {outcome, reason}`, which is
  journaled with the `ok` result (see `implement.run` above).

## Idempotency on the command id

- The `id` names one instance of one step or gate. The core never reuses it: a
  retry or re-ask gets a new id.
- If the same `id` reaches you again (a person re-ran a command by hand), treat
  it as the same command: reuse what the first call made (e.g. an existing pull
  request) and do not repeat side effects.
- Put the `id` wherever an external system lets you tag work (branch, PR, message),
  so a later `ship signal` can carry it back.

## `tracker.next` order (GitHub tracker)

`tracker/github.ts` picks the next key differently per mode:

| Mode | Picks | Why |
|---|---|---|
| Project (`--project <n>`) | first ready item in **board order** | dragging an item up the board prioritises it |
| Labels (no `--project`) | ready issue with the **lowest number** | labels have no order |

- Board order is the output order of `gh project item-list`, which matches the
  item position (as GraphQL `ProjectV2.items`). gh does not document this order.
  If it ever changes, switch to an explicit GraphQL query that reads the position.
- Project mode still skips drafts, pull requests and other repos' issues, and
  lists at most 1000 items.
