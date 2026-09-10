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
         done-triage.sh done-preflight.sh harness-common.sh harness-resolve.sh \
         commit-ledger.sh; do
  if [ -f "$CL/scripts/$s" ]; then
    ok "shipped scripts/$s"
  else
    bad "shipped scripts/$s" "missing"
  fi
done

# Executable bit — every shipped script EXCEPT harness-common.sh (SOURCED, stays
# non-exec by install.sh's chmod list).
for s in done-gate.sh baseline-snapshot.sh done-detect.sh done-write-state.sh \
         done-triage.sh done-preflight.sh harness-resolve.sh commit-ledger.sh; do
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

  # PreToolUse: the commit-ledger `pre` pin, on the widened matcher.
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
  # A FRESH install wires exactly ONE PreToolUse entry: the ledger pin. This
  # says nothing about upgrades — this target never had a previous install, so
  # there is nothing stale to survive. Stale-hook survival is proved by the
  # "UPGRADE from 60826f9" fixture near the end of this file, which installs a
  # real older bundle first; this assertion only pins the fresh-install shape
  # (a second entry here would mean the installer wired something extra).
  PRE_N=$(jq '[.hooks.PreToolUse[]?] | length' "$SET" 2>/dev/null)
  if [ "$PRE_N" = "1" ]; then
    ok "fresh install wires exactly one PreToolUse entry (the ledger pin)"
  else
    bad "fresh install wires exactly one PreToolUse entry" "got $PRE_N"
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

