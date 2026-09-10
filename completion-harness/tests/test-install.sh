#!/bin/bash
#
# test-install.sh — install-verification for completion-harness/install.sh.
#
# The behavioural suites all run against the SOURCE tree (they source/exec
# completion-harness/scripts/* directly, which resolve their sibling contracts/
# via BASH_SOURCE). This suite is the one place that exercises install.sh end to
# end: it installs the bundle into a throwaway target dir and asserts the shipped
# .claude/ layout is complete, correct, and that the plugin→.claude path rewrite
# was actually applied to the installed SKILL.md.
#
# It consolidates the install-verification intent that used to be scattered
# across the old Class-B tests (which sourced the INSTALLED copies as a proxy for
# "install.sh shipped the right thing").
#
# Zero-dependency: bash + jq. Prints PASS/FAIL per assertion; exits non-zero on
# any failure. No `set -e` — every assertion runs and reports.

set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$(cd "$(dirname "$0")/../.." && pwd)/completion-harness/install.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

echo "== test-install =="

if [ ! -f "$INSTALL" ]; then
  bad "install.sh not found at $INSTALL"
  echo; echo "test-install: $PASS passed, $FAIL failed"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot verify contracts"
  echo; echo "test-install: $PASS passed, $FAIL failed"; exit 1
fi

TMP=$(hc__test_mktemp_d)
trap 'rm -rf "$TMP" 2>/dev/null' EXIT INT TERM

# --- run the installer ------------------------------------------------------
if bash "$INSTALL" "$TMP" >/dev/null 2>&1; then
  ok "install.sh exited 0"
else
  bad "install.sh exited non-zero"
fi

CL="$TMP/.claude"

# --- scripts present + executable -------------------------------------------
for s in done-gate.sh baseline-snapshot.sh done-detect.sh done-write-state.sh \
         done-triage.sh done-preflight.sh harness-common.sh harness-resolve.sh auto-branch.sh; do
  if [ -f "$CL/scripts/$s" ]; then
    ok "shipped scripts/$s"
  else
    bad "shipped scripts/$s" "missing"
  fi
done

# Executable bit — every shipped script EXCEPT harness-common.sh (SOURCED, stays
# non-exec by install.sh's chmod list).
for s in done-gate.sh baseline-snapshot.sh done-detect.sh done-write-state.sh \
         done-triage.sh done-preflight.sh harness-resolve.sh auto-branch.sh; do
  if [ -x "$CL/scripts/$s" ]; then
    ok "scripts/$s is executable"
  else
    bad "scripts/$s is executable" "not +x"
  fi
done

# --- contracts present + valid JSON -----------------------------------------
for c in shell-abi.json base-dod.schema.json done-config.schema.json \
         done-state.schema.json resolver-output.schema.json review-log.schema.json \
         done-plan.schema.json base-dod.json; do
  if [ -f "$CL/contracts/$c" ]; then
    if jq empty "$CL/contracts/$c" >/dev/null 2>&1; then
      ok "shipped contracts/$c (valid JSON)"
    else
      bad "shipped contracts/$c valid JSON" "invalid"
    fi
  else
    bad "shipped contracts/$c" "missing"
  fi
done

# --- base DoD ---------------------------------------------------------------
if [ -f "$CL/dod/base-dod.md" ]; then
  ok "shipped dod/base-dod.md"
else
  bad "shipped dod/base-dod.md" "missing"
fi

