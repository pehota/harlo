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
  <base> <head>` is the changed set the review must cover (range diff at
  `:1262`).
- `done-write-state.sh:315` — coverage-gap check, `<HC_BASE> <VERIFIED_SHA>`.
- `skills/done/dod-protocol.md` ~line 107 — "scope everything to `git diff
  <base> HEAD`".

The commit ledger is already the exact set we need ("commits this session's tool
calls produced" — `scripts/commit-ledger.sh`). It is consulted only to locate a
**base point**, never used as the scope set itself. A point can say "start after
commit N"; it cannot say "review {A, B}, skip X between them." That needs a set.

### Prior art in the codebase

The per-commit "is this positively the session's own work?" predicate **already
exists**: `hc__commit_session_authored` (`harness-common.sh:784`). It is
**ledger-preferring** — when `baselines/<sid>.own-commits` exists and is
non-empty it delegates to `hc__commit_in_ledger`; otherwise it falls back to the
committer-email check. `hc__session_authored_count` (`:746`) already walks
`orig_base..head` applying it, for the "N authored this session" summary line.

**This spec reuses `hc__commit_session_authored`** as the membership test — it
must not introduce a parallel ledger call. The only new code is a helper that
*emits the SHAs* (rather than counting them) plus its changed-file sibling.

### Out of scope (already handled)

- Uncommitted parallel edits — `hc_tree_status` is per-session via the `.dirty`
  baseline (`harness-common.sh:913+`).
- Ledger-absent / empty-ledger sessions — email-only fallback in
  `hc__commit_session_authored` stays as-is (0.1.15 regression guard).
- Task mode — `hc__resolve_task_base` deliberately never advances past foreign
  commits; the pinned fork point is the anchor. This spec is **session mode
  only**.

---

## Fix — set-membership scope when the ledger is engaged

Stop deriving a scope from a single base point when the ledger is engaged.
Scope the review to the **session-authored SHAs within `HC_BASE_ORIG..HEAD`**,
review each commit's own diff, union the file set. Non-contiguous foreign commits
fall out automatically. Peer's `/done` does the same against *its* ledger —
disjoint sets, zero overlap, no cross-session coordination.

"Ledger engaged" is decided **inside `hc__commit_session_authored`** (file exists
AND non-empty). The helpers below therefore do not re-check it; they simply emit
nothing when no commit passes the predicate, and callers treat empty output as
"not engaged → use the point-base path unchanged."

### The base-consistency requirement (load-bearing)

Both new helpers, **and** the `hc_review_coverage_gap` changed-set, MUST be
computed from **`HC_BASE_ORIG`**, not the advanced `HC_BASE`. Reason: the fix
must include an **interior own-commit that sits between `HC_BASE_ORIG` and the
advanced `HC_BASE`** (`base → [your A] → [peer X] → [your B]` — `hc__resolve_
session_base` breaks at `A`, so `HC_BASE == HC_BASE_ORIG` here; but
`base → [peer X] → [your A] → [peer Y] → [your B]` advances `HC_BASE` to `X` and
`A` is then *below* `HC_BASE`).

Consequence for the **attested-log chain-walk** in `hc_review_coverage_gap`
(`harness-common.sh` ~lines 1290-1320): it currently admits prior review-logs by
`is-ancestor <log> <head>` **AND NOT** `is-ancestor <log> <base>`, with `<base>`
= the value passed by the caller (today `HC_BASE`). If the changed-set widens to
`HC_BASE_ORIG` but the chain-walk keeps filtering against `HC_BASE`, an interior
own-commit's own review-log (which *is* an ancestor of `HC_BASE`) gets filtered
**out** of the chain while its files are now **demanded** by the widened changed
set → spurious coverage gap, blocking a legitimately-reviewed file.

**Fix:** when the ledger path is taken, pass `HC_BASE_ORIG` as the chain-walk
`<base>` too, so the changed-set and the chain-walk share one lower bound. The
`done-write-state.sh:315` / `done-gate.sh` call sites must pass `HC_BASE_ORIG`
(available: `hc_resolve` sets it) alongside `HC_BASE` — see consumer change 4.

### New helper — `hc_session_changeset_commits`

`scripts/harness-common.sh`, next to `hc__session_authored_count`.

```
# hc_session_changeset_commits <orig_base> <head> <session_id> [proj]
#
# Emits, one SHA per line oldest→newest, the commits in <orig_base>..<head> that
# hc__commit_session_authored deems positively this session's own work (ledger
# membership when the ledger is engaged; committer-email otherwise). This is the
# SET the DoD review must cover in session mode — as opposed to the contiguous
# <base>..<head> range, which wrongly includes interior foreign commits (peer
# sessions sharing the git identity).
#
# Prints nothing (rc 0) when: empty orig_base, git failure, empty range, or no
# commit passes the predicate. Callers treat empty output as "not engaged -> use
# the point-base path". Mirrors hc__session_authored_count's structure exactly,
# emitting SHAs instead of a count.
```

```sh
hc_session_changeset_commits() {
  local orig_base="$1" head="$2" session_id="$3"
  local proj="${4:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  [ -z "$orig_base" ] && return 0
  local revs c
  revs=$(git -C "$proj" rev-list --reverse "$orig_base..$head" 2>/dev/null) || return 0
  [ -z "$revs" ] && return 0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    hc__commit_session_authored "$c" "$session_id" && printf '%s\n' "$c"
  done <<EOF
$revs
EOF
  return 0
}
```

Notes:
- Bounded by `orig_base..head` ancestry, so a stale ledger line for an
  amended/rebased-away commit no longer reachable from `head` simply never
  appears in `revs`.
- Takes `orig_base` explicitly (not read from a file) so the caller controls the
  lower bound and the base-consistency requirement above is enforced at the call
  site, visibly.

### Changed-file set — `hc_session_changeset_files`

```
# hc_session_changeset_files <orig_base> <head> <session_id> [proj]
#
# Union (sorted -u) of the per-commit changed paths over every SHA from
# hc_session_changeset_commits. The paths the DoD review must cover when the
# ledger path is taken. Empty output -> not engaged (caller uses point-base).
```

```sh
hc_session_changeset_files() {
  local orig_base="$1" head="$2" session_id="$3"
  local proj="${4:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local commits c out=""
  commits=$(hc_session_changeset_commits "$orig_base" "$head" "$session_id" "$proj")
  [ -z "$commits" ] && return 0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    # Parentless (root) commit: `<c>^` errors. Use diff-tree against the empty
    # tree via --root so the initial commit's full file set is still emitted.
    local paths
    if git -C "$proj" rev-parse -q --verify "${c}^" >/dev/null 2>&1; then
      paths=$(git -C "$proj" diff --name-only "${c}^" "$c" 2>/dev/null)
    else
      paths=$(git -C "$proj" diff-tree --no-commit-id --name-only -r --root "$c" 2>/dev/null)
    fi
    out="${out:+$out
}${paths}"
  done <<EOF
