# Spec — ledger-set scoping for the DoD reviewer range

**Status:** draft
**Date:** 2026-09-04
**Owner:** harlo-2d session (design consult; harlo-advisor peer offline)

---

## Problem

Two parallel `/done` sessions, same git identity (one human, two Claude Code
sessions), each doing **unrelated** commits on shared `main`. Session A's `/done`
DoD-reviews a commit that Session B produced — and B's `/done` reviews it again.
Same commit gets DoD'd twice; worse, A "accepts" work it explicitly declined to
touch because "the resolved base makes it part of the changeset regardless of who
wrote it."

### Root cause — interior foreign commit

`hc__resolve_session_base` (`scripts/harness-common.sh:854`) walks
`HC_BASE_ORIG..HEAD` oldest→newest and **`break`s at the first commit that is in
this session's ledger** (`baselines/<sid>.own-commits`). It therefore advances
the base only past a **contiguous leading run** of foreign commits.

```
base → [your A] → [peer X] → [your B] → HEAD
        ↑ in ledger → break; base never advances; X stays in range
```

Only the one ordering where every foreign commit precedes every own commit is
handled. Any interleave traps the foreign commit in `base..HEAD`, and every
downstream consumer that scopes off `git diff <base>..HEAD` pulls it in:

- `agents/dod-reviewer.md` — "Review `git diff <base> <head>` in full" (line 30).
- `hc_review_coverage_gap` (`harness-common.sh:1238`) — `git diff --name-only
  <base> <head>` is the changed set the review must cover.
- `done-write-state.sh:315` — coverage-gap check, same range.
- `skills/done/dod-protocol.md:106` — "scope everything to `git diff <base> HEAD`".

