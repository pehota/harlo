#!/bin/bash
#
# dod/scripts/dod-claim.sh — arms the claim latch for a task.
#
# Usage: dod-claim.sh <repo_dir> <task_key>
# Sole writer of state.latched=true outside the gate itself. Skills call this
# when the agent declares the task done.

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$SCRIPT_ROOT/lib/state.sh"

REPO_DIR="${1:?usage: dod-claim.sh <repo_dir> <task_key>}"
TASK_KEY="${2:?usage: dod-claim.sh <repo_dir> <task_key>}"

STATE_FILE="$REPO_DIR/.dod/$TASK_KEY/state.json"
state_arm_latch "$STATE_FILE"
