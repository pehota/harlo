#!/bin/bash
#
# dod/hooks/approve.sh — PreToolUse (Bash): auto-approve dod's own CLI so
# the skills run without a permission prompt (ADR 0005).
#
# A plugin cannot ship permission rules, and a SKILL.md `allowed-tools`
# lasts one turn only (/dod:define spans several). A PreToolUse hook can
# return permissionDecision "allow", so this one does — for exactly one
# command shape and nothing else:
#
#   bash <this plugin's scripts/dod.sh> <whitelisted verb> [args]
#
# Allow ONLY when ALL hold, else print nothing and exit 0 (fall through to
# Claude Code's normal permission handling — this hook never denies, never
# blocks, never exits non-zero):
#   - tool_name is Bash;
#   - the command starts with exactly `bash ` + this plugin's dod.sh path,
#     resolved from this file's own location (logical or physical form),
#     compared as an exact string, written "double-quoted", 'single-quoted'
#     or bare — no prefix, no env assignment, no other interpreter;
#   - then one space and a whitelisted verb, then nothing or a space + args;
#   - the args, scanned quote-aware, contain nothing the shell would expand
#     or interpret: inside '…' anything goes (newlines included); inside "…"
#     no $ ` \ and no newline/CR; outside quotes none of
#     ; & | < > ( ) $ ` \ * ? [ ] { } ~ # newline CR; quotes balanced.
# So the only program that can run is dod.sh, with literal words as
# arguments — and dod.sh never evals or executes its arguments.
#
# Conservative by design: when unsure, fall through. Pure bash + jq: one jq
# pass over the hook payload does the whole match (the args check is one
# linear regex — a char-by-char bash loop was quadratic on large JSON args).
# No `set -e`/`set -u`/pipefail, matching every other hook's fail-open
# discipline — a bug here only means a prompt, never a blocked tool call.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
ROOT_P="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)"
[ -n "$ROOT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

VERBS="brief-path contract-write contract-read state-set diff-hash cache-get cache-set baseline-worktree changed-standards result-write record-decisions claim"

# The args grammar, anchored with \A/\z (never ^/$: in jq's regex flavour $
# also matches before a trailing newline). Alternatives start on disjoint
# chars and the star is possessive, so the match is linear, no backtracking:
#   outside quotes: any char but ; & | < > ( ) $ ` \ * ? [ ] { } ~ # ' " LF CR
#   '…'           : anything but '
#   "…"           : anything but " $ ` \ LF CR
ARGS_RE=$(cat <<'EOF'
\A(?:[^;&|<>()$`\\*?\[\]{}~#'"\n\r]|'[^']*'|"[^"$`\\\n\r]*")*+\z
EOF
)

# shellcheck disable=SC2016
jq -e -s --arg root "$ROOT" --arg root_p "$ROOT_P" --arg verbs "$VERBS" --arg re "$ARGS_RE" --arg sq "'" '
  def prefixes:
    [$root, $root_p] | unique | .[] | "\(.)/scripts/dod.sh"
    | ("bash \"\(.)\" ", "bash \($sq)\(.)\($sq) ", "bash \(.) ");
  def rest_after_prefix($c):
    first(prefixes | select(. as $p | $c | startswith($p)) | . as $p | $c[($p | length):]) // null;

  length == 1 and (.[0] | type) == "object" and (.[0]
  | (.tool_name == "Bash")
  and ((.tool_input.command | type) == "string")
  and (.tool_input.command as $c
    | ($c | contains("\u0000") | not)
    and (rest_after_prefix($c) as $rest
      | $rest != null
      and (($rest | index(" ")) as $i
        | (if $i == null then [$rest, ""] else [$rest[:$i], $rest[$i:]] end) as [$verb, $args]
        | any($verbs | split(" ")[]; . == $verb)
        and ($args | test($re))))))
' >/dev/null 2>&1 || exit 0

jq -n '{hookSpecificOutput: {hookEventName: "PreToolUse",
  permissionDecision: "allow", permissionDecisionReason: "dod: own CLI"}}' 2>/dev/null
exit 0