# --- SKILL.md present + path rewrite applied --------------------------------
SKILL="$CL/skills/done/SKILL.md"
if [ -f "$SKILL" ]; then
  ok "shipped skills/done/SKILL.md"

  # install.sh's sed rewrites the plugin-native ${CLAUDE_PLUGIN_ROOT} root to the
  # mirrored .claude/ layout ($CLAUDE_PROJECT_DIR/.claude). Assert the EFFECT:
  #   (a) NO ${CLAUDE_PLUGIN_ROOT} token survives in the installed copy, and
  #   (b) the resolved $CLAUDE_PROJECT_DIR/.claude/scripts/ path is present.
  if grep -q 'CLAUDE_PLUGIN_ROOT' "$SKILL"; then
    bad "installed SKILL.md has NO \${CLAUDE_PLUGIN_ROOT} (rewrite applied)" \
      "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$SKILL") occurrences remain"
  else
    ok "installed SKILL.md has NO \${CLAUDE_PLUGIN_ROOT} (rewrite applied)"
  fi
  if grep -q '\$CLAUDE_PROJECT_DIR/.claude/scripts/' "$SKILL"; then
    ok "installed SKILL.md references \$CLAUDE_PROJECT_DIR/.claude/scripts/ (resolved root)"
  else
    bad "installed SKILL.md references \$CLAUDE_PROJECT_DIR/.claude/scripts/" "not found"
  fi

  # Thin SKILL.md must carry the FALLBACK clause (#7): references dod-protocol.md
  # + instructs running ALL steps when triage fails / prints nothing.
  if grep -q 'dod-protocol.md' "$SKILL"; then
    ok "thin SKILL.md references dod-protocol.md"
  else
    bad "thin SKILL.md references dod-protocol.md" "not found"
  fi
  if grep -qi 'ALL steps' "$SKILL"; then
    ok "thin SKILL.md fallback names 'ALL steps'"
  else
    bad "thin SKILL.md fallback names 'ALL steps'" "not found"
  fi
  if grep -q 'done-triage.sh' "$SKILL"; then
    ok "thin SKILL.md invokes done-triage.sh"
  else
    bad "thin SKILL.md invokes done-triage.sh" "not found"
  fi
else
  bad "shipped skills/done/SKILL.md" "missing"
fi

# --- dod-protocol.md present + path rewrite applied -------------------------
PROTO="$CL/skills/done/dod-protocol.md"
if [ -f "$PROTO" ]; then
  ok "shipped skills/done/dod-protocol.md"
  if grep -q 'CLAUDE_PLUGIN_ROOT' "$PROTO"; then
    bad "installed dod-protocol.md has NO \${CLAUDE_PLUGIN_ROOT} (rewrite applied)" \
      "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$PROTO") occurrences remain"
  else
    ok "installed dod-protocol.md has NO \${CLAUDE_PLUGIN_ROOT} (rewrite applied)"
  fi
  if grep -q '\$CLAUDE_PROJECT_DIR/.claude/' "$PROTO"; then
    ok "installed dod-protocol.md references \$CLAUDE_PROJECT_DIR/.claude/ (resolved root)"
  else
    bad "installed dod-protocol.md references \$CLAUDE_PROJECT_DIR/.claude/" "not found"
  fi
else
  bad "shipped skills/done/dod-protocol.md" "missing"
fi

# --- dod-reviewer agent shipped ---------------------------------------------
# Step 5 spawns the shipped reviewer; on the non-plugin path it must resolve
# bare as `dod-reviewer`, which requires the file under .claude/agents/.
AGENT="$CL/agents/dod-reviewer.md"
if [ -f "$AGENT" ]; then
  ok "shipped agents/dod-reviewer.md"
  if grep -q '^name: dod-reviewer$' "$AGENT"; then
    ok "agents/dod-reviewer.md frontmatter has name: dod-reviewer"
  else
    bad "agents/dod-reviewer.md frontmatter has name: dod-reviewer" "not found"
  fi
  if grep -q '^description:' "$AGENT"; then
    ok "agents/dod-reviewer.md frontmatter has description:"
  else
    bad "agents/dod-reviewer.md frontmatter has description:" "not found"
  fi
  # The reviewer's deliverable IS the review-log file it writes — drop Write from
  # the frontmatter and every /done run breaks at Step 5 while every other suite
  # still passes, so pin it here.
  if grep -q '^tools:.*Write' "$AGENT"; then
    ok "agents/dod-reviewer.md frontmatter tools: includes Write"
  else
    bad "agents/dod-reviewer.md frontmatter tools: includes Write" \
      "without Write the agent cannot produce the review-log the gate requires"
  fi
  # No plugin-root rewrite is applied to agents (they reference no plugin
  # paths) — assert the body stayed free of the token so a future edit that
  # introduces one is caught here rather than at runtime.
  if grep -q 'CLAUDE_PLUGIN_ROOT' "$AGENT"; then
    bad "agents/dod-reviewer.md references no \${CLAUDE_PLUGIN_ROOT}" \
      "$(grep -c 'CLAUDE_PLUGIN_ROOT' "$AGENT") occurrences — install.sh applies no rewrite here"
  else
    ok "agents/dod-reviewer.md references no \${CLAUDE_PLUGIN_ROOT}"
  fi
else
  bad "shipped agents/dod-reviewer.md" "missing"
fi