# --- UPGRADE from a REAL older bundle: retired artifacts must be pruned ------
# Everything above installs only the CURRENT bundle, so nothing above can see
# what the installer does to an install made by an OLDER one. That is how the
# auto-branch removal shipped broken: install.sh only copied and appended, so
# .claude/scripts/auto-branch.sh stayed on disk (+x) and its
# PreToolUse(Write|Edit) hook entry stayed in settings.local.json — the feature
# stayed LIVE for the entire existing non-plugin population while this suite
# was green.
#
# So install the bundle AS IT EXISTED at 60826f9 (the last commit that shipped
# auto-branching) into a throwaway target via `git archive` — no worktree, no
# checkout, nothing touched in the developer's tree — then install the current
# bundle over it and assert BOTH directions:
#   pruned    : the retired script file and hook entry are gone, and the
#               removal is REPORTED on stdout (a destructive step must not be
#               silent).
#   preserved : user-owned state survives untouched — an unrelated top-level
#               key, a script of theirs sitting in .claude/scripts/, and three
#               hook entries that the prune must not touch:
#                 (a) one pointing OUTSIDE .claude/scripts/ (fails the location
#                     test — the weakest of the three, it would survive even a
#                     location-only prune),
#                 (b) one pointing INSIDE .claude/scripts/ at a script of
#                     theirs that is present and carries no harness marker
#                     (this is the one that needs real two-signal ownership; a
#                     location-only prune DELETES it), and
#                 (c) a MIXED entry — one retired-harness command plus one
#                     user command — which the all-commands rule keeps intact.
#               This half is what stops a future "prune" from eating somebody's
#               config.
OLD_SHA=60826f9
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
if git -C "$REPO" cat-file -e "$OLD_SHA^{commit}" 2>/dev/null; then
  OLDB=$(hc__test_mktemp_d)   # extracted old bundle
  OT=$(hc__test_mktemp_d)     # upgrade target
  if git -C "$REPO" archive "$OLD_SHA" completion-harness 2>/dev/null \
       | tar -x -C "$OLDB" 2>/dev/null && [ -f "$OLDB/completion-harness/install.sh" ]; then
    ok "extracted the $OLD_SHA bundle for the upgrade fixture"

    if bash "$OLDB/completion-harness/install.sh" "$OT" >/dev/null 2>&1; then
      ok "the $OLD_SHA installer exited 0 into the upgrade target"
    else
      bad "the $OLD_SHA installer exited 0 into the upgrade target" "non-zero"
    fi

    OS="$OT/.claude/settings.local.json"
    STALE_SCRIPT="$OT/.claude/scripts/auto-branch.sh"
    # Fixture precondition — if the OLD install did not leave the stale
    # artifacts, the post-upgrade assertions below would pass vacuously.
    if [ -f "$STALE_SCRIPT" ]; then
      ok "fixture precondition: $OLD_SHA left scripts/auto-branch.sh behind"
    else
      bad "fixture precondition: $OLD_SHA left scripts/auto-branch.sh behind" "absent"
    fi
    if jq -e '[.. | objects | .command? // empty] | any(contains("auto-branch.sh"))' \
         "$OS" >/dev/null 2>&1; then
      ok "fixture precondition: $OLD_SHA wired the auto-branch hook entry"
    else
      bad "fixture precondition: $OLD_SHA wired the auto-branch hook entry" "absent"
    fi

    # Seed USER-OWNED state before the upgrade, all on PreToolUse — the very
    # event being pruned: the three hook entries (a)/(b)/(c) described above,
    # an unrelated top-level key, and scripts of their own inside
    # .claude/scripts/ that carry no harness header marker.
    # (a) outside .claude/scripts/ entirely.
    OUT_CMD='bash "$CLAUDE_PROJECT_DIR/scripts/my-own-hook.sh"'
    # (b) INSIDE .claude/scripts/ — the case a location-only ownership test
    #     destroys. The script it names is seeded present and UNMARKED below.
    IN_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/my-own-lint.sh"'
    # (c) mixed: the retired harness command beside a user command.
    MIX_HARNESS_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/auto-branch.sh"'
    MIX_USER_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/my-own-fmt.sh"'
    SEEDED=$(jq --arg o "$OUT_CMD" --arg i "$IN_CMD" \
                --arg mh "$MIX_HARNESS_CMD" --arg mu "$MIX_USER_CMD" '
      .hooks.PreToolUse += [
          {"matcher":"Write","hooks":[{"type":"command","command":$o}]},
          {"matcher":"Write","hooks":[{"type":"command","command":$i}]},
          {"matcher":"Edit","hooks":[{"type":"command","command":$mh},
                                     {"type":"command","command":$mu}]}
        ]
      | .permissions = {"allow":["Bash(ls:*)"]}
    ' "$OS" 2>/dev/null)
    printf '%s\n' "$SEEDED" > "$OS"
    USER_SCRIPT="$OT/.claude/scripts/my-project-helper.sh"
    printf '#!/bin/bash\n# a script this project put here itself\n' > "$USER_SCRIPT"
    # The script hook (b)/(c) reference: present, no harness header marker.
    USER_HOOK_SCRIPT="$OT/.claude/scripts/my-own-lint.sh"
    printf '#!/bin/bash\n# this project wired its own hook at this path\n' \
      > "$USER_HOOK_SCRIPT"
    MIX_USER_SCRIPT="$OT/.claude/scripts/my-own-fmt.sh"
    printf '#!/bin/bash\n# the user half of the mixed hook entry\n' \
      > "$MIX_USER_SCRIPT"

    UPG_OUT="$OT/.install-output.txt"
    if bash "$INSTALL" "$OT" >"$UPG_OUT" 2>&1; then
      ok "current install.sh exited 0 over the $OLD_SHA install"
    else
      bad "current install.sh exited 0 over the $OLD_SHA install" "non-zero"
    fi

    # --- pruned ---
    if [ -e "$STALE_SCRIPT" ]; then
      bad "upgrade pruned the retired scripts/auto-branch.sh" "still present"
    else
      ok "upgrade pruned the retired scripts/auto-branch.sh"
    fi
    # The MIXED entry (c) keeps a command naming auto-branch.sh on purpose, so
    # this asserts the retired ALL-OURS entry is gone: exactly one entry still
    # names auto-branch.sh, and it is the two-command mixed one.
    AB_ENTRIES=$(jq '[.hooks.PreToolUse[]?
                      | select([.hooks[]?.command // ""] | any(contains("auto-branch.sh")))]' \
                   "$OS" 2>/dev/null)
    if [ "$(printf '%s' "$AB_ENTRIES" | jq 'length' 2>/dev/null)" = "1" ] \
       && [ "$(printf '%s' "$AB_ENTRIES" | jq '.[0].hooks | length' 2>/dev/null)" = "2" ]; then
      ok "upgrade pruned the retired auto-branch hook entry"
    else
      bad "upgrade pruned the retired auto-branch hook entry" \
        "$(jq -c '.hooks.PreToolUse' "$OS" 2>/dev/null)"
    fi
    # Part 2: a destructive step must say what it removed.
    if grep -q 'pruned retired hook entry.*auto-branch\.sh' "$UPG_OUT" 2>/dev/null; then
      ok "upgrade REPORTED the pruned hook entry on stdout"
    else
      bad "upgrade REPORTED the pruned hook entry on stdout" \
        "$(grep -c . "$UPG_OUT" 2>/dev/null) lines, no prune report"
    fi

    # --- preserved ---
    # (a) points outside .claude/scripts/ — proves only that the location test
    #     is required, NOT that ownership is checked.
    if [ "$(jq --arg u "$OUT_CMD" \
              '[.hooks.PreToolUse[]? | select((.hooks[]?.command // "") == $u)] | length' \
              "$OS" 2>/dev/null)" = "1" ]; then
      ok "upgrade preserved the user hook entry pointing OUTSIDE .claude/scripts/"
    else
      bad "upgrade preserved the user hook entry pointing OUTSIDE .claude/scripts/" \
        "$(jq -c '.hooks.PreToolUse' "$OS" 2>/dev/null)"
    fi
    # (b) THE regression guard: inside .claude/scripts/, script present and
    #     unmarked. A location-only ownership test deletes this.
    if [ "$(jq --arg u "$IN_CMD" \
              '[.hooks.PreToolUse[]? | select((.hooks[]?.command // "") == $u)] | length' \
              "$OS" 2>/dev/null)" = "1" ]; then
      ok "upgrade preserved the user hook entry INSIDE .claude/scripts/ (present, unmarked)"
    else
      bad "upgrade preserved the user hook entry INSIDE .claude/scripts/ (present, unmarked)" \
        "$(jq -c '.hooks.PreToolUse' "$OS" 2>/dev/null)"
    fi
    # (c) mixed entry survives INTACT — both commands, per the all-commands rule.
    if [ "$(jq --arg h "$MIX_HARNESS_CMD" --arg u "$MIX_USER_CMD" \
              '[.hooks.PreToolUse[]?
                | select([.hooks[]?.command // ""] == [$h, $u])] | length' \
              "$OS" 2>/dev/null)" = "1" ]; then
      ok "upgrade preserved the MIXED hook entry intact (harness + user command)"
    else
      bad "upgrade preserved the MIXED hook entry intact (harness + user command)" \
        "$(jq -c '.hooks.PreToolUse' "$OS" 2>/dev/null)"
    fi
    if [ -f "$USER_HOOK_SCRIPT" ] && [ -f "$MIX_USER_SCRIPT" ]; then
      ok "upgrade preserved the user hook SCRIPTS inside .claude/scripts/"
    else
      bad "upgrade preserved the user hook SCRIPTS inside .claude/scripts/" "deleted"
    fi
    if [ "$(jq -c '.permissions' "$OS" 2>/dev/null)" = '{"allow":["Bash(ls:*)"]}' ]; then
      ok "upgrade preserved the user-owned unrelated settings key"
    else
      bad "upgrade preserved the user-owned unrelated settings key" \
        "$(jq -c '.permissions' "$OS" 2>/dev/null)"
    fi
    if [ -f "$USER_SCRIPT" ]; then
      ok "upgrade preserved a user-owned script inside .claude/scripts/"
    else
      bad "upgrade preserved a user-owned script inside .claude/scripts/" "deleted"
    fi

    # Pruning must be idempotent too: nothing left to prune, nothing changes.
    OT_SNAP=$(cat "$OS" 2>/dev/null)
    bash "$INSTALL" "$OT" >/dev/null 2>&1
    if [ "$OT_SNAP" = "$(cat "$OS" 2>/dev/null)" ]; then
      ok "re-install after the prune is byte-identical (idempotent)"
    else
      bad "re-install after the prune is byte-identical" "settings.local.json changed"
    fi
  else
    bad "extracted the $OLD_SHA bundle for the upgrade fixture" "git archive failed"
  fi
  rm -rf "$OLDB" "$OT" 2>/dev/null
else
  bad "upgrade fixture can reach commit $OLD_SHA" \
    "object unavailable — the upgrade-prune assertions did not run"
fi

# --- FRESH install: a user's own in-.claude/scripts hook must survive --------
# The prune runs on EVERY install, not only upgrades, so the destructive path is
# reachable on a first install into a project that already wired hooks of its
# own. No prior harness install here, so no earlier prune pass can have removed
# anything: the only ownership signal available is "present and unmarked", and
# it must be enough to protect the entry.
FR=$(hc__test_mktemp_d)
mkdir -p "$FR/.claude/scripts"
FR_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/my-own-lint.sh"'
printf '#!/bin/bash\n# a hook this project wired before the harness existed\n' \
  > "$FR/.claude/scripts/my-own-lint.sh"
jq -n --arg u "$FR_CMD" \
  '{hooks:{PreToolUse:[{matcher:"Write",hooks:[{type:"command",command:$u}]}]}}' \
  > "$FR/.claude/settings.local.json"

if bash "$INSTALL" "$FR" >/dev/null 2>&1; then
  ok "install.sh exited 0 on a fresh install over pre-existing user hooks"
else
  bad "install.sh exited 0 on a fresh install over pre-existing user hooks" "non-zero"
fi
FRS="$FR/.claude/settings.local.json"
if [ "$(jq --arg u "$FR_CMD" \
          '[.hooks.PreToolUse[]? | select((.hooks[]?.command // "") == $u)] | length' \
          "$FRS" 2>/dev/null)" = "1" ]; then
  ok "FRESH install preserved the user hook INSIDE .claude/scripts/ (present, unmarked)"
else
  bad "FRESH install preserved the user hook INSIDE .claude/scripts/ (present, unmarked)" \
    "$(jq -c '.hooks.PreToolUse' "$FRS" 2>/dev/null)"
fi
if [ -f "$FR/.claude/scripts/my-own-lint.sh" ]; then
  ok "FRESH install preserved the user's script inside .claude/scripts/"
else
  bad "FRESH install preserved the user's script inside .claude/scripts/" "deleted"
fi
rm -rf "$FR" 2>/dev/null

# ---------------------------------------------------------------------------
echo
echo "test-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
