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
# Idempotently wires the Stop + SessionStart + PreToolUse hooks into a TARGET
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
mkdir -p "$CLAUDE_DIR/scripts" "$CLAUDE_DIR/skills/done" "$CLAUDE_DIR/dod"

# --- copy bundle files ------------------------------------------------------
cp "$SCRIPT_DIR/scripts/done-gate.sh"         "$CLAUDE_DIR/scripts/done-gate.sh"
cp "$SCRIPT_DIR/scripts/baseline-snapshot.sh" "$CLAUDE_DIR/scripts/baseline-snapshot.sh"
cp "$SCRIPT_DIR/scripts/done-detect.sh"       "$CLAUDE_DIR/scripts/done-detect.sh"
cp "$SCRIPT_DIR/scripts/done-write-state.sh"  "$CLAUDE_DIR/scripts/done-write-state.sh"
cp "$SCRIPT_DIR/scripts/done-preflight.sh"    "$CLAUDE_DIR/scripts/done-preflight.sh"
# Shared identity resolver: harness-common.sh is SOURCED (stays non-exec);
# harness-resolve.sh is the executable wrapper; auto-branch.sh is the
# PreToolUse hook.
cp "$SCRIPT_DIR/scripts/harness-common.sh"    "$CLAUDE_DIR/scripts/harness-common.sh"
cp "$SCRIPT_DIR/scripts/harness-resolve.sh"   "$CLAUDE_DIR/scripts/harness-resolve.sh"
cp "$SCRIPT_DIR/scripts/auto-branch.sh"       "$CLAUDE_DIR/scripts/auto-branch.sh"
# The bundle SKILL.md is plugin-native (resolves code/data at
# ${CLAUDE_PLUGIN_ROOT}/...). For the non-plugin install, rewrite that root to
# the mirrored .claude/ layout so scripts resolve at
# $CLAUDE_PROJECT_DIR/.claude/scripts/... and base-dod at
# $CLAUDE_PROJECT_DIR/.claude/dod/base-dod.md. Single-quoted sed is load-bearing:
# it prevents this shell from expanding the vars, and sed does a literal replace.
# State refs ($CLAUDE_PROJECT_DIR/.claude/.harness/...) are untouched.
sed 's#${CLAUDE_PLUGIN_ROOT}#$CLAUDE_PROJECT_DIR/.claude#g' \
    "$SCRIPT_DIR/skills/done/SKILL.md" > "$CLAUDE_DIR/skills/done/SKILL.md"
# Base DoD → committed, portable artifact under .claude/dod/ (mirrors the
# plugin's dod/; NOT the gitignored .claude/.harness/). Step 0.5 of /done reads
# it. DOD.md (the harness project's own meta DoD) is intentionally NOT copied —
# it stays in the bundle.
cp "$SCRIPT_DIR/dod/base-dod.md"             "$CLAUDE_DIR/dod/base-dod.md"
chmod +x "$CLAUDE_DIR/scripts/done-gate.sh" "$CLAUDE_DIR/scripts/baseline-snapshot.sh" \
         "$CLAUDE_DIR/scripts/done-detect.sh" "$CLAUDE_DIR/scripts/done-write-state.sh" \
         "$CLAUDE_DIR/scripts/done-preflight.sh" \
         "$CLAUDE_DIR/scripts/harness-resolve.sh" "$CLAUDE_DIR/scripts/auto-branch.sh"
echo "  copied scripts/, skills/done/, and dod/base-dod.md"

# --- starter done-config.json (only if absent) ------------------------------
CONFIG_FILE="$CLAUDE_DIR/done-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<'JSON'
{
  "source_fingerprint": null,
  "detected": {},
  "overrides": {},
  "max_fix_attempts": 3,
  "max_review_rounds": 2,
  "baseline_snapshot": true,
  "deploy_check_cmd": null,
  "start_check_cmd": null,
  "start_timeout": 30,
  "trunk": null,
  "auto_branch": true,
  "branch_prefix": "task/",
  "untracked_policy": "baseline",
  "min_review_level": "high"
}
JSON
  echo "  created starter done-config.json"
else
  echo "  done-config.json already present — left untouched"
fi

# --- merge hooks into settings.local.json (idempotent) ----------------------
SETTINGS_FILE="$CLAUDE_DIR/settings.local.json"
[ -f "$SETTINGS_FILE" ] || echo '{}' > "$SETTINGS_FILE"

STOP_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/done-gate.sh"'
START_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/baseline-snapshot.sh"'
PRE_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/auto-branch.sh"'

MERGED=$(jq \
  --arg stop "$STOP_CMD" \
  --arg start "$START_CMD" \
  --arg pre "$PRE_CMD" '
  # ensure hooks containers exist
  .hooks = (.hooks // {})
  | .hooks.Stop = (.hooks.Stop // [])
  | .hooks.SessionStart = (.hooks.SessionStart // [])
  | .hooks.PreToolUse = (.hooks.PreToolUse // [])

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

  # append PreToolUse(Write|Edit) auto-branch hook only if not already wired.
  # PreToolUse entries carry a "matcher" that Stop/SessionStart do not.
  | ([ .hooks.PreToolUse[]?.hooks[]?.command ] | any(. == $pre)) as $hasPre
  | if $hasPre then .
    else .hooks.PreToolUse += [ {"matcher":"Write|Edit","hooks": [ {"type":"command","command":$pre} ]} ]
    end
' "$SETTINGS_FILE" 2>/dev/null)

if [ -z "$MERGED" ]; then
  echo "error: failed to merge hooks into $SETTINGS_FILE (invalid JSON?)" >&2
  exit 1
fi
printf '%s\n' "$MERGED" > "$SETTINGS_FILE"
echo "  wired Stop + SessionStart + PreToolUse hooks into settings.local.json"

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