# --- hooks wired into settings.local.json -----------------------------------
# Nothing here asserted the PreToolUse commit-ledger `pre` half at all, so an
# installer regression that dropped it from the jq merge would ship green: the
# ledger would then only ever sweep from the SessionStart baseline (the
# no-cursor fallback), and the widened matcher — the whole reason a
# SlashCommand- or MCP-driven commit is observed at all — would be invisible.
SET="$CL/settings.local.json"
LEDGER_MATCHER='Bash|SlashCommand|mcp__.*'
if [ -f "$SET" ] && jq empty "$SET" >/dev/null 2>&1; then
  ok "settings.local.json is valid JSON"

  # ev_matcher <event> <command substring> → the matcher of the merged entry.
  ev_matcher() {
    jq -r --arg e "$1" --arg c "$2" \
      '.hooks[$e][]? | select((.hooks[]?.command // "") | contains($c)) | .matcher // ""' \
      "$SET" 2>/dev/null
  }

  # PreToolUse: BOTH halves must be present — auto-branch on Write|Edit and the
  # commit-ledger `pre` pin on the widened matcher.
  if jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(endswith("commit-ledger.sh\" pre"))' \
       "$SET" >/dev/null 2>&1; then
    ok "PreToolUse commit-ledger 'pre' hook is wired (HEAD pin)"
  else
    bad "PreToolUse commit-ledger 'pre' hook is wired" \
      "absent — the sweep would have no per-call cursor to diff from"
  fi
  PRE_M=$(ev_matcher PreToolUse 'commit-ledger.sh" pre')
  if [ "$PRE_M" = "$LEDGER_MATCHER" ]; then
    ok "PreToolUse commit-ledger matcher is the widened '$LEDGER_MATCHER'"
  else
    bad "PreToolUse commit-ledger matcher is '$LEDGER_MATCHER'" "got '$PRE_M'"
  fi
  POST_M=$(ev_matcher PostToolUse 'commit-ledger.sh')
  if [ "$POST_M" = "$LEDGER_MATCHER" ]; then
    ok "PostToolUse commit-ledger matcher is the widened '$LEDGER_MATCHER'"
  else
    bad "PostToolUse commit-ledger matcher is '$LEDGER_MATCHER'" "got '$POST_M'"
  fi
  AB_M=$(ev_matcher PreToolUse 'auto-branch.sh')
  if [ "$AB_M" = "Write|Edit" ]; then
    ok "PreToolUse auto-branch matcher is still 'Write|Edit' (not widened)"
  else
    bad "PreToolUse auto-branch matcher is still 'Write|Edit'" "got '$AB_M'"
  fi

  # The installer's matcher must equal the plugin manifest's, or the two
  # distribution paths observe different tool sets.
  PLUGIN_HOOKS="$(cd "$(dirname "$0")/.." && pwd)/hooks/hooks.json"
  if [ -f "$PLUGIN_HOOKS" ]; then
    PM=$(jq -r '.hooks.PreToolUse[]? | select((.hooks[]?.command // "") | contains("commit-ledger")) | .matcher' \
      "$PLUGIN_HOOKS" 2>/dev/null)
    if [ "$PM" = "$LEDGER_MATCHER" ]; then
      ok "hooks/hooks.json commit-ledger matcher matches the installer's"
    else
      bad "hooks/hooks.json commit-ledger matcher matches the installer's" "plugin='$PM' installer='$LEDGER_MATCHER'"
    fi
  else
    bad "hooks/hooks.json present for the matcher-parity check" "missing"
  fi
else
  bad "settings.local.json is valid JSON" "missing or unparseable"
fi

# --- idempotency: a second install changes nothing ---------------------------
# install.sh is documented idempotent. Snapshot the installed tree, re-run, and
# require it byte-identical — this catches a re-copied file drifting as well as a
# duplicated hook entry in settings.local.json. .harness/ (live state) is excluded.
SNAP="$TMP/.claude-before"
cp -a "$CL" "$SNAP"
if bash "$INSTALL" "$TMP" >/dev/null 2>&1; then
  ok "install.sh exited 0 on re-run"
else
  bad "install.sh exited 0 on re-run" "non-zero"
fi
if diff -r -x '.harness' "$SNAP" "$CL" >/dev/null 2>&1; then
  ok "re-install is idempotent (installed .claude/ byte-identical)"
else
  bad "re-install is idempotent" \
    "$(diff -r -x '.harness' "$SNAP" "$CL" 2>&1 | head -3 | tr '\n' ' ')"
