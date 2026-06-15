#!/usr/bin/env bash
# TaskCompleted — completeness gate. Before a task flips to "completed", verify the
# deliverables it declared in tasks.json actually exist. exit 2 rolls the completion back.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-.}"
input=$(cat)

# Claude Code passes the task being completed; adapt the jq path to your task payload.
task_id=$(jq -r '.task.id // .tool_input.id // empty' <<<"$input")
[ -z "$task_id" ] && exit 0
[ -f tasks.json ] || exit 0

deliverables=$(jq -r --arg id "$task_id" '.tasks[] | select(.id==$id) | (.deliverables // [])[]' tasks.json 2>/dev/null || true)
[ -z "$deliverables" ] && exit 0

missing=""
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -e "$f" ] || missing="${missing}\n  - ${f}"
done <<<"$deliverables"

if [ -n "$missing" ]; then
  echo -e "Task ${task_id} is not complete. Declared deliverables missing:${missing}" >&2
  exit 2
fi
exit 0
