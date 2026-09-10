#!/bin/bash
#
# Completion Harness — installer (NON-PLUGIN FALLBACK).
#
# The primary distribution is the Claude Code plugin (see .claude-plugin/ and
# the README "Install as a plugin" section). Use this script only when the
# plugin path is unavailable — it mirrors the plugin root 1:1 under the target
# project's .claude/ so the bundle's plugin-native SKILL resolves with a single
# path substitution.
#
# Idempotently wires the Stop + SessionStart + PreToolUse + PostToolUse hooks into a TARGET
# project's machine-local settings, copies the bundle into the project's
# .claude/, seeds a starter done-config.json, and gitignores harness state.
#
# Usage: bash install.sh /path/to/project      (defaults to $PWD)

set -u

# --- resolve source (this bundle) and target -------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${1:-$PWD}"
TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd)"

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
  echo "error: target directory not found: ${1:-$PWD}" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to merge settings" >&2
  exit 1
fi

echo "Installing completion harness into: $TARGET_DIR"

CLAUDE_DIR="$TARGET_DIR/.claude"
mkdir -p "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/skills/done" "$CLAUDE_DIR/dod" \
         "$CLAUDE_DIR/contracts" "$CLAUDE_DIR/agents"

# --- copy bundle files ------------------------------------------------------
# Executable scripts: copied AND chmod +x below. harness-common.sh (sourced,
# never executed directly) is copied separately and deliberately excluded
# from this list so it stays non-exec.
EXEC_SCRIPTS=(
  done-gate.sh
  baseline-snapshot.sh
  done-detect.sh
  done-write-state.sh
  done-triage.sh
  done-preflight.sh
  worktree-detect.sh
  new-worktree.sh
  finish-worktree.sh
  run-task.sh
  harness-resolve.sh
  commit-ledger.sh
)
for s in "${EXEC_SCRIPTS[@]}"; do
  cp "$SCRIPT_DIR/scripts/$s" "$CLAUDE_DIR/scripts/$s"
done
# Shared identity resolver library — sourced, stays non-exec.
cp "$SCRIPT_DIR/scripts/harness-common.sh" "$CLAUDE_DIR/scripts/harness-common.sh"
# The bundle SKILL.md is plugin-native (resolves code/data at
# ${CLAUDE_PLUGIN_ROOT}/...). For the non-plugin install, rewrite that root to
# the mirrored .claude/ layout so scripts resolve at
# $CLAUDE_PROJECT_DIR/.claude/scripts/... and base-dod at
# $CLAUDE_PROJECT_DIR/.claude/dod/base-dod.md. Single-quoted sed is load-bearing:
# it prevents this shell from expanding the vars, and sed does a literal replace.
# State refs ($CLAUDE_PROJECT_DIR/.claude/.harness/...) are untouched.
sed 's#${CLAUDE_PLUGIN_ROOT}#$CLAUDE_PROJECT_DIR/.claude#g' \
    "$SCRIPT_DIR/skills/done/SKILL.md" > "$CLAUDE_DIR/skills/done/SKILL.md"
# The full DoD reference (dod-protocol.md) ships beside SKILL.md, with the same
# plugin-root rewrite so its ${CLAUDE_PLUGIN_ROOT}/scripts/... references resolve
# under the mirrored .claude/ layout in the non-plugin install.
sed 's#${CLAUDE_PLUGIN_ROOT}#$CLAUDE_PROJECT_DIR/.claude#g' \
    "$SCRIPT_DIR/skills/done/dod-protocol.md" > "$CLAUDE_DIR/skills/done/dod-protocol.md"
