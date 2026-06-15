#!/usr/bin/env bash
# SubagentStop / Stop(implement). exit 2 = keep working. Delegates to shared check.
set -euo pipefail
HOME_DIR="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}}"
export REPO="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
if ! out=$("$HOME_DIR/checks/gate.sh" </dev/null 2>&1); then echo -e "$out" >&2; exit 2; fi
exit 0
