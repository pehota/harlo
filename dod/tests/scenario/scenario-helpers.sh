#!/bin/bash
#
# Shared helpers for dod/tests/scenario/*.sh — headless before/after runs of
# a skill's prompt text against a fixture situation.
#
# Not a run-tests.sh suite: run-tests.sh globs dod/tests/test-*.sh only, and
# these call a real model (slow, costs tokens). Run by hand:
#   bash dod/tests/scenario/test-<x>.sh [SKILL_PATH]
# Baseline: git show 39b65b7:dod/skills/<x>/SKILL.md > /tmp/base.md, pass it
# (39b65b7 is the last commit before the works_when/relay change).
#
# Sourced, never executed.

SCENARIO_RUNS=3

# scenario_model <system_prompt_file> <user_prompt> — one isolated,
# tool-less, non-interactive sonnet run: no tools, settings, plugins/hooks,
# MCP, skills or CLAUDE.md. Prints only the reply's JSON object (first line
# opening with `{` to the last line closing with `}`), dropping fences/prose.
scenario_model() {
  local sys="$1" user="$2" out
  out=$(cd "${TMPDIR:-/tmp}" && printf '%s' "$user" | CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p \
    --model sonnet --tools "" --setting-sources "" --strict-mcp-config \
    --disable-slash-commands --no-session-persistence \
    --system-prompt "$(cat "$sys")" 2>&1)
  printf '%s\n' "$out" | awk '/^\{/ { f = 1 } f { buf = buf $0 "\n" } f && /\}[[:space:]]*$/ { out = buf } END { printf "%s", out }'
}

# scenario_run <assert_fn> <system_prompt_file> <user_prompt> — runs the model
# SCENARIO_RUNS times, pipes each reply to <assert_fn> (which prints a
# failure reason and returns non-zero, or returns 0). Exit 1 on any fail.
scenario_run() {
  local assert="$1" sys="$2" user="$3" i reply reason fail=0
  for i in $(seq 1 "$SCENARIO_RUNS"); do
    reply=$(scenario_model "$sys" "$user")
    if reason=$(printf '%s' "$reply" | "$assert"); then
      echo "  run $i: PASS"
    else
      echo "  run $i: FAIL — $reason"
      [ -n "${SCENARIO_VERBOSE:-}" ] && printf '%s\n' "$reply" | sed 's/^/    | /'
      fail=1
    fi
  done
  return $fail
}
