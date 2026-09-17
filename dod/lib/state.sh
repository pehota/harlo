#!/bin/bash
#
# dod/lib/state.sh — sole owner of state.json (N6).
#
# Nothing outside this file may `jq` into state.json. Holds the claim latch,
# round counter and escalation flag the gate's decision tree reads and
# (only it) mutates.
#
# Phase 1 fields: latched, round, escalation, last_failed_diff_hash.
# Phase 2 adds edits[] (track.sh, this file) additively — cache{}/worktree/
# errors_unacknowledged still land with their own consumers.

STATE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dod__has_jq() { command -v jq >/dev/null 2>&1; }

# state_write <path> — (re)writes defaults. Used both to initialise and,
# combined with the mutators below, to persist changes.
state_write() {
  local path="$1"
  dod__has_jq || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null
  jq -n '{
    latched: false,
    round: 0,
    escalation: "none",
    last_failed_diff_hash: null,
    edits: []
  }' > "$path" 2>/dev/null
}

# state_read <path> — sets STATE_* globals. Returns 1 on missing/malformed/
# non-object JSON, without setting stale globals.
state_read() {
  local path="$1"
  STATE_LATCHED=""
  STATE_ROUND=""
  STATE_ESCALATION=""
  STATE_LAST_FAILED_DIFF_HASH=""
  STATE_EDITS="[]"

  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e 'type == "object"' "$path" >/dev/null 2>&1 || return 1

  STATE_LATCHED=$(jq -r '.latched // false' "$path" 2>/dev/null)
  STATE_ROUND=$(jq -r '.round // 0' "$path" 2>/dev/null)
  STATE_ESCALATION=$(jq -r '.escalation // "none"' "$path" 2>/dev/null)
  STATE_LAST_FAILED_DIFF_HASH=$(jq -r '.last_failed_diff_hash // ""' "$path" 2>/dev/null)
  STATE_EDITS=$(jq -c '.edits // []' "$path" 2>/dev/null)
  [ -n "$STATE_EDITS" ] || STATE_EDITS="[]"
  return 0
}

# state__mutate <path> <jq_filter> — read-modify-write via a jq filter,
# initialising defaults first if the file doesn't exist yet.
state__mutate() {
  local path="$1" filter="$2" tmp
  [ -f "$path" ] || state_write "$path"
  dod__has_jq || return 1
  tmp="${path}.tmp.$$"
  jq "$filter" "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}

state_arm_latch() { state__mutate "$1" '.latched = true'; }

state_bump_round() { state__mutate "$1" '.round = ((.round // 0) + 1)'; }

state_set_escalation() {
  local path="$1" value="$2" tmp
  [ -f "$path" ] || state_write "$path"
  dod__has_jq || return 1
  tmp="${path}.tmp.$$"
  jq --arg v "$value" '.escalation = $v' "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}

state_set_last_failed_diff_hash() {
  local path="$1" hash="$2" tmp
  [ -f "$path" ] || state_write "$path"
  dod__has_jq || return 1
  tmp="${path}.tmp.$$"
  jq --arg h "$hash" '.last_failed_diff_hash = $h' "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}

# state_log_edit <path> <prompt_id> <file_path> — appends one edit record
# (§6.5). Sole writer of state.edits — track.sh's PostToolUse hook, never the
# gate. Used by gate.sh branch 5 (D8) to detect "edited this prompt without a
# latch" without relying on the agent to call dod-claim.sh.
state_log_edit() {
  local path="$1" prompt_id="$2" file="$3" ts tmp
  [ -f "$path" ] || state_write "$path"
  dod__has_jq || return 1
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  tmp="${path}.tmp.$$"
  jq --arg p "$prompt_id" --arg f "$file" --arg t "$ts" \
    '.edits += [{prompt_id: $p, path: $f, ts: $t}]' \
    "$path" >"$tmp" 2>/dev/null && mv -f "$tmp" "$path" 2>/dev/null
}

# state_has_edit_for_prompt <path> <prompt_id> — 0 if state.edits contains
# any record for prompt_id, 1 otherwise (including missing/malformed state).
state_has_edit_for_prompt() {
  local path="$1" prompt_id="$2"
  [ -f "$path" ] || return 1
  dod__has_jq || return 1
  jq -e --arg p "$prompt_id" '(.edits // []) | any(.[]; .prompt_id == $p)' \
    "$path" >/dev/null 2>&1
}
