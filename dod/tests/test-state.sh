#!/bin/bash
#
# Tests for dod/lib/state.sh: state_read/write + mutators.

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/test-helpers.sh"
. "$DIR0/../lib/state.sh"

echo "== state.sh =="

REPO=$(dod__test_make_repo)
SFILE="$REPO/.dod/main/state.json"

# --- write defaults + round trip ---------------------------------------------
state_write "$SFILE"
if [ -f "$SFILE" ]; then
  ok "state_write creates the file"
else
  bad "state_write creates the file" "missing"
fi

state_read "$SFILE"
eq "default latched" "false" "$STATE_LATCHED"
eq "default round" "0" "$STATE_ROUND"
eq "default escalation" "none" "$STATE_ESCALATION"
eq "default state" "idle" "$STATE_STATE"

# --- malformed input rejected -------------------------------------------------
BADFILE="$REPO/.dod/main/bad-state.json"
printf 'nope not json' > "$BADFILE"
if state_read "$BADFILE"; then
  bad "state_read rejects malformed JSON" "accepted"
else
  ok "state_read rejects malformed JSON"
fi

# --- N6: state has no requirements array, so validate a plain shape check ----
NOTOBJ="$REPO/.dod/main/notobj-state.json"
printf '[1,2,3]' > "$NOTOBJ"
if state_read "$NOTOBJ"; then
  bad "state_read rejects a non-object JSON value" "accepted"
else
  ok "state_read rejects a non-object JSON value"
fi

# --- mutators ------------------------------------------------------------
state_write "$SFILE"
state_arm_latch "$SFILE"
state_read "$SFILE"
eq "state_arm_latch sets latched" "true" "$STATE_LATCHED"

state_bump_round "$SFILE"
state_read "$SFILE"
eq "state_bump_round increments round" "1" "$STATE_ROUND"
state_bump_round "$SFILE"
state_read "$SFILE"
eq "state_bump_round increments round again" "2" "$STATE_ROUND"

# --- state_log_edit / state_has_edit_for_prompt -------------------------------
state_write "$SFILE"
state_log_edit "$SFILE" "p1" "src/a.ts"
state_read "$SFILE"
COUNT=$(printf '%s' "$STATE_EDITS" | jq 'length' 2>/dev/null)
eq "state_log_edit appends one record" "1" "$COUNT"

state_log_edit "$SFILE" "p1" "src/b.ts"
state_read "$SFILE"
COUNT=$(printf '%s' "$STATE_EDITS" | jq 'length' 2>/dev/null)
eq "state_log_edit appends a second record" "2" "$COUNT"

if state_has_edit_for_prompt "$SFILE" "p1"; then
  ok "state_has_edit_for_prompt true for logged prompt_id"
else
  bad "state_has_edit_for_prompt true for logged prompt_id" "false"
fi

# --- state_log_edit dedupe keeps the FRESHEST record, not the first --------
state_write "$SFILE"
state__log_edit_body "$SFILE" "p1" "src/a.ts" 2>/dev/null || true
jq '.edits[0].ts = "2000-01-01T00:00:00Z"' "$SFILE" > "$SFILE.tmp" && mv "$SFILE.tmp" "$SFILE"
state_log_edit "$SFILE" "p1" "src/a.ts"
state_read "$SFILE"
COUNT=$(printf '%s' "$STATE_EDITS" | jq 'length' 2>/dev/null)
eq "state_log_edit dedupe: repeat (prompt_id,path) collapses to one" "1" "$COUNT"
KEPT_TS=$(printf '%s' "$STATE_EDITS" | jq -r '.[0].ts' 2>/dev/null)
if [ "$KEPT_TS" != "2000-01-01T00:00:00Z" ]; then
  ok "state_log_edit dedupe: kept the fresh record, not the backdated one"
else
  bad "state_log_edit dedupe: kept the fresh record, not the backdated one" "$KEPT_TS"
fi
if state_has_edit_for_prompt "$SFILE" "p2"; then
  bad "state_has_edit_for_prompt false for unlogged prompt_id" "true"
else
  ok "state_has_edit_for_prompt false for unlogged prompt_id"
fi

# --- state_set_state ----------------------------------------------------------
state_write "$SFILE"
state_set_state "$SFILE" "verifying"
state_read "$SFILE"
eq "state_set_state sets verifying" "verifying" "$STATE_STATE"

state_set_state "$SFILE" "idle"
state_read "$SFILE"
eq "state_set_state sets idle" "idle" "$STATE_STATE"

if state_set_state "$SFILE" "bogus"; then
  bad "state_set_state rejects an invalid value" "accepted"
else
  ok "state_set_state rejects an invalid value"
fi
state_read "$SFILE"
eq "state_set_state: rejected write leaves state unchanged" "idle" "$STATE_STATE"

# --- concurrent state_log_edit calls: no lost writes under flock -------------
if command -v flock >/dev/null 2>&1; then
  state_write "$SFILE"
  for i in $(seq 1 20); do
    state_log_edit "$SFILE" "p$i" "file$i.txt" &
  done
  wait
  state_read "$SFILE"
  COUNT=$(printf '%s' "$STATE_EDITS" | jq 'length' 2>/dev/null)
  eq "concurrent state_log_edit: no lost writes" "20" "$COUNT"
else
  echo "  SKIP: flock not available, concurrency test skipped"
fi

# --- cache: get/set + miss/hit --------------------------------------------
state_write "$SFILE"
if state_cache_get "$SFILE" "d1" "npm test" >/dev/null 2>&1; then
  bad "state_cache_get misses on empty cache" "hit"
else
  ok "state_cache_get misses on empty cache"
fi

state_cache_set "$SFILE" "d1" "npm test" "pass"
GOT=$(state_cache_get "$SFILE" "d1" "npm test")
eq "state_cache_get hits after state_cache_set" "pass" "$GOT"

if state_cache_get "$SFILE" "d2" "npm test" >/dev/null 2>&1; then
  bad "state_cache_get misses on a different diff_hash" "hit"
else
  ok "state_cache_get misses on a different diff_hash"
fi

if state_cache_get "$SFILE" "d1" "npm run lint" >/dev/null 2>&1; then
  bad "state_cache_get misses on a different command" "hit"
else
  ok "state_cache_get misses on a different command"
fi

state_cache_set "$SFILE" "d1" "npm test" "fail"
GOT=$(state_cache_get "$SFILE" "d1" "npm test")
eq "state_cache_set overwrites an existing entry" "fail" "$GOT"

# --- cache: key hashing avoids ':' collisions --------------------------------
state_write "$SFILE"
state_cache_set "$SFILE" "abc" "echo hi:there" "pass"
GOT=$(state_cache_get "$SFILE" "abc" "echo hi:there")
eq "state_cache_get round-trips a command containing ':'" "pass" "$GOT"

echo
echo "state.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
