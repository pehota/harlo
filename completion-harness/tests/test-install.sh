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

PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1 (got: ${2:-})"; FAIL=$((FAIL+1)); }

echo "== test-install =="

if [ ! -f "$INSTALL" ]; then
  bad "install.sh not found at $INSTALL"
  echo; echo "test-install: $PASS passed, $FAIL failed"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  bad "jq unavailable — cannot verify contracts"
  echo; echo "test-install: $PASS passed, $FAIL failed"; exit 1
fi

TMP=$(mktemp -d)
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

# ---------------------------------------------------------------------------
echo
echo "test-install: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
