#!/bin/bash
#
# dod/scripts/dod-claim.sh — arms the claim latch for a task.
#
# Usage: dod-claim.sh <repo_dir> <task_key>
# repo_dir is the git top-level (callers pass dod_repo_root "$PWD"), the
# same root the gate keys .dod/ on. Records $CLAUDE_CODE_SESSION_ID (set in
# the Bash tool env) as the claiming session, so the gate scopes the latch
# to it; unset -> no session recorded, the latch claims in any session.
# Sole writer of state.latched=true outside the gate itself. Skills call this
# when the agent declares the task done.

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPT_ROOT/lib/state.sh"

REPO_DIR="${1:?usage: dod-claim.sh <repo_dir> <task_key>}"
TASK_KEY="${2:?usage: dod-claim.sh <repo_dir> <task_key>}"

STATE_FILE="$REPO_DIR/.dod/$TASK_KEY/state.json"
state_arm_latch "$STATE_FILE" "${CLAUDE_CODE_SESSION_ID:-}"