# Base DoD → committed, portable artifact under .claude/dod/ (mirrors the
# plugin's dod/; NOT the gitignored .claude/.harness/). Step 0.5 of /done reads
# it. DOD.md (the harness project's own meta DoD) is intentionally NOT copied —
# it stays in the bundle.
cp "$SCRIPT_DIR/dod/base-dod.md"             "$CLAUDE_DIR/dod/base-dod.md"
# Contracts: JSON-Schema files + base-dod.json + shell-abi.json. Copied whole so
# harness-common.sh resolves them at .claude/contracts/ (sibling of scripts/).
cp "$SCRIPT_DIR/contracts/"*.json "$CLAUDE_DIR/contracts/"
echo "  copied contracts/"
# Subagents: Step 5 of the protocol spawns the shipped dod-reviewer. Plugin
# installs get it from <plugin-root>/agents/ as `completion-harness:dod-reviewer`;
# this mirror makes it resolve bare as `dod-reviewer`. NO plugin-root rewrite is
# applied — the agent bodies reference only $CLAUDE_PROJECT_DIR state paths, never
# ${CLAUDE_PLUGIN_ROOT}, so there is nothing to substitute.
cp "$SCRIPT_DIR/agents/"*.md "$CLAUDE_DIR/agents/"
for s in "${EXEC_SCRIPTS[@]}"; do
  chmod +x "$CLAUDE_DIR/scripts/$s"
done
echo "  copied scripts/, skills/done/, agents/, and dod/base-dod.md"

# --- starter done-config.json (only if absent) ------------------------------
# Read straight from the just-copied contracts/done-config.default.json
# instead of duplicating its keys here: contracts/ is copied a few lines
# above (line ~77), so the default file already exists on disk by this
# point, and jq is a hard requirement of this script already (checked at
# the top, used again below for merging hooks). Only source_fingerprint and
# detected are added on top — they're per-run detection results, not
# defaults, so a fresh install has none.
CONFIG_FILE="$CLAUDE_DIR/done-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
  STARTER=$(jq '. + {"source_fingerprint": "none", "detected": {}}' \
    "$CLAUDE_DIR/contracts/done-config.default.json" 2>/dev/null)
  if [ -z "$STARTER" ]; then
    echo "error: failed to build starter done-config.json from contracts/done-config.default.json" >&2
    exit 1
  fi
  printf '%s\n' "$STARTER" > "$CONFIG_FILE"
  echo "  created starter done-config.json"
else
  echo "  done-config.json already present — left untouched"
fi

# --- merge hooks into settings.local.json (idempotent) ----------------------
SETTINGS_FILE="$CLAUDE_DIR/settings.local.json"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

# --- prune retired harness artifacts (upgrade path) -------------------------
# This installer only ever copied and appended, so a feature the bundle STOPPED
# shipping stayed LIVE in every existing non-plugin install: its script file
# remained under .claude/scripts/ (+x) and its hook entry remained in
# settings.local.json. The removed auto-branch PreToolUse(Write|Edit) hook is
# the case that surfaced it — it kept branching users' trunk after the bundle
# had dropped the feature. Plugin installs were never affected (hooks.json
# ships wholesale, so a dropped entry disappears on its own).
#
# Strategy: DERIVE what the bundle ships now (the same EXEC_SCRIPTS list used
# to copy, plus the sourced harness-common.sh) and remove harness-OWNED
# leftovers that are not in it. No hand-maintained list of retired artifacts:
# the NEXT feature removal needs no edit here. Ownership is never inferred
# from location alone — two independent signals are required, so a script a
# project dropped into .claude/scripts/ itself, or a hook it wired itself, is
# never touched:
#   file — lives in the harness's own .claude/scripts/ install target AND
#          carries the bundle's header marker ("Completion Harness —") in its
#          first 5 lines. Every shipped script has it; so did auto-branch.sh.
#   hook — EVERY command in the entry references
#          $CLAUDE_PROJECT_DIR/.claude/scripts/<name>.sh (that same target)
#          AND every <name>.sh it references is BOTH no longer shipped AND
#          provably harness-owned. Location alone is NOT ownership: a project
#          that wired its own hook at .claude/scripts/my-own-lint.sh has an
#          entry that satisfies the location test, so the second signal is the
#          same marker signal the file prune uses, read through the install
#          target:
#            absent from .claude/scripts/  -> harness-owned. The file prune
#              above runs FIRST, so a genuinely retired harness script is
#              already deleted (as marker-carrying) by the time we look; an
#              earlier install whose file prune succeeded and whose hook prune
#              warned out leaves the same state, and it must stay prunable.
#            present WITH the marker       -> harness-owned (belt-and-braces:
#              the file prune would normally have taken it already).
#            present WITHOUT the marker    -> the signature of a USER's script.
#              Never prunable. This is the case that protects the project's own
#              hook, and it holds on a FRESH install too, where no prune has
#              ever run: the user's script is present and unmarked.
#          Requiring ALL commands to be ours keeps a mixed entry (ours + a hook
#          the user added beside it) intact; nothing else is removed, reordered,
#          or rewritten, and non-hook keys are carried through untouched.
# Pruning is best-effort: any failure warns and the install continues (a
# stale leftover is a wart, a half-installed harness is worse).
SHIPPED_SCRIPTS=("${EXEC_SCRIPTS[@]}" harness-common.sh)

