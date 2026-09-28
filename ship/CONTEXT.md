# ship

A harness that carries a WorkItem from a tracker to a verified production
release, moving it through fixed states. The Principal answers its questions
and passes its gates.

## Language

### Work

**WorkItem**:
One unit of requested work as held by a tracker: a Jira issue, a markdown task,
a GitHub issue.
_Avoid_: ticket, issue, task (dod's term for what its contract covers)

**Delivery**:
One run of a WorkItem through ship's states, from start to closed or abandoned.
A WorkItem can have several Deliveries.
_Avoid_: run, job, pipeline

**Position**:
Where a Delivery is now: one of its steps or gates, Blocked, Closed or
Abandoned.
_Avoid_: phase, stage, status

**Step**:
One fixed part of a Delivery: Setup, Define, Implement, Check, Integrate,
Deploy, Verify, Close, Teardown.
_Avoid_: phase, stage, task

**Acceptance criteria**:
What must be true for a WorkItem to count as delivered, agreed in Define.
_Avoid_: Definition of Done (dod's term), requirements

**Changeset**:
The changes a Delivery makes to the project, as a whole.
_Avoid_: diff, patch, PR

**Main line**:
The branch a project releases from.
_Avoid_: main, master, trunk

**Outcome**:
How a Delivery ended: delivered, accepted with failure, rolled back, abandoned.
_Avoid_: status, result

### Decisions

**Principal**:
The party that answers a Delivery's questions and passes its gates: a person or
an advisor model, reached through whatever channel the project configures.
_Avoid_: human, user, approver, advisor

**Gate**:
A point in a Delivery that holds until the Principal decides, such as accepting
the acceptance criteria or landing the change.
_Avoid_: checkpoint, approval step

**Minimum Principal**:
The least kind of Principal a gate accepts — or a kind of decision within a
gate accepts: a model, or only a person.
_Avoid_: permission level, role

**Blocked**:
A Delivery whose step could not run even after its retries, waiting for the
Principal to choose retry or stop.
_Avoid_: stuck, failed, errored

**Abandoned**:
A Delivery stopped before it closed. Final.
_Avoid_: cancelled, aborted

**Closed**:
A Delivery that went through Close. Final.
_Avoid_: done, finished, completed

### Proof

**Change check**:
Verification of a Delivery's changeset before it lands.
_Avoid_: local verify, pre-merge check

**Release check**:
Verification of a Delivery's effect in production after it deploys, following
its runbook.
_Avoid_: prod verify, smoke test

**Runbook**:
The steps a release check follows to show a Delivery works in production.
_Avoid_: test plan, checklist

**Verdict**:
What a check or a landing concludes about a Delivery, such as pass, fix or
decide. A red verdict is an answer, not a failure.
_Avoid_: status, exit code

**Findings**:
The specific problems a verdict points to, handed back to Implement or to the
Principal.
_Avoid_: issues, errors, comments

**Fix round**:
One return from a check to Implement to address its findings. A Delivery gets a
limited number before the Principal decides.
_Avoid_: iteration, loop, retry

**Capability profile**:
The credentials and tools given to the adapter serving one port: a step's
worker, or a service such as the Tracker or the Principal channel.
_Avoid_: permissions, environment

### Flow

**Command**:
A request the core sends out for one instance of a step or gate, carrying an
id that its result must return with.
_Avoid_: call, job, request

**Signal**:
Anything that reaches the core from outside about a Delivery. Either a Result
or a Delivery signal.
_Avoid_: event, callback, message, wake-up

**Result**:
A signal answering one command — what a step reports, or a Principal's answer —
matched to the command by its id.
_Avoid_: response, reply, callback

**Delivery signal**:
A signal addressed to a Delivery as a whole rather than to a command, such as
start, stop, or a change to its WorkItem.
_Avoid_: event, notification

**Runner**:
The part of ship around the core that loads and saves a Delivery's state, feeds
the core each signal, and carries out the commands the core returns.
_Avoid_: shell, engine, orchestrator, driver

**Workspace**:
The isolated copy of the project a Delivery works in, set up at its start and
torn down when it closes.
_Avoid_: worktree, checkout, sandbox

**Integrate**:
The step that lands a Delivery's changeset on the main line.
_Avoid_: merge, push, integration

**Environment**:
Everything ship runs in but does not own: the machines, listeners and services
that keep it reachable, deliver its signals, recover from crashes and keep time.
_Avoid_: infra, platform, host
