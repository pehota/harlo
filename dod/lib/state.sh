#!/bin/bash
#
# dod/lib/state.sh — sole owner of state.json (N6).
#
# Nothing outside this file may `jq` into state.json. Holds the claim latch,
# round counter and escalation flag the gate's decision tree reads and
# (only it) mutates.
#
# Phase 1 fields: latched, round, escalation, last_failed_diff_hash.
# Phase 2 adds edits[] (track.sh), state ("idle"|"verifying", this file) and
# cache{} (this file, Phase 2 item 6) additively — worktree/
# errors_unacknowledged still land with their own consumers.
#
# `state` is WORDING-ONLY: gate.sh reads it to pick which block message to
# print, never to change the block/release decision itself (that stays
# governed by result.json's existence and diff-hash match, unchanged). No
# TTL/staleness guard — a crashed session can leave it stuck "verifying",
# but the only cost is a misleading-but-harmless "wait, it's running"
# message for at most one turn; the next /dod:verify call resets it fresh
# regardless of what it was. Deliberately not over-engineered (YAGNI).

STATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dod__has_jq() { command -v jq >/dev/null 2>&1; }

# state__locked <path> <body...> — runs body (a full read-modify-write) under
# an exclusive flock on "<path>.lock", so two concurrent writers (e.g. a
# subagent and the main loop each editing files, each firing their own
# track.sh) can't both read the same pre-write state and have the second
# `mv` silently clobber the first one's change. One lock acquisition per
# public function below, covering its whole init-if-missing + mutate body —
# never call another state_* function from inside a locked body, or the
# second flock on the same fd blocks forever (flock is not reentrant).
# Falls back to running body unlocked if flock isn't on PATH — same
# behaviour as before this existed, not a new failure mode.
state__locked() {
  local path="$1"; shift
  mkdir -p "$(dirname "$path")" 2>/dev/null
  if command -v flock >/dev/null 2>&1; then
    ( flock -x 200; "$@"; ) 200>"${path}.lock" 2>/dev/null
  else
    "$@"
  fi
}

state__write_body() {
  local path="$1"
  dod__has_jq || return 1
  jq -n '{
    latched: false,
    round: 0,
    escalation: "none",
    last_failed_diff_hash: null,
    edits: [],
    state: "idle",
    cache: {}
  }' > "$path" 2>/dev/null
}
# state_write <path> — (re)writes defaults. Used both to initialise and,
# combined with the mutators below, to persist changes.
state_write() { state__locked "$1" state__write_body "$1"; }

# state_read <path> — sets STATE_* globals. Returns 1 on missing/malformed/
# non-object JSON, without setting stale globals. Read-only: no lock needed.
state_read() {
  local path="$1"
  STATE_LATCHED=""
  STATE_ROUND=""
  STATE_ESCALATION=""
  STATE_LAST_FAILED_DIFF_HASH=""
  STATE_EDITS="[]"
  STATE_STATE="idle"
  STATE_CACHE="{}"

  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e 'type == "object"' "$path" >/dev/null 2>&1 || return 1

  STATE_LATCHED=$(jq -r '.latched // false' "$path" 2>/dev/null)
  STATE_ROUND=$(jq -r '.round // 0' "$path" 2>/dev/null)
  STATE_ESCALATION=$(jq -r '.escalation // "none"' "$path" 2>/dev/null)
  STATE_LAST_FAILED_DIFF_HASH=$(jq -r '.last_failed_diff_hash // ""' "$path" 2>/dev/null)
  STATE_EDITS=$(jq -c '.edits // []' "$path" 2>/dev/null)
  [ -n "$STATE_EDITS" ] || STATE_EDITS="[]"
  STATE_STATE=$(jq -r '.state // "idle"' "$path" 2>/dev/null)
  [ -n "$STATE_STATE" ] || STATE_STATE="idle"
  STATE_CACHE=$(jq -c '.cache // {}' "$path" 2>/dev/null)
  [ -n "$STATE_CACHE" ] || STATE_CACHE="{}"
  return 0
}

# state__mutate_body <path> <jq_filter> — init-if-missing + read-modify-write
# via a jq filter. Only ever called through state__locked.
state__mutate_body() {
  local path="$1" filter="$2" tmp
  [ -f "$path" ] || state__write_body "$path"
  dod__has_jq || return 1
  tmp="${path}.tmp.$$"
  jq "$filter" "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}
state__mutate() { state__locked "$1" state__mutate_body "$1" "$2"; }

state_arm_latch() { state__mutate "$1" '.latched = true'; }

state_bump_round() { state__mutate "$1" '.round = ((.round // 0) + 1)'; }

# state_set_state <path> <"idle"|"verifying"> — wording-only signal for
# gate.sh's block message (see header). /dod:verify sets "verifying" before
# doing anything else, and back to "idle" right after result_write succeeds.
state_set_state() {
  local path="$1" value="$2"
  case "$value" in idle|verifying) : ;; *) return 1 ;; esac
  state__mutate "$path" ".state = $(jq -n --arg v "$value" '$v')"
}

