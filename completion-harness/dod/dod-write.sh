#!/bin/bash
#
# Completion Harness — task-DoD walking skeleton: the writer.
#
#   dod-write.sh <path-to-input-json>     (or: pipe the JSON on stdin)
#
# Part of the dod/ skeleton (issue #11 / ADR-0001). Writes / amends
# .claude/.harness/task-dod/<task_key>.json — the CONTRACT for this task. Not a
# hook; invoked by the model (or, in the tests / headless trial, by a stand-in).
#
# APPEND-ONLY is enforced STRUCTURALLY here, because a schema cannot compare a
# write against the prior file (ADR-0001 "Trust the writer script … Rejected"
# note: the schema pins the shape, the writer pins the history):
#   - first write: input must be schema-valid, requirements non-empty, and carry
#     created_at + blast_radius. Written verbatim (normalised through jq).
#   - amend: every existing requirement's `text` must still be present in the
#     incoming payload, UNCHANGED. Dropping or softening one → REJECT, nonzero.
#     `blast_radius` and `created_at` are immutable → any change → REJECT.
#     Genuinely-new requirements (text not already on file) are appended in
#     order; the stored entries are preserved byte-for-byte.
#
# The file lives under .claude/.harness/ so writing it is arming-exempt.
#
# Exit: 0 on a successful write/amend (path printed to stdout). Nonzero + a
# one-line reason on stderr otherwise. No `set -e`; every jq/git call guarded.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

if [ -f "$PLUGIN_ROOT/scripts/harness-common.sh" ]; then
  . "$PLUGIN_ROOT/scripts/harness-common.sh" 2>/dev/null
fi

die() { printf 'dod-write: %s\n' "$1" >&2; exit "${2:-1}"; }

hc_has_jq || die "jq is required" 3
hc_has_fn hc_resolve || die "harness-common.sh did not load" 3

# --- read the input -------------------------------------------------------------
INPUT_SRC="${1:-}"
if [ -n "$INPUT_SRC" ]; then
  [ -f "$INPUT_SRC" ] && [ -r "$INPUT_SRC" ] || die "input file not found: $INPUT_SRC"
  PAYLOAD=$(cat "$INPUT_SRC" 2>/dev/null)
else
  PAYLOAD=$(cat 2>/dev/null)
fi
[ -n "$PAYLOAD" ] || die "empty input"
printf '%s' "$PAYLOAD" | jq . >/dev/null 2>&1 || die "input is not valid JSON"

# --- resolve identity --------------------------------------------------------
SESSION_ID=$(printf '%s' "$PAYLOAD" | jq -r '.__session_id // ""' 2>/dev/null)
# Fallback: the harness resolver needs a session id only in session mode; in
# task mode the branch is the key. Allow an env override for the tests.
[ -n "$SESSION_ID" ] || SESSION_ID="${DOD_SESSION_ID:-unknown-session}"
hc_resolve "$SESSION_ID" 2>/dev/null
[ -n "$HARNESS_DIR" ] || die "could not resolve HARNESS_DIR" 3
[ -n "$HC_TASK_KEY" ] || HC_TASK_KEY="session-${SESSION_ID}"

DOD_DIR="$HARNESS_DIR/task-dod"
DOD_FILE="$DOD_DIR/${HC_TASK_KEY}.json"
SCHEMA="$PLUGIN_ROOT/contracts/task-dod.schema.json"

# Strip any transport-only helper key before it is validated or stored.
PAYLOAD=$(printf '%s' "$PAYLOAD" | jq 'del(.__session_id)' 2>/dev/null)

# task_key in the file is authoritative from the resolver (issue: "use
# HC_TASK_KEY verbatim"); inject/overwrite it so the caller cannot mis-key.
PAYLOAD=$(printf '%s' "$PAYLOAD" | jq --arg k "$HC_TASK_KEY" '.task_key = $k' 2>/dev/null)

# --- schema gate (shape) ---------------------------------------------------
TMP_PAYLOAD=$(mktemp 2>/dev/null) || die "mktemp failed" 3
trap 'rm -f "$TMP_PAYLOAD"' EXIT
printf '%s' "$PAYLOAD" > "$TMP_PAYLOAD"
if hc_has_fn hc_validate; then
  ERR=$(hc_validate "$SCHEMA" "$TMP_PAYLOAD" 2>&1) || die "input fails task-dod.schema.json: $ERR"
else
  die "hc_validate unavailable" 3
fi

# requirements non-empty — a writer invariant the schema's keyword subset
# cannot express (no minItems).
REQ_COUNT=$(printf '%s' "$PAYLOAD" | jq '.requirements | length' 2>/dev/null)
case "$REQ_COUNT" in ''|0|*[!0-9]*) die "requirements[] must be non-empty" ;; esac

mkdir -p "$DOD_DIR" 2>/dev/null

# --- first write ---------------------------------------------------------------
if [ ! -f "$DOD_FILE" ]; then
  printf '%s' "$PAYLOAD" | jq -S . > "$DOD_FILE" 2>/dev/null || die "write failed"
  printf '%s\n' "$DOD_FILE"
  exit 0
fi

# --- amend: append-only merge -----------------------------------------------
EXISTING=$(cat "$DOD_FILE" 2>/dev/null)
printf '%s' "$EXISTING" | jq . >/dev/null 2>&1 || die "existing task-dod is corrupt: $DOD_FILE" 3

# immutables
OLD_CREATED=$(printf '%s' "$EXISTING" | jq -r '.created_at' 2>/dev/null)
NEW_CREATED=$(printf '%s' "$PAYLOAD"  | jq -r '.created_at' 2>/dev/null)
[ "$OLD_CREATED" = "$NEW_CREATED" ] || die "created_at is immutable after the first write"

OLD_BR=$(printf '%s' "$EXISTING" | jq -Sc '.blast_radius' 2>/dev/null)
NEW_BR=$(printf '%s' "$PAYLOAD"  | jq -Sc '.blast_radius' 2>/dev/null)
[ "$OLD_BR" = "$NEW_BR" ] || die "blast_radius is immutable after the first write"

# every existing requirement text must reappear VERBATIM in the payload
MISSING=$(jq -rn \
  --slurpfile old <(printf '%s' "$EXISTING") \
  --slurpfile new <(printf '%s' "$PAYLOAD") '
  ($new[0].requirements | map(.text)) as $newtexts
  | $old[0].requirements[]
  | select(.text as $t | ($newtexts | index($t)) | not)
  | .text
' 2>/dev/null)
[ -z "$MISSING" ] || die "append-only violation: existing requirement dropped or reworded: ${MISSING}"

# merge: keep existing entries byte-for-byte, append payload entries whose text
# is new (dedup by text).
MERGED=$(jq -n \
  --slurpfile old <(printf '%s' "$EXISTING") \
  --slurpfile new <(printf '%s' "$PAYLOAD") '
  ($old[0].requirements | map(.text)) as $oldtexts
  | ($new[0].requirements | map(select(.text as $t | ($oldtexts | index($t)) | not))) as $added
  | $old[0] | .requirements = ($old[0].requirements + $added)
' 2>/dev/null)
[ -n "$MERGED" ] || die "merge failed"

printf '%s' "$MERGED" | jq -S . > "$DOD_FILE" 2>/dev/null || die "write failed"
printf '%s\n' "$DOD_FILE"
exit 0
