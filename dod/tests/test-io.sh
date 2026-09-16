#!/bin/bash
#
# Tests for dod/lib/io.sh: dod_hook_read, dod_block, dod_release,
# dod_fail_open, dod_log.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/io.sh"

echo "== io.sh =="

# --- dod_hook_read ------------------------------------------------------
PAYLOAD='{"session_id":"sid-1","cwd":"/tmp/x","prompt_id":"p1","stop_hook_active":true}'
dod_hook_read <<<"$PAYLOAD"
eq "hook_read session_id" "sid-1" "$DOD_HOOK_SESSION_ID"
eq "hook_read cwd" "/tmp/x" "$DOD_HOOK_CWD"
eq "hook_read prompt_id" "p1" "$DOD_HOOK_PROMPT_ID"
eq "hook_read stop_hook_active" "true" "$DOD_HOOK_STOP_ACTIVE"

# degrade to defaults on garbage input, never crash
dod_hook_read <<<"not json"
eq "hook_read degrades session_id on garbage" "" "$DOD_HOOK_SESSION_ID"
eq "hook_read degrades stop_hook_active on garbage" "false" "$DOD_HOOK_STOP_ACTIVE"

dod_hook_read </dev/null
eq "hook_read degrades on empty stdin" "" "$DOD_HOOK_SESSION_ID"

# --- dod_block ------------------------------------------------------------
OUT=$(dod_block "reason text here")
COUNT=$(printf '%s' "$OUT" | jq -s 'length' 2>/dev/null)
eq "dod_block emits exactly one JSON object" "1" "$COUNT"
DECISION=$(printf '%s' "$OUT" | jq -r '.decision' 2>/dev/null)
eq "dod_block decision field" "block" "$DECISION"
REASON=$(printf '%s' "$OUT" | jq -r '.reason' 2>/dev/null)
eq "dod_block reason field" "reason text here" "$REASON"

# --- dod_release ------------------------------------------------------------
OUT2=$(dod_release)
eq "dod_release emits empty stdout" "" "$OUT2"

# --- dod_fail_open ----------------------------------------------------------
ERRLOG=$(dod__test_mktemp_d)/errors.log
OUT3=$(dod_fail_open "$ERRLOG" "cause of failure" 2>&1 1>/dev/null)
case "$OUT3" in
  *"cause of failure"*) ok "dod_fail_open stderr mentions cause" ;;
  *) bad "dod_fail_open stderr mentions cause" "$OUT3" ;;
esac
if [ -f "$ERRLOG" ] && grep -q "cause of failure" "$ERRLOG" 2>/dev/null; then
  ok "dod_fail_open appends to errors.log"
else
  bad "dod_fail_open appends to errors.log" "missing"
fi

# --- dod_log: never writes stdout -------------------------------------------
LOGFILE=$(dod__test_mktemp_d)/dod.log
STDOUT_CAPTURE=$(dod_log "$LOGFILE" "hello world" 2>/dev/null)
eq "dod_log writes nothing to stdout" "" "$STDOUT_CAPTURE"
if [ -f "$LOGFILE" ] && grep -q "hello world" "$LOGFILE" 2>/dev/null; then
  ok "dod_log writes to the log file"
else
  bad "dod_log writes to the log file" "missing"
fi

echo
echo "io.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