$commits
EOF
  printf '%s\n' "$out" | grep -v '^$' | sort -u
  return 0
}
```

Merge commits: `git diff --name-only <c>^ <c>` is first-parent; acceptable —
harness convention is linear history on `main`, and a merge the session itself
performed is in its ledger and its first-parent diff is the right scope.

---

## Consumer changes

### 1. `hc_review_coverage_gap` (`harness-common.sh:1238`)

Signature today: `hc_review_coverage_gap <log> <base> <head> [proj] [extra] [chain]`.

Change:

1. **Add `<orig_base>` as a 7th TRAILING optional param** —
   `hc_review_coverage_gap <log> <base> <head> [proj] [extra] [chain] [orig_base]`.
   Trailing, not positional-insert, so **no existing call site needs
   arg-shifting**. There are **three** production call sites; only the two below
   pass the new arg:
   - `done-write-state.sh:315` → pass `$HC_BASE_ORIG` (7th).
   - `done-gate.sh:722` → pass `$HC_BASE_ORIG` (7th).
   - `harness-common.sh:2023` inside `hc_done_state_blocked` (reached from
     `finish-worktree.sh:172`, `run-task.sh:321`, and the Stop-hook path at
     `harness-common.sh:2209`) → **left untouched**. `orig_base` defaults empty
     → the range-diff path, i.e. exactly today's behaviour. This is correct:
     task-mode callers have `HC_BASE_ORIG == HC_BASE` (nothing to gain), and the
     Stop-hook path reads a review-log that `/done` already wrote with the
     correctly-scoped `files_reviewed` — the gap check there only re-validates
     coverage against the current tree, which the ledger-scoped log already
     satisfies.
2. Compute `changed` via the ledger set first, falling back to the range —
   **preserving the existing git-failure SKIP on both paths**:

```sh
local changed=""
if hc_has_fn hc_session_changeset_files && [ -n "${HC_SESSION_ID:-}" ] && [ -n "$orig_base" ]; then
  changed=$(hc_session_changeset_files "$orig_base" "$head" "$HC_SESSION_ID" "$proj")
