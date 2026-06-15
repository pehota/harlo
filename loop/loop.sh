#!/usr/bin/env bash
# Agent-agnostic autonomous implementation loop. Owns iteration/budget/reset/PR.
# Verification = external gate (checks/gate.sh). No dependency on /goal, /loop, or hooks.
#
# Usage:
#   loop/loop.sh --init [--repo PATH]            analyze a repo and write .harness.json
#   loop/loop.sh [--repo PATH] [branch] [iters]  run the loop (default agent: $AGENT or claude)
set -euo pipefail
HARNESS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REPO=""; INIT=0; ARGS=()
while [ $# -gt 0 ]; do case "$1" in
  --init) INIT=1; shift ;;
  --repo) REPO="$2"; shift 2 ;;
  --repo=*) REPO="${1#*=}"; shift ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) ARGS+=("$1"); shift ;;
esac; done
REPO="$(cd "${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" && pwd)"
export REPO HARNESS_HOME

if [ "$INIT" = 1 ]; then exec "$HARNESS_HOME/loop/init.sh"; fi

cd "$REPO"
[ -f "$REPO/.harness.json" ] || { echo "No .harness.json in $REPO — run: $0 --init"; exit 1; }

AGENT="${AGENT:-claude}"; ADAPTER="$HARNESS_HOME/loop/adapters/${AGENT}.sh"
[ -f "$ADAPTER" ] || { echo "No adapter '$AGENT' ($ADAPTER)."; exit 1; }
# shellcheck disable=SC1090
source "$ADAPTER"   # provides agent_run / agent_cost

BRANCH="${ARGS[0]:-loop/$(date -u +%Y%m%d-%H%M%S)}"
MAX_ITERS="${ARGS[1]:-${HARNESS_MAX_ITERS:-30}}"
DEADLINE_MIN="${HARNESS_DEADLINE_MIN:-480}"; MAX_TASK_RETRIES="${HARNESS_MAX_TASK_RETRIES:-3}"; BUDGET_USD="${HARNESS_BUDGET_USD:-0}"
state="$REPO/.claude/state"; mkdir -p "$state"; ERRLOG="$state/loop.err"; export ERRLOG
REVIEW=$(jq -r '.commands["code-review"] // empty' "$REPO/.harness.json" 2>/dev/null || true)
: > "$state/review.md"; rm -f "$state/mutation.log"
git rev-parse --verify "$BRANCH" >/dev/null 2>&1 || git switch -c "$BRANCH"; git switch "$BRANCH"
start=$(date +%s); total_cost=0

ready_task(){ jq -r '(.tasks|map(select(.status=="completed")|.id)) as $d
  | (.tasks[]|select(.status=="pending")|select((.dependsOn//[])-$d|length==0)|.id)' tasks.json | head -n1; }
set_status(){ t=$(mktemp); jq --arg i "$1" --arg s "$2" '(.tasks[]|select(.id==$i)).status=$s' tasks.json >"$t" && mv "$t" tasks.json; }
retries(){ cat "$state/retries-$1" 2>/dev/null || echo 0; }
bump(){ echo $(( $(retries "$1") + 1 )) > "$state/retries-$1"; }
over_budget(){ [ "$BUDGET_USD" != "0" ] && awk -v t="$total_cost" -v b="$BUDGET_USD" 'BEGIN{exit !(t>=b)}'; }
build_review_payload(){
  local id="$1" title acc files diff
  title=$(jq -r --arg i "$id" '.tasks[]|select(.id==$i)|.title // ""' tasks.json)
  acc=$(jq -r --arg i "$id" '.tasks[]|select(.id==$i)|(.acceptance // [])[]|"- "+.' tasks.json 2>/dev/null)
  files=$(git status --porcelain | sed 's/^...//')   # incl. untracked; reviewer can read them
  diff=$(git diff HEAD)
  printf '## TASK\n%s: %s\n\n## ACCEPTANCE CRITERIA\n%s\n\n## CHANGED FILES\n%s\n\n## DIFF\n%s\n' \
    "$id" "$title" "$acc" "$files" "$diff"
}

iter=0
while [ "$iter" -lt "$MAX_ITERS" ]; do
  (( ($(date +%s)-start)/60 >= DEADLINE_MIN )) && { echo "Wall-clock budget hit."; break; }
  over_budget && { echo "Cost budget \$$BUDGET_USD hit (spent \$$total_cost)."; break; }
  task=$(ready_task); [ -z "$task" ] && { echo "No ready tasks remaining."; break; }
  iter=$((iter+1)); set_status "$task" "in_progress"
  echo "=== iter $iter — $task ($(retries "$task")/$MAX_TASK_RETRIES) — spent \$$total_cost ==="

  prompt="Implement ONLY task '$task' from tasks.json. Stay inside its 'owns' file scope. Cover every \
'acceptance' item with a test that would fail on regression. Do not edit tasks.json or other tasks' files. \
Append a short REFLECTION.md entry."
  fb="$state/feedback-$task"
  [ -s "$fb" ] && prompt="$prompt

Your previous attempt FAILED verification. Fix exactly this, don't start over:
$(cat "$fb")"

  raw=$(agent_run "$prompt" 2>>"$ERRLOG" || true)
  c=$(printf '%s' "$raw" | agent_cost 2>/dev/null || echo 0); c=${c:-0}
  total_cost=$(awk -v a="$total_cost" -v b="$c" 'BEGIN{printf "%.4f", a+b}')

  if [ -z "$(git status --porcelain)" ]; then
    echo "No changes made (silent run)." > "$fb"; bump "$task"; echo "  ⨯ $task made no changes"
  elif "$HARNESS_HOME/checks/gate.sh" </dev/null 2>"$fb"; then
    review_rc=0; review_out=""
    if [ -n "$REVIEW" ]; then
      set +e; review_out=$(build_review_payload "$task" | eval "$REVIEW" 2>&1); review_rc=$?; set -e
      printf '%s' "$review_out" | grep -q 'CHANGES_REQUESTED' && review_rc=1
    fi
    if [ "$review_rc" -ne 0 ]; then
      { echo "Code review requested changes:"; echo "$review_out"; } > "$fb"
      bump "$task"; git reset -q --hard; git clean -qfd; echo "  ✎ $task changes requested by review"
    else
      r=$(retries "$task"); [ "$r" -gt 0 ] && echo "- ⚠️ \`$task\` — passed only after $((r+1)) attempts; review carefully" >> "$state/review.md"
      [ -n "$review_out" ] && printf -- '- 📝 `%s` review notes:\n%s\n' "$task" "$(printf '%s' "$review_out" | sed 's/^/    /')" >> "$state/review.md"
      rm -f "$fb" "$state/retries-$task"; set_status "$task" "completed"
      git add -A && git commit -q -m "feat($task): $task [loop]" || true; echo "  ✓ $task committed"
    fi
  else
    bump "$task"; git reset -q --hard; git clean -qfd; echo "  ↻ $task gate red (feedback saved)"
  fi

  if [ "$(retries "$task")" -ge "$MAX_TASK_RETRIES" ]; then set_status "$task" "blocked"; echo "  ✗ $task blocked"
  elif [ "$(jq -r --arg i "$task" '.tasks[]|select(.id==$i)|.status' tasks.json)" = "in_progress" ]; then set_status "$task" "pending"; fi
  git add tasks.json && git commit -q -m "chore: task state [$task]" || true
done

echo "=== final gate (spent \$$total_cost over $iter iters) ==="
DRAFT=""; HARNESS_RUN_MUTATION=1 "$HARNESS_HOME/checks/gate-full.sh" </dev/null 2>&1 || DRAFT="--draft"
git push -u origin "$BRANCH" 2>/dev/null || true
if command -v gh >/dev/null 2>&1; then
  body=$(jq -r '"## Tasks\n"+([.tasks[]|"- ["+.status+"] "+.id+": "+.title]|join("\n"))' tasks.json)
  blocked=$(jq -r '[.tasks[]|select(.status=="blocked")|.id]|join(", ")' tasks.json)
  [ -n "$blocked" ] && body="$body

## ⛔ Blocked (need a human)
$blocked"
  [ -s "$state/review.md" ] && body="$body

## 🔍 Review focus
$(cat "$state/review.md")"
  [ -s "$state/mutation.log" ] && body="$body

## 🧬 Mutation summary (surviving mutants = tests that don't constrain behavior — review these)
\`\`\`
$(tail -n 15 "$state/mutation.log")
\`\`\`"
  [ -f REFLECTION.md ] && body="$body

## Reflections
$(cat REFLECTION.md)"
  body="$body

_agent: $AGENT · spent: \$$total_cost · gate: ${DRAFT:+RED}${DRAFT:-green}_"
  gh pr create $DRAFT --title "[loop:$AGENT] $BRANCH" --body "$body" || echo "gh pr create failed — branch pushed, open PR manually."
else echo "gh not found — branch pushed, open PR manually."; fi
echo "Done. ${DRAFT:+(draft — final gate red) }Review the PR."
