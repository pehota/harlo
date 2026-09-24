#!/bin/bash
#
# Scenario: dod-context-collector writes a task-relevant, cited context brief.
#
#   (rules) a fixture repo with a root CLAUDE.md (one relevant rule, one
#           irrelevant UI-only decoy), an ADR stating a domain invariant, a
#           nested CLAUDE.md in the module the task touches, and neighbouring
#           code with a consistent idiom. The brief is written at brief_path
#           only; it holds every relevant rule and the idiom, leaves out the
#           decoy, cites every entry path:line (each line exists and states
#           the rule), speculates about no impact or plan, and the final
#           message is {"applicable":true,"path":...}.
#   (empty) an empty repo — no standards, no code: {"applicable":false} with
#           a reason, nothing written.
#
# Runs the agent WITH tools (Read, Grep, Glob, Write) inside a throwaway git
# repo per run. Usage:
#   bash dod/tests/scenario/test-context-collector.sh [COLLECTOR_AGENT_PATH]

DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR0/scenario-helpers.sh"
AGENT="${1:-$DIR0/../../agents/dod-context-collector.md}"
TOOLS="Read,Grep,Glob,Write"
BRIEF=".dod/main/brief.md"

SYS=$(mktemp)
FIXTURES=()
cleanup() { rm -f "$SYS"; for d in "${FIXTURES[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT
{
  echo "You are this agent, running as a subagent. Your working directory is the repository."
  echo
  cat "$AGENT"
} > "$SYS"

# collector__repo — a fresh git repo with one commit; prints its path.
collector__repo() {
  local d
  d=$(mktemp -d)
  git -C "$d" init -q -b main 2>/dev/null
  git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  printf '%s' "$d"
}

# collector__rules_fixture — neutral invented stock-keeping service.
collector__rules_fixture() {
  local d
  d=$(collector__repo)
  mkdir -p "$d/docs/adr" "$d/inventory" "$d/web"
  cat > "$d/CLAUDE.md" <<'EOF'
# Project rules

## Data access

- Every database write goes through a UnitOfWork; never call session.commit() directly.

## Web UI

- Button labels in web/ use sentence case, never title case.
EOF
  cat > "$d/docs/adr/0001-stock-never-negative.md" <<'EOF'
# 1. Stock never goes negative

## Decision

An item's stock count must never drop below zero; an operation that would make it negative raises OutOfStock.
EOF
  cat > "$d/inventory/CLAUDE.md" <<'EOF'
# inventory/

- Quantities are whole integers; never use float for a quantity.
EOF
  cat > "$d/inventory/errors.py" <<'EOF'
class OutOfStock(Exception):
    pass
EOF
  cat > "$d/inventory/reservations.py" <<'EOF'
from inventory.errors import OutOfStock


def reserve(uow, item_id: str, qty: int) -> None:
    item = uow.items.get(item_id)
    if item.stock - qty < 0:
        raise OutOfStock(item_id)
    item.stock -= qty
    uow.items.save(item)
EOF
  cat > "$d/inventory/restock.py" <<'EOF'
def restock(uow, item_id: str, qty: int) -> None:
    item = uow.items.get(item_id)
    item.stock += qty
    uow.items.save(item)
EOF
  cat > "$d/web/buttons.js" <<'EOF'
export const saveLabel = "Save changes";
EOF
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@t commit -q -m fixture
  printf '%s' "$d"
}

TASK_RULES="Add a release(uow, item_id, qty) function to inventory/reservations.py that returns reserved quantity to an item's stock."

# collector__user <task>
collector__user() {
  printf 'Inputs:\n\ntask       : %s\nbrief_path : %s\n' "$1" "$BRIEF"
}

# collector__cited_ok <repo> <brief_line> <term_regex> <label> — the brief
# line carries >=1 path:line citation, and every cited line exists and
# matches term_regex.
collector__cited_ok() {
  local repo="$1" bline="$2" term="$3" label="$4" cites c path line text n=0
  cites=$(printf '%s' "$bline" | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+' )
  [ -n "$cites" ] || { echo "$label: no path:line citation in: $bline"; return 1; }
  for c in $cites; do
    path=${c%:*}; line=${c##*:}
    [ -f "$repo/$path" ] || { echo "$label: cited file $path does not exist"; return 1; }
    text=$(sed -n "${line}p" "$repo/$path")
    printf '%s' "$text" | grep -qiE "$term" || { echo "$label: $c does not state it (line: '$text')"; return 1; }
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}

# collector__rule <repo> <brief> <find_regex> <term_regex> <label> — some
# brief line mentions the rule (find_regex) and its citation states it.
collector__rule() {
  local repo="$1" brief="$2" find="$3" term="$4" label="$5" bline
  bline=$(printf '%s\n' "$brief" | grep -iE "$find" | grep -E ':[0-9]+' | head -n 1)
  [ -n "$bline" ] || { echo "$label missing (or uncited) in brief"; return 1; }
  collector__cited_ok "$repo" "$bline" "$term" "$label"
}

assert_rules() {
  local repo="$1" reply="$2" brief porcelain c path line total
  printf '%s' "$reply" | jq -e '.applicable == true' >/dev/null 2>&1 || { echo "final message not applicable:true: $reply"; return 1; }
  [ "$(printf '%s' "$reply" | jq -r '.path')" = "$BRIEF" ] || { echo "final message path != $BRIEF: $reply"; return 1; }
  [ -s "$repo/$BRIEF" ] || { echo "no brief at $BRIEF"; return 1; }

  porcelain=$(git -C "$repo" -c core.excludesFile=/dev/null status --porcelain -uall)
  [ "$porcelain" = "?? $BRIEF" ] || { echo "repo changes beyond the brief: $(printf '%s' "$porcelain" | tr '\n' ';')"; return 1; }

  brief=$(cat "$repo/$BRIEF")
  collector__rule "$repo" "$brief" 'unit ?of ?work' 'unitofwork' "unit-of-work rule" || return 1
  collector__rule "$repo" "$brief" 'negative|below zero' 'negative|below zero' "stock invariant" || return 1
  collector__rule "$repo" "$brief" 'float|integer' 'float|integer' "nested integer rule" || return 1
  collector__rule "$repo" "$brief" 'uow' 'uow' "uow.items idiom" || return 1

  printf '%s' "$brief" | grep -qiE 'sentence case|title case' && { echo "irrelevant UI decoy rule included"; return 1; }

  # every citation anywhere in the brief resolves to an existing line
  total=0
  for c in $(printf '%s' "$brief" | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+:[0-9]+'); do
    path=${c%:*}; line=${c##*:}
    [ -f "$repo/$path" ] || { echo "citation $c: no such file"; return 1; }
    [ "$line" -ge 1 ] && [ "$line" -le "$(wc -l < "$repo/$path")" ] || { echo "citation $c: no such line"; return 1; }
    total=$((total + 1))
  done
  [ "$total" -ge 4 ] || { echo "only $total citations"; return 1; }

  printf '%s' "$brief" | grep -qiE 'impact|blast radius|will (change|affect|break)|callers? (of|to) release|implementation plan|recommend|suggest' \
    && { echo "brief speculates about impact / plan / opinion: $(printf '%s' "$brief" | grep -iE 'impact|blast radius|will (change|affect|break)|callers? (of|to) release|implementation plan|recommend|suggest' | head -n 1)"; return 1; }
  return 0
}

assert_empty() {
  local repo="$1" reply="$2" reason porcelain
  printf '%s' "$reply" | jq -e '.applicable == false' >/dev/null 2>&1 || { echo "final message not applicable:false: $reply"; return 1; }
  reason=$(printf '%s' "$reply" | jq -r '.reason // ""')
  [ -n "$reason" ] || { echo "applicable:false without a reason"; return 1; }
  porcelain=$(git -C "$repo" -c core.excludesFile=/dev/null status --porcelain -uall)
  [ -z "$porcelain" ] || { echo "wrote files in an N/A repo: $(printf '%s' "$porcelain" | tr '\n' ';')"; return 1; }
}

# collector__run <assert_fn> <fixture_fn> <task>
collector__run() {
  local assert="$1" fixture="$2" task="$3" i repo reply reason fail=0
  for i in $(seq 1 "$SCENARIO_RUNS"); do
    repo=$("$fixture"); FIXTURES+=("$repo")
    reply=$(scenario_model_tools "$SYS" "$(collector__user "$task")" "$repo" "$TOOLS")
    if reason=$("$assert" "$repo" "$reply"); then
      echo "  run $i: PASS"
    else
      echo "  run $i: FAIL — $reason"
      if [ -n "${SCENARIO_VERBOSE:-}" ]; then
        printf 'reply: %s\n' "$reply" | sed 's/^/    | /'
        [ -f "$repo/$BRIEF" ] && sed 's/^/    | /' "$repo/$BRIEF"
      fi
      fail=1
    fi
  done
  return $fail
}

fail=0
echo "== scenario (rules): relevant cited rules + idiom, no decoy, only the brief written ($AGENT) =="
collector__run assert_rules collector__rules_fixture "$TASK_RULES" || fail=1
echo "== scenario (empty): no standards, no code -> applicable:false, nothing written ($AGENT) =="
collector__run assert_empty collector__repo "Add a greet(name) function that returns a greeting." || fail=1
exit $fail