fi
if [ -z "$changed" ]; then
  # unchanged from today (harness-common.sh:1262): git failure here -> SKIP.
  changed=$(git -C "$proj" diff --name-only "$base" "$head" 2>/dev/null) \
    || { printf 'SKIP'; return 0; }
fi
# From here down: existing logic unchanged. An EMPTY changed set is still
# "nothing to cover -> PASS" (harness-common.sh ~:1268) whether it came from an
# empty ledger-union (all session commits were empty/no-op) or an empty range.
```

   Note the empty-union case is now explicitly *fine*: if every session-authored
   commit in range changed zero files, `changed=""` and coverage is trivially
   satisfied — same as an empty range. It does **not** fall through to the range
   diff (that would re-introduce interior foreign files).

3. **Chain-walk base:** in the ledger path, the chain-walk's `!is-ancestor
   <log> <base>` filter must use `<orig_base>`, not `<base>` — see
   "base-consistency requirement" above. Concretely: bind a local
   `chain_base="${orig_base:-$base}"` and use it in the two `merge-base
   --is-ancestor` calls of the chain-walk loop.

### 2. `HC_SESSION_ID` — do NOT touch `hc_resolve`

`HC_SESSION_ID` is **already a live global**, set manually at exactly one site:
`done-gate.sh:478` (`HC_SESSION_ID="$SESSION_ID"`, comment at `:469` — lets
`hc_changeset_summary` find the baseline mtime), and read by `hc_changeset_
summary` (`harness-common.sh:1545`).

Adding `HC_SESSION_ID="$session_id"` to `hc_resolve`'s reset block would set it
in **every** caller — including `run-task.sh:310` (passes `$TASK_ID`) and
`finish-worktree.sh:103` (passes the literal string `"finish-worktree"`),
poisoning the global for `hc_changeset_summary` in those paths.

**Instead:** mirror `done-gate.sh` — `done-write-state.sh` must set
`HC_SESSION_ID="$SESSION_ID"` explicitly after its `hc_resolve` call (it already
resolves `SESSION_ID` locally at `:55-65`; it just never exports it as the
global). One line, same pattern as `done-gate.sh:478`. No change to the shared
resolver.

### 3. `agents/dod-reviewer.md`

Round-1 input currently: `<base>` + "Review `git diff <base> <head>` in full."

- New optional input line `<commits>` — newline-separated SHAs (oldest→newest)
  constituting this session's changeset. When present, round 1 reviews
  `git diff <c>^ <c>` per listed commit (root commit: `git show --name-only` /
  `diff-tree --root`), union is the changeset; `files_reviewed` attests that
  union.
- Absent (ledger not engaged, or task mode) → exactly today's `git diff <base>
  <head>`.
- Round 2 (delta-scoped) unchanged — `git diff <prevHEAD> <head>`.

`files_reviewed` attestation rule (line 74+) gains: "When given a `<commits>`
list, `files_reviewed ⊇ ⋃ (git diff --name-only <c>^ <c>)` over the list."

### 4. `skills/done/dod-protocol.md`

- ~line 107 ("scope everything to `git diff <base> HEAD`"): replace with —
  "resolve the changeset base **and** `HC_BASE_ORIG`. When any commit in
  `HC_BASE_ORIG..HEAD` is session-authored (`hc_session_changeset_commits`
  non-empty), scope the review to that commit set (`git diff <c>^ <c>` per
  commit, union); otherwise `git diff <base> HEAD`."
- line ~18 ("agents still race"): note same-identity parallel sessions on shared
  main are now scoped apart by per-commit session-authorship, not just base
  point.
- **Step 5 reviewer dispatch** (`dod-protocol.md` ~lines 238-263 — "spawn the
  shipped reviewer agent", "Pass the agent only: `<base>`, `<head>`,
  `min_review_level`, and the mode"): add the `<commits>` list to the passed
  inputs when `hc_session_changeset_commits` is non-empty.

### 5. `done-gate.sh` / `done-write-state.sh` call sites

- `done-write-state.sh:315` — `hc_review_coverage_gap "$REVIEW_LOG" "$HC_BASE"
  "$VERIFIED_SHA" "$PROJECT_DIR" "$EXTRA_ADMIT" "$CHAIN_ADMIT"`: append
  `"$HC_BASE_ORIG"` as the 7th arg, and add the `HC_SESSION_ID="$SESSION_ID"`
  line (consumer change 2).
- `done-gate.sh:722` — append `"$HC_BASE_ORIG"` as the 7th arg. `HC_SESSION_ID`
  already set at `:478`.
- `harness-common.sh:2023` (`hc_done_state_blocked`) — **not touched**; see
  consumer change 1, item 1.
- `base_sha` written into review-log/done-state (`done-write-state.sh:366`) stays
  `HC_BASE` (the advanced point base) — still a valid lower bound for the gate's
  HEAD-keyed evidence check and anchor-recovery. The ledger set is a *scoping*
  refinement, not a persisted anchor. **No schema change.**

---

## Test — `tests/test-gate.sh`

New chunk: **interior foreign commit excluded from session-mode DoD scope.**

Setup (extends the ledger fixtures already in `tests/test-commit-ledger.sh`):
1. Init repo, commit `C0`. Record `C0` as `baselines/<sid>.sha` → `HC_BASE_ORIG`.
2. Own commit `A` touching `a.txt` — append `A` to `baselines/<sid>.own-commits`.
3. **Peer** commit `X` touching `x.txt` — NOT appended.
4. Own commit `B` touching `b.txt` — append `B`.
   History: `C0 → A → X → B` (HEAD).

Assertions:
- `hc_session_changeset_commits C0 HEAD <sid>` emits exactly `A\nB` (not `X`).
- `hc_session_changeset_files C0 HEAD <sid>` = `a.txt\nb.txt` — **not** `x.txt`.
- `hc_review_coverage_gap` (ledger path) with a review-log attesting `a.txt` +
  `b.txt` returns empty (PASS) — `x.txt` not demanded.
- **Interior-own-before-advanced-base variant:** history
  `C0 → X → A → Y → B`, ledger `{A, B}`. `hc__resolve_session_base` advances
  `HC_BASE` to `X`; `HC_BASE_ORIG` stays `C0`. Assert
  `hc_session_changeset_commits C0 HEAD <sid>` still emits `A\nB`, and the
  chain-walk (fed `HC_BASE_ORIG`) does **not** drop `A`'s review-log →
  no spurious gap for `a.txt`.
- **Empty-union:** own commits `A`, `B` are both empty (`--allow-empty`).
  `hc_session_changeset_files` → empty → `hc_review_coverage_gap` PASSes and does
  **not** fall through to the range diff (assert `x.txt` still not demanded).
- **Root commit:** `<sid>` owns the initial commit `C0` itself.
  `hc_session_changeset_files` emits `C0`'s full file set (no `<c>^` error).
- Control — ledger **absent**: `hc_review_coverage_gap` still demands `x.txt`
  (point-base behaviour preserved).
- Control — ledger **empty** (`-f`, 0 bytes): same as absent
  (`hc__commit_session_authored` degrades to email-only).
- **Git-failure SKIP preserved:** a bogus `<base>` on the range path still
  yields `SKIP`, not a block.

Also pin (unchanged behaviour): `hc__resolve_session_base` still `break`s at the
first ledgered commit — this spec adds a set path, it does not alter the loop.

---

## Non-goals

- No cross-session locking, claim files, or coordination channel. Per-commit
  session-authorship is sufficient and needs no communication.
- No change to task mode.
- No change to the working-tree (`.dirty`) path.
- No change to `hc_resolve` (see consumer change 2).
- No new persisted anchor or review-log field.

---

## Touch list

| File | Change |
|---|---|
| `scripts/harness-common.sh` | + `hc_session_changeset_commits`, + `hc_session_changeset_files` (both reuse `hc__commit_session_authored`); `hc_review_coverage_gap` gains a **7th trailing** `[orig_base]` param, prefers the ledger set, keeps git-failure SKIP on both paths, and uses `orig_base` for the chain-walk filter. `hc_done_state_blocked`'s call at `:2023` is left as-is (defaults empty → today's behaviour) |
| `scripts/done-write-state.sh` | set `HC_SESSION_ID="$SESSION_ID"` after `hc_resolve` (mirror `done-gate.sh:478`); append `$HC_BASE_ORIG` (7th arg) to `hc_review_coverage_gap` |
| `scripts/done-gate.sh` | append `$HC_BASE_ORIG` (7th arg) to `hc_review_coverage_gap` at `:722` |
| `agents/dod-reviewer.md` | round-1 accepts optional `<commits>` list; `files_reviewed` attestation bullet; root-commit diff note |
| `skills/done/dod-protocol.md` | scope wording (~line 107), Step 5 dispatch (~lines 238-263) passes `<commits>`, race caveat (~line 18) |
| `tests/test-gate.sh` | + interior-foreign-commit chunk: base-order variant, empty-union, root-commit, absent/empty-ledger controls, git-failure SKIP |

**NOT touched:** `scripts/harness-common.sh` `hc_resolve` (the shared resolver
stays as-is).