state_set_escalation() {
  local path="$1" value="$2"
  state__mutate "$path" ".escalation = $(jq -n --arg v "$value" '$v')"
}

state_set_last_failed_diff_hash() {
  local path="$1" hash="$2"
  state__mutate "$path" ".last_failed_diff_hash = $(jq -n --arg h "$hash" '$h')"
}

# state_log_edit <path> <prompt_id> <file_path> — appends one edit record
# (§6.5). Sole writer of state.edits — track.sh's PostToolUse hook, never the
# gate. Used by gate.sh branch 5 (D8) to detect "edited this prompt without a
# latch" without relying on the agent to call dod-claim.sh.
#
# Deduplicates on (prompt_id, path) and keeps only the last 200 entries: only
# membership ("was this prompt_id ever logged") is read back, never order or
# repeat count, so an unbounded append on a long session or a
# repeatedly-edited file would grow state.json for no observable behaviour
# change — just slower gate.sh reads on every Stop.
state__log_edit_body() {
  local path="$1" prompt_id="$2" file="$3" ts tmp
  [ -f "$path" ] || state__write_body "$path"
  dod__has_jq || return 1
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  tmp="${path}.tmp.$$"
  jq --arg p "$prompt_id" --arg f "$file" --arg t "$ts" \
    '.edits = (([{prompt_id: $p, path: $f, ts: $t}] + .edits)
                | unique_by([.prompt_id, .path])
                | .[0:200])' \
    "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}
state_log_edit() { state__locked "$1" state__log_edit_body "$1" "$2" "$3"; }

# state_has_edit_for_prompt <path> <prompt_id> — 0 if state.edits contains
# any record for prompt_id, 1 otherwise (including missing/malformed state).
# Read-only: no lock needed.
state_has_edit_for_prompt() {
  local path="$1" prompt_id="$2"
  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e --arg p "$prompt_id" '(.edits // []) | any(.[]; .prompt_id == $p)' \
    "$path" >/dev/null 2>&1
}

# state_cache_key <diff_hash> <cmd> — the cache map key, "<diff_hash>:<cmd_hash>".
# cmd is hashed (not stored raw) so a command containing ':' or other odd
# characters can't collide with the diff_hash delimiter; sha1 chosen only
# because it's already on every machine this runs on (git needs it), not for
# any cryptographic property.
state_cache_key() {
  local diff_hash="$1" cmd="$2" cmd_hash
  cmd_hash=$(printf '%s' "$cmd" | sha1sum 2>/dev/null | cut -d' ' -f1)
  [ -n "$cmd_hash" ] || cmd_hash=$(printf '%s' "$cmd" | cksum 2>/dev/null | cut -d' ' -f1)
  printf '%s:%s' "$diff_hash" "$cmd_hash"
}

# state_cache_get <path> <diff_hash> <cmd> — prints the cached verdict
# ("pass"/"fail") for this (diff_hash, cmd) pair, or nothing + return 1 on a
# miss. Read-only: no lock needed. Any change to the diff changes diff_hash,
# so the whole cache is invalidated for free — no explicit eviction on edit.
state_cache_get() {
  local path="$1" diff_hash="$2" cmd="$3" key verdict
  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  key=$(state_cache_key "$diff_hash" "$cmd")
  verdict=$(jq -r --arg k "$key" '(.cache // {})[$k] // empty' "$path" 2>/dev/null)
  [ -n "$verdict" ] || return 1
  printf '%s' "$verdict"
}

# state_cache_set <path> <diff_hash> <cmd> <verdict> — records a check's
# verdict. Caps the map at 200 entries (oldest-inserted evicted first,
# jq object key order is insertion order) for the same reason edits[] is
# capped: only lookups are read back, never history, so unbounded growth
# would just slow every gate.sh/verify read for no behaviour change.
state__cache_set_body() {
  local path="$1" key="$2" verdict="$3" tmp
  [ -f "$path" ] || state__write_body "$path"
  dod__has_jq || return 1
  tmp="${path}.tmp.$$"
  jq --arg k "$key" --arg v "$verdict" \
    '.cache = (((.cache // {}) + {($k): $v})
                | to_entries | .[-200:] | from_entries)' \
    "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}
state_cache_set() {
  local path="$1" diff_hash="$2" cmd="$3" verdict="$4" key
  key=$(state_cache_key "$diff_hash" "$cmd")
  state__locked "$path" state__cache_set_body "$path" "$key" "$verdict"
}