is_shipped() {
  local n
  for n in "${SHIPPED_SCRIPTS[@]}"; do
    [ "$n" = "$1" ] && return 0
  done
  return 1
}

for f in "$CLAUDE_DIR/scripts/"*.sh; do
  [ -f "$f" ] || continue                     # no-glob-match guard
  b="$(basename "$f")"
  is_shipped "$b" && continue                 # still part of the bundle
  head -5 "$f" 2>/dev/null | grep -q 'Completion Harness —' || continue  # not ours
  if rm -f "$f" 2>/dev/null; then
    echo "  pruned retired scripts/$b (no longer shipped)"
  else
    echo "  warning: could not remove retired scripts/$b — delete it by hand" >&2
  fi
done

SHIPPED_JSON=$(printf '%s\n' "${SHIPPED_SCRIPTS[@]}" \
  | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null)

# The ownership half of the hook test, read off the install target AFTER the
# file prune above: {"<name>.sh": <carries the header marker>} for every script
# still present. A name absent from this map is absent from disk.
#
# Names reach jq as POSITIONAL ARGUMENTS, never as delimited text: a filename
# may legally contain a tab or a newline, and any in-band separator would
# either corrupt the pair or drop the name from the map — and a dropped name
# reads as "absent from disk" = harness-owned = prunable, i.e. it would fail
# toward DELETING a user's hook entry. Arguments carry arbitrary filenames
# verbatim, so there is nothing left to mis-parse. If jq fails anyway the
# variable comes back empty and the whole hook prune is skipped (below).
PRESENT_ARGS=()
for f in "$CLAUDE_DIR/scripts/"*.sh; do
  [ -f "$f" ] || continue
  PRESENT_ARGS+=("$(basename "$f")")
  if head -5 "$f" 2>/dev/null | grep -q 'Completion Harness —'; then
    PRESENT_ARGS+=(true)
  else
    PRESENT_ARGS+=(false)
  fi
