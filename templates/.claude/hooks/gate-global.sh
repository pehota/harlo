#!/usr/bin/env bash
# Stop(orchestrator). Shared full gate + Claude-Code kill-criterion.
set -euo pipefail
HOME_DIR="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}}"
export REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
state="$REPO/.claude/state"; mkdir -p "$state"; counter="$state/stop-retries"
max="${HARNESS_MAX_STOP_RETRIES:-5}"; n=$(cat "$counter" 2>/dev/null || echo 0)
if [ "$n" -ge "$max" ]; then echo 0 > "$counter"
  jq -nc '{continue:false, stopReason:"Global gate failed '"$max"'x consecutively. Halting for human review."}'; exit 0
fi
if out=$("$HOME_DIR/checks/gate-full.sh" </dev/null 2>&1); then echo 0 > "$counter"; exit 0
else echo $((n+1)) > "$counter"; echo -e "$out" >&2; exit 2; fi