The commit ledger is already the exact set we need ("commits this session's tool
calls produced" — `scripts/commit-ledger.sh`). It is consulted only to locate a
**base point**, never used as the scope set itself. A point can say "start after
commit N"; it cannot say "review {A, B}, skip X between them." That needs a set.

### Out of scope (already handled)

- Uncommitted parallel edits — `hc_tree_status` is per-session via the `.dirty`
  baseline (`harness-common.sh:913+`).
- Ledger-absent / empty-ledger sessions — email-only fallback stays as-is
  (0.1.15 regression guard).
- Task mode — `hc__resolve_task_base` deliberately never advances past foreign
  commits; the pinned fork point is the anchor. This spec is **session mode
  only**.

---

## Fix — set-membership scope when the ledger is engaged

Stop deriving a scope from a single base point when the ledger is engaged.
Scope the review to the **ledgered SHAs within `HC_BASE_ORIG..HEAD`**, review
each commit's own diff, union the file set. Non-contiguous foreign commits fall
out automatically. Peer's `/done` does the same against *its* ledger — disjoint
sets, zero overlap, no cross-session coordination.

"Ledger engaged" = `baselines/<sid>.own-commits` exists **and is non-empty** —
identical predicate to `hc__resolve_session_base` line 885. Empty or absent →
no set, fall back to the existing point-base path unchanged.

### New helper — `hc_session_changeset_commits`

`scripts/harness-common.sh`, near `hc__resolve_session_base`.

```
# hc_session_changeset_commits <session_id> [proj]
#
# Emits, one SHA per line oldest→newest, the commits in HC_BASE_ORIG..HEAD that
# are members of this session's ledger (baselines/<sid>.own-commits). This is
# the SET the DoD review must cover in session mode when the ledger is engaged
# — as opposed to the contiguous <base>..HEAD range, which wrongly includes
# interior foreign commits (peer sessions, same git identity).
#
# Prints nothing (rc 0) when: ledger absent or empty, no base anchor, git
# failure, or the intersection is empty. Callers treat "empty output" as
# "ledger not engaged → use the point-base path".
```

Implementation sketch:

```sh
hc_session_changeset_commits() {
  local session_id="$1"
  local proj="${2:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local ledger="$HARNESS_DIR/baselines/${session_id}.own-commits"
  [ -s "$ledger" ] || return 0

  local base_file="$HARNESS_DIR/baselines/${session_id}.sha"
  [ -f "$base_file" ] || return 0
  local base; base=$(cat "$base_file" 2>/dev/null)
  [ -z "$base" ] && return 0

  local head; head=$(git -C "$proj" rev-parse HEAD 2>/dev/null)
  [ -z "$head" ] && return 0

  local revs; revs=$(git -C "$proj" rev-list --reverse "$base..$head" 2>/dev/null) || return 0
  local c
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    hc__commit_in_ledger "$c" "$session_id" && printf '%s\n' "$c"
  done <<EOF
$revs
EOF
}
```

Notes:
- Reuses `hc__commit_in_ledger` (`harness-common.sh:689`) — exact-line grep, the
  same membership test `hc__resolve_session_base` uses.
- Bounded by `base..head` ancestry so stale ledger lines from an
  amended/rebased-away commit that is no longer reachable simply don't appear.
- No dependency on `HC_BASE` (the *advanced* base) — always the original anchor,
  so an interior own-commit before an interior foreign one is still included.

### Changed-file set for coverage

Add a sibling that turns that commit set into the changed-path set the coverage
check needs:

```
# hc_session_changeset_files <session_id> [proj]
#
# Union of `git diff --name-only <c>^ <c>` over every SHA from
# hc_session_changeset_commits. The paths the DoD review must cover when the
# ledger is engaged. Empty output → ledger not engaged (caller uses point-base).
```

Merge commits: `git diff --name-only <c>^ <c>` uses first-parent; acceptable —
harness convention is linear history on `main`, and a merge the session itself
performed is in its ledger and its first-parent diff is the right scope.

---

## Consumer changes

### 1. `hc_review_coverage_gap` (`harness-common.sh:1238`)

Currently: `changed=$(git -C "$proj" diff --name-only "$base" "$head")`.

Change: before that line, try the ledger set —

```sh
if hc_has_fn hc_session_changeset_files && [ -n "${HC_SESSION_ID:-}" ]; then
  local ledger_changed
  ledger_changed=$(hc_session_changeset_files "$HC_SESSION_ID" "$proj")
  [ -n "$ledger_changed" ] && changed="$ledger_changed"
fi
[ -n "$changed" ] || changed=$(git -C "$proj" diff --name-only "$base" "$head" 2>/dev/null) || { printf 'SKIP'; return 0; }
```

`hc_resolve` takes `session_id` as `$1` but does **not** currently persist it as
a global (confirmed: `harness-common.sh:573-614` — resets `HC_*` outputs, never
stores the id). Add `HC_SESSION_ID="$session_id"` to the reset block (~line 585)
so consumers can reach it. If empty, `hc_review_coverage_gap` degrades to the
existing range exactly as today.

The attested-log chain-walk below (lines ~1290-1320) is unaffected: it filters
logs by ancestry to `head` and non-ancestry to `base`, which is still correct —
an interior foreign commit's log (if any) is simply not this session's and its
paths, if they don't intersect `changed`, cost nothing.

### 2. `agents/dod-reviewer.md`

Round-1 input currently: `<base>` + "Review `git diff <base> <head>` in full."

Change the round-1 contract to accept a **commit list** when given one:

- New optional input line: `<commits>` — a newline-separated list of SHAs
  (oldest→newest) that constitute this session's changeset. When present, round 1
  reviews `git diff <c>^ <c>` for **each** listed commit and the union is the
  changeset; `files_reviewed` attests the union of `git diff --name-only <c>^ <c>`.
- When `<commits>` is absent (ledger not engaged, or task mode), behaviour is
  exactly today's `git diff <base> <head>`.
- Round 2 (delta-scoped) is unchanged — `git diff <prevHEAD> <head>`.

`files_reviewed` attestation rule (line 74+) gains one bullet: "When reviewing a
commit list, `files_reviewed ⊇ ⋃ git diff --name-only <c>^ <c>` over the list."

### 3. `skills/done/dod-protocol.md`

- Line ~105-106: replace "resolve the changeset base … scope everything to
  `git diff <base> HEAD`" with: "resolve the changeset base **and** the ledger
  commit set via the shared resolver. When the ledger is engaged, scope the
  review to that commit set (`git diff <c>^ <c>` per commit, union); otherwise
  `git diff <base> HEAD`."
- Line ~18: the "agents still race" caveat can note that same-identity parallel
  sessions on shared main are now scoped apart by ledger membership, not just by
  base point.
- Step 5 round-1 dispatch (line ~322): pass the commit list to the reviewer when
  `hc_session_changeset_commits` is non-empty.

### 4. `done-gate.sh` / `done-write-state.sh`

`done-gate.sh` Step 8 and `done-write-state.sh:315` both call
`hc_review_coverage_gap` with `<base> <head>`. Once (1) reads the ledger set
internally, **no call-site change is needed** — the range args stay as the
fallback. Confirm `HC_SESSION_ID` is in scope at both call sites (it is: both
`hc_resolve` first).

`base_sha` written into the review-log/done-state (`done-write-state.sh:366`)
stays `HC_BASE` (the advanced point base) — it is still a valid lower bound for
the gate's HEAD-keyed evidence check and the anchor-recovery paths. The ledger
set is a *scoping* refinement, not a new persisted anchor. No schema change.

---

## Test — `tests/test-gate.sh`

New chunk: **interior foreign commit is excluded from session-mode DoD scope.**

Setup:
1. Init repo, one commit `C0`. Record it as `baselines/<sid>.sha`.
2. Simulate the session's own commit `A` — append `A` to
   `baselines/<sid>.own-commits`.
3. Simulate a **peer** commit `X` (not appended to the ledger).
4. Simulate the session's own commit `B` — append `B`.
   History: `C0 → A → X → B` (HEAD).

Assertions:
- `hc_session_changeset_commits <sid>` emits exactly `A\nB` (not `X`).
- `hc_session_changeset_files <sid>` = union of A's and B's changed paths, and
  **does not** include a path touched only by `X`.
- `hc_review_coverage_gap` with a review-log attesting only A's + B's files
  returns empty (PASS) — i.e. `X`'s file is not demanded.
- Control: with the ledger **absent**, `hc_review_coverage_gap` still demands
  `X`'s file (existing behaviour preserved).
- Control: with the ledger **empty** (`-f` but 0 bytes), same as absent.

Also pin: `hc__resolve_session_base` still `break`s at `A` (its point-base
behaviour is unchanged — this spec adds a set path, does not alter the loop).

---

## Non-goals

- No cross-session locking, claim files, or coordination channel. Ledger
  membership is sufficient and needs no communication.
- No change to task mode.
- No change to the working-tree (`.dirty`) path.
- No new persisted anchor or review-log field.

---

## Touch list

| File | Change |
|---|---|
| `scripts/harness-common.sh` | + `hc_session_changeset_commits`, + `hc_session_changeset_files`; `hc_review_coverage_gap` consults them; + `HC_SESSION_ID="$session_id"` in `hc_resolve` reset block (~line 585) |
| `agents/dod-reviewer.md` | round-1 accepts optional `<commits>` list; `files_reviewed` attestation bullet |
| `skills/done/dod-protocol.md` | scope wording (§105-106), Step 5 dispatch passes commit list, race caveat note |
| `tests/test-gate.sh` | + interior-foreign-commit chunk with absent/empty ledger controls |

`done-gate.sh` and `done-write-state.sh`: no code change if `hc_review_coverage_gap`
absorbs it internally — verify `HC_SESSION_ID` scope only.