done
PRESENT_JSON=$(jq -n '
  $ARGS.positional as $a
  | reduce range(0; ($a | length); 2) as $i ({}; .[$a[$i]] = ($a[$i + 1] == "true"))
' --args ${PRESENT_ARGS[@]+"${PRESENT_ARGS[@]}"} 2>/dev/null)

# Shared jq prelude: the ownership predicate, used once to REPORT what will go
# and once to actually remove it, so the two can never drift.
PRUNE_DEFS='
  # Commands carried by one hook entry.
  def cmds: [ .hooks[]?.command? // empty ];
  # Script basenames those commands reference under the harness install
  # target. Read off ONE command as {refs, unresolved}: the command string is
  # split on the literal install-target prefix and each tail is resolved to the
  # name that follows it. A name may contain ANY character a filesystem allows
  # (a space above all), so no character class enumerates it — the tail is cut
  # at the first shell metacharacter instead, and the quote that closed it (if
  # any) is what licenses an embedded space. Nothing is ever GUESSED: a tail we
  # cannot resolve unambiguously sets .unresolved, which makes the whole entry
  # not harness-owned and therefore un-prunable. (\u0027 is the single quote,
  # spelled as an escape so this prelude can stay inside single quotes.)
  def parse_cmd($c):
    reduce ($c | split("/.claude/scripts/") | .[1:])[] as $t
      ({refs: [], unresolved: false};
        ($t | capture("^(?<cand>[^\"\u0027\n;|&<>()]*)(?<term>[\"\u0027])?")) as $m
      | ($m.term != null) as $quoted
      | ($m.cand | capture("^(?<w>\\S*)").w) as $word
      | if ($m.cand | endswith(".sh"))
             and ($quoted or ($m.cand | test("\\s") | not))
        then .refs += [$m.cand]            # quoted name, or one with no space
        elif ($quoted | not) and ($word | endswith(".sh"))
        then .refs += [$word]              # bare name followed by arguments
        else .unresolved = true            # anything else: fail toward KEEP
        end);
  def parsed: [ cmds[] | parse_cmd(.) ];
  def refs: [ parsed[].refs[] ];
  def unresolved: (parsed | any(.unresolved));
  # Second ownership signal (see the comment block above): absent from the
  # install target, or present carrying the bundle header marker. A file that
  # is present WITHOUT the marker is a user script and is never owned.
  def harness_owned($n): if ($present | has($n)) then $present[$n] else true end;
  # A retired harness entry: entirely ours by location, every reference in it
  # resolved, naming at least one script, and every script it names both
  # unshipped AND harness-owned.
  def retired: (cmds | length) > 0
    and (cmds | all(contains("/.claude/scripts/")))
    and (unresolved | not)
    and (refs | length) > 0
    and (refs | all(. as $n | (IN($shipped[]) | not) and harness_owned($n)));
'

if [ -z "$SHIPPED_JSON" ] || [ -z "$PRESENT_JSON" ]; then
  echo "  warning: could not build the shipped/present script lists — skipped" \
       "pruning retired hooks from settings.local.json" >&2
else
  # What is about to go, one line per entry, so a destructive step is never
  # silent. Reported only after the write below actually lands.
  DOOMED=$(jq -r --argjson shipped "$SHIPPED_JSON" --argjson present "$PRESENT_JSON" \
    "$PRUNE_DEFS"'
    if (.hooks | type) == "object" then
      .hooks | to_entries[] | .key as $ev | .value
      | if type == "array"
        then .[] | select(type == "object") | select(retired)
             | "\($ev) → \(refs | unique | join(", "))"
        else empty end
    else empty end
  ' "$SETTINGS_FILE" 2>/dev/null)

  PRUNED=$(jq --argjson shipped "$SHIPPED_JSON" --argjson present "$PRESENT_JSON" \
    "$PRUNE_DEFS"'
    if (.hooks | type) == "object" then
      .hooks |= with_entries(
        if (.value | type) == "array"
        then .value = [ .value[]
               | if type == "object" then select(retired | not) else . end ]
        else . end)
    else . end
  ' "$SETTINGS_FILE" 2>/dev/null)
  if [ -z "$PRUNED" ]; then
    echo "  warning: could not prune retired hooks from $SETTINGS_FILE" \
         "(invalid JSON?) — left untouched" >&2
  else
    printf '%s\n' "$PRUNED" > "$SETTINGS_FILE"
    if [ -n "$DOOMED" ]; then
      while IFS= read -r entry; do
        [ -n "$entry" ] && echo "  pruned retired hook entry: $entry (no longer shipped)"
      done <<< "$DOOMED"
    fi
  fi
fi

STOP_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/done-gate.sh"'
START_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/baseline-snapshot.sh"'
POST_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/commit-ledger.sh"'
# PreToolUse(Bash) half of the commit ledger: pins HEAD so the PostToolUse half
# can sweep exactly what moved during the call (see commit-ledger.sh).
PREL_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/commit-ledger.sh" pre'
# Tool matcher for BOTH commit-ledger halves. Wider than Bash because a
# non-Bash tool can move HEAD too (an MCP git server, a SlashCommand that
# commits) and no Bash window would exist to observe it. NOT every tool: Read /
# Edit / Glob cannot move HEAD, so pinning on them would cost two process
# spawns per tool call for nothing. MUST stay identical to hooks/hooks.json —
# the plugin path and this fallback installer wire the same pair.
LEDGER_MATCHER='Bash|SlashCommand|mcp__.*'

MERGED=$(jq \
  --arg stop "$STOP_CMD" \
  --arg start "$START_CMD" \
  --arg post "$POST_CMD" \
  --arg prel "$PREL_CMD" \
  --arg ledgerm "$LEDGER_MATCHER" '
  # ensure hooks containers exist
  .hooks = (.hooks // {})
  | .hooks.Stop = (.hooks.Stop // [])
  | .hooks.SessionStart = (.hooks.SessionStart // [])
  | .hooks.PreToolUse = (.hooks.PreToolUse // [])
  | .hooks.PostToolUse = (.hooks.PostToolUse // [])

  # append Stop hook only if this exact command is not already wired
  | ([ .hooks.Stop[]?.hooks[]?.command ] | any(. == $stop)) as $hasStop
  | if $hasStop then .
    else .hooks.Stop += [ {"hooks": [ {"type":"command","command":$stop,"timeout":10} ]} ]
    end

  # append SessionStart hook only if this exact command is not already wired
  | ([ .hooks.SessionStart[]?.hooks[]?.command ] | any(. == $start)) as $hasStart
  | if $hasStart then .
    else .hooks.SessionStart += [ {"hooks": [ {"type":"command","command":$start} ]} ]
    end

  # commit-ledger halves: UPDATE-IN-PLACE, then append-if-absent.
  #
  # The presence test keys on the COMMAND alone, so an entry wired by an OLDER
  # installer — identical command, the narrow "Bash" matcher — counted as
  # already wired and was skipped. Every existing install therefore kept the
  # narrow matcher when the matcher widened, and a SlashCommand- or MCP-driven
  # commit was never pinned or swept: empty ledger, base advances to HEAD, Stop
  # allowed with no DoD run. So first REWRITE the matcher of any entry carrying
  # our command, then append only if no such entry exists. Both halves stay
  # idempotent: on an install that is already current the assignment is a no-op
  # and the append is skipped, so a second run is byte-identical.
  #
  # Scoped to entries whose command is EXACTLY ours, so any unrelated
  # PreToolUse entry a project already wired is left untouched.
  | .hooks.PreToolUse = [ .hooks.PreToolUse[]?
      | if ([ .hooks[]?.command ] | any(. == $prel)) then .matcher = $ledgerm else . end ]
  | ([ .hooks.PreToolUse[]?.hooks[]?.command ] | any(. == $prel)) as $hasPreL
  | if $hasPreL then .
    else .hooks.PreToolUse += [ {"matcher":$ledgerm,"hooks": [ {"type":"command","command":$prel} ]} ]
    end

  | .hooks.PostToolUse = [ .hooks.PostToolUse[]?
      | if ([ .hooks[]?.command ] | any(. == $post)) then .matcher = $ledgerm else . end ]
  | ([ .hooks.PostToolUse[]?.hooks[]?.command ] | any(. == $post)) as $hasPost
  | if $hasPost then .
    else .hooks.PostToolUse += [ {"matcher":$ledgerm,"hooks": [ {"type":"command","command":$post} ]} ]
    end
' "$SETTINGS_FILE" 2>/dev/null)

if [ -z "$MERGED" ]; then
  echo "error: failed to merge hooks into $SETTINGS_FILE (invalid JSON?)" >&2
  exit 1
fi
printf '%s\n' "$MERGED" > "$SETTINGS_FILE"
echo "  wired Stop + SessionStart + PreToolUse + PostToolUse hooks into settings.local.json"

# --- gitignore machine-local harness state ----------------------------------
# .harness/ (per-session state) and settings.local.json (machine-local hooks)
# must never be tracked. The shared bundle (scripts/, skills/done/,
# done-config.json) is intentionally NOT ignored — it is committed on adoption.
GITIGNORE="$TARGET_DIR/.gitignore"
add_ignore() {
  local line="$1"
  if [ ! -f "$GITIGNORE" ] || ! grep -qxF "$line" "$GITIGNORE" 2>/dev/null; then
    # Prepend a newline so we never fuse onto a no-trailing-newline last line.
    if [ -s "$GITIGNORE" ] && [ -n "$(tail -c1 "$GITIGNORE" 2>/dev/null)" ]; then
      printf '\n%s\n' "$line" >> "$GITIGNORE"
    else
      printf '%s\n' "$line" >> "$GITIGNORE"
    fi
    echo "  added $line to .gitignore"
  else
    echo "  .gitignore already ignores $line"
  fi
}
add_ignore ".claude/.harness/"
add_ignore ".claude/settings.local.json"

# --- create harness state dirs ---------------------------------------------
mkdir -p "$CLAUDE_DIR/.harness/baselines" "$CLAUDE_DIR/.harness/done-state"

echo "Done. Use /done to verify a changeset; the Stop hook enforces it."
