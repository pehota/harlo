#!/usr/bin/env bash
set -euo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${HARNESS_ROLE:-orchestrator}" in
  implement) exec "$D/gate-task.sh" ;;
  plan)
    REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
    if [ -f "$REPO/tasks.json" ] && jq -e '.tasks|length>0' "$REPO/tasks.json" >/dev/null 2>&1; then exit 0; fi
    echo "Planning must produce tasks.json with at least one task." >&2; exit 2 ;;
  *) exec "$D/gate-global.sh" ;;
esac