fi
if [ "$(grep -c 'done-gate.sh' "$CL/settings.local.json")" -eq 1 ]; then
  ok "re-install did not duplicate the Stop hook entry"
else
  bad "re-install did not duplicate the Stop hook entry" \
    "$(grep -c 'done-gate.sh' "$CL/settings.local.json") occurrences"
fi
if [ "$(jq '[.hooks.PreToolUse[]?.hooks[]?.command] | map(select(endswith("commit-ledger.sh\" pre"))) | length' "$CL/settings.local.json" 2>/dev/null)" = "1" ]; then
  ok "re-install did not duplicate the PreToolUse commit-ledger entry"
else
  bad "re-install did not duplicate the PreToolUse commit-ledger entry" \
    "$(jq -c '[.hooks.PreToolUse[]?.hooks[]?.command]' "$CL/settings.local.json" 2>/dev/null)"
fi
if [ "$(grep -cxF '.claude/.harness/' "$TMP/.gitignore")" -eq 1 ]; then
  ok "re-install did not duplicate the .gitignore entry"
else
  bad "re-install did not duplicate the .gitignore entry" \
    "$(grep -cxF '.claude/.harness/' "$TMP/.gitignore") occurrences"
fi

# --- UPGRADE: an existing install's STALE matcher must be widened in place ---
# The two cases above only cover a FRESH install and a re-install of the current
# version, so they both pass with a merge that keys its presence test on the
# COMMAND ALONE. That is what shipped: every already-installed project — the
# whole upgrade population — kept the narrow "Bash" matcher when the matcher
# widened, so a SlashCommand- or MCP-driven commit was never pinned or swept
# (empty ledger ⇒ base advances ⇒ Stop allowed with no DoD run). This is the
# genuine WIRING assertion; test-commit-ledger.sh's payload cases cannot make it,
# because the hook script never reads a matcher.
UPG=$(hc__test_mktemp_d)
mkdir -p "$UPG/.claude"
# Pre-seed exactly what the previous installer wrote: our commands, verbatim,
# under the OLD narrow matcher.
cat > "$UPG/.claude/settings.local.json" <<'EOJ'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/commit-ledger.sh\" pre" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/commit-ledger.sh\"" } ] }
    ]
  }
}
EOJ
if bash "$INSTALL" "$UPG" >/dev/null 2>&1; then
  ok "install.sh exited 0 over a pre-seeded old-matcher settings file"
else
  bad "install.sh exited 0 over a pre-seeded old-matcher settings file" "non-zero"
fi
US="$UPG/.claude/settings.local.json"
upg_matcher() {
  jq -r --arg e "$1" --arg c "$2" \
    '.hooks[$e][]? | select((.hooks[]?.command // "") | contains($c)) | .matcher // ""' \
    "$US" 2>/dev/null
}
upg_count() {
  jq --arg e "$1" --arg c "$2" \
    '[.hooks[$e][]? | select((.hooks[]?.command // "") | contains($c))] | length' \
    "$US" 2>/dev/null
}
for pair in "PreToolUse|commit-ledger.sh\" pre" "PostToolUse|commit-ledger.sh"; do
  EV="${pair%%|*}"; CMD="${pair#*|}"
  M=$(upg_matcher "$EV" "$CMD")
  if [ "$M" = "$LEDGER_MATCHER" ]; then
    ok "$EV stale 'Bash' matcher WIDENED in place to '$LEDGER_MATCHER'"
  else
    bad "$EV stale matcher widened to '$LEDGER_MATCHER'" "got '$M'"
  fi
  N=$(upg_count "$EV" "$CMD")
  if [ "$N" = "1" ]; then
    ok "$EV commit-ledger entry not duplicated by the upgrade"
  else
    bad "$EV commit-ledger entry not duplicated" "$N entries"
  fi
done
# Still idempotent over the upgraded file: a second run must change nothing.
UPG_SNAP=$(cat "$US" 2>/dev/null)
bash "$INSTALL" "$UPG" >/dev/null 2>&1
if [ "$UPG_SNAP" = "$(cat "$US" 2>/dev/null)" ]; then
  ok "re-install over the upgraded settings file is byte-identical (idempotent)"
else
  bad "re-install over the upgraded settings file is byte-identical" "settings.local.json changed"
fi
rm -rf "$UPG" 2>/dev/null

# ---------------------------------------------------------------------------
echo
echo "test-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
