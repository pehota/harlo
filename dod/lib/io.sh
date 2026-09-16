#!/bin/bash
#
# dod/lib/io.sh — hook stdin parsing + the gate's output primitives.
#
# dod_hook_read: one `jq … | @tsv` pass instead of 8 separate forks (v1's
# harness-common.sh hc_read_hook_input pattern, collapsed).
# dod_block/dod_release: the A1 exit contract — block is JSON on stdout +
# exit 0, never `exit 2` (see docs/design-v2.md §6.2 amendment).
# dod_log: never writes stdout — hook stdout is reserved for dod_block's JSON.

IO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dod__has_jq() { command -v jq >/dev/null 2>&1; }

# dod_hook_read — reads a Claude Code hook JSON payload from stdin, sets:
#   DOD_HOOK_SESSION_ID, DOD_HOOK_CWD, DOD_HOOK_PROMPT_ID, DOD_HOOK_STOP_ACTIVE
# Degrades to empty/false defaults on missing jq or malformed JSON; never
# crashes the caller.
dod_hook_read() {
  local raw tsv
  raw=$(cat 2>/dev/null)
  DOD_HOOK_SESSION_ID=""
  DOD_HOOK_CWD=""
  DOD_HOOK_PROMPT_ID=""
  DOD_HOOK_STOP_ACTIVE="false"

  dod__has_jq || return 0

  tsv=$(printf '%s' "$raw" | jq -r \
    '[(.session_id // ""), (.cwd // ""), (.prompt_id // ""), ((.stop_hook_active // false) | tostring)] | @tsv' \
    2>/dev/null)
  [ -n "$tsv" ] || return 0

  IFS=$'\t' read -r DOD_HOOK_SESSION_ID DOD_HOOK_CWD DOD_HOOK_PROMPT_ID DOD_HOOK_STOP_ACTIVE <<<"$tsv"
  [ -n "$DOD_HOOK_STOP_ACTIVE" ] || DOD_HOOK_STOP_ACTIVE="false"
  return 0
}

# dod_block <reason> — prints exactly one JSON object to stdout. Caller exits 0.
dod_block() {
  local reason="$1"
  if dod__has_jq; then
    jq -n --arg r "$reason" '{"decision":"block","reason":$r}' 2>/dev/null
  else
    printf '{"decision":"block","reason":"%s"}\n' "$reason"
  fi
}

# dod_release — silent, empty stdout. Caller exits 0.
dod_release() { :; }

# dod_fail_open <errlog> <cause> — appends a timestamped line to errlog,
# prints one line to stderr. Caller exits 1.
dod_fail_open() {
  local errlog="$1" cause="$2" ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  mkdir -p "$(dirname "$errlog")" 2>/dev/null
  printf '%s dod gate error: %s\n' "$ts" "$cause" >>"$errlog" 2>/dev/null
  printf 'dod gate error: %s — see %s\n' "$cause" "$errlog" >&2
}

# dod_log <logfile> <message> — append-only, NEVER writes stdout. Hook stdout
# is reserved exclusively for dod_block's JSON.
dod_log() {
  local logfile="$1" message="$2" ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  mkdir -p "$(dirname "$logfile")" 2>/dev/null
  printf '%s %s\n' "$ts" "$message" >>"$logfile" 2>/dev/null
}
