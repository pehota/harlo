#!/bin/bash
#
# Tests for the SHARED probe helpers in harness-common.sh — hc_pkg_probe and
# hc_hash_stdin — which done-detect.sh (Step 0 config) and worktree-detect.sh
# (worktree provisioning) both call so the two can never derive a different
# package manager for the same repo.
#
# Each case is a throwaway tmpdir with only the probe files under test in it;
# no git repo is needed because the probe reads the filesystem, not the index.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
# shellcheck source=../scripts/harness-common.sh
. "$SCRIPTS/harness-common.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

CLEANUP=()
trap 'for d in "${CLEANUP[@]}"; do rm -rf "$d" 2>/dev/null; done' EXIT

# mk <file>... → a fresh tmpdir containing each named (empty) file. Echoes it.
mk() {
  local d; d=$(mktemp -d); CLEANUP+=("$d")
  local f
  for f in "$@"; do : > "$d/$f"; done
  printf '%s' "$d"
}

# probe_is <label> <expected_mgr> <expected_lockfile> <file>...
probe_is() {
  local label="$1" want_mgr="$2" want_lock="$3"; shift 3
  local d; d=$(mk "$@")
  hc_pkg_probe "$d"
  if [ "$HC_PKG_MGR" = "$want_mgr" ] && [ "$HC_LOCKFILE" = "$want_lock" ]; then
    ok "$label → mgr='$want_mgr' lockfile='$want_lock'"
  else
    bad "$label → got mgr='$HC_PKG_MGR' lockfile='$HC_LOCKFILE' (want '$want_mgr'/'$want_lock')"
  fi
}

echo "== test-pkg-probe =="

echo "-- hc_pkg_probe: lockfile → manager --"
probe_is "pnpm-lock.yaml"     pnpm pnpm-lock.yaml     pnpm-lock.yaml package.json
probe_is "yarn.lock"          yarn yarn.lock          yarn.lock package.json
probe_is "package-lock.json"  npm  package-lock.json  package-lock.json package.json
# A bare package.json is still a Node project (npm is the default runner), but
# the LOCKFILE stays "none" — the two are reported separately on purpose so a
# lockfile appearing later moves the fingerprint.
probe_is "bare package.json"  npm  none               package.json
# Not a Node project at all: empty manager, no lockfile. Degrades, never errors.
probe_is "no node files"      ""   none               README.md

echo "-- hc_pkg_probe: precedence when several lockfiles coexist --"
probe_is "pnpm beats yarn+npm" pnpm pnpm-lock.yaml \
  pnpm-lock.yaml yarn.lock package-lock.json package.json
probe_is "yarn beats npm"      yarn yarn.lock \
  yarn.lock package-lock.json package.json

echo "-- hc_pkg_probe: yarn berry detection is a FILE probe --"
D=$(mk yarn.lock package.json)
hc_pkg_probe "$D"
if [ "$HC_YARN_BERRY" = "0" ]; then
  ok "yarn classic (no .yarnrc.yml) → HC_YARN_BERRY=0"
else
  bad "yarn classic → HC_YARN_BERRY='$HC_YARN_BERRY' (want 0)"
fi
D=$(mk yarn.lock package.json .yarnrc.yml)
hc_pkg_probe "$D"
if [ "$HC_YARN_BERRY" = "1" ]; then
  ok "yarn berry (.yarnrc.yml present) → HC_YARN_BERRY=1"
else
  bad "yarn berry → HC_YARN_BERRY='$HC_YARN_BERRY' (want 1)"
fi

echo "-- hc_pkg_probe: no leaked state between calls --"
D=$(mk pnpm-lock.yaml package.json)
hc_pkg_probe "$D"
D2=$(mk README.md)
hc_pkg_probe "$D2"
if [ -z "$HC_PKG_MGR" ] && [ "$HC_LOCKFILE" = "none" ] && [ "$HC_YARN_BERRY" = "0" ]; then
  ok "a second call fully resets the globals (no stale pnpm)"
else
  bad "globals leaked across calls: mgr='$HC_PKG_MGR' lock='$HC_LOCKFILE' berry='$HC_YARN_BERRY'"
fi

echo "-- hc_pkg_probe: missing project dir degrades, returns 0 --"
hc_pkg_probe "/nonexistent/path/$$"
RC=$?
if [ "$RC" -eq 0 ] && [ -z "$HC_PKG_MGR" ]; then
  ok "missing project dir → empty manager, rc0"
else
  bad "missing project dir → mgr='$HC_PKG_MGR' rc=$RC"
fi

echo "-- hc_hash_stdin --"
H1=$(printf 'alpha' | hc_hash_stdin)
H2=$(printf 'alpha' | hc_hash_stdin)
H3=$(printf 'beta'  | hc_hash_stdin)
if [ -n "$H1" ]; then ok "produces a non-empty digest"; else bad "empty digest"; fi
if [ "$H1" = "$H2" ]; then ok "is deterministic for identical input"; else bad "non-deterministic: '$H1' vs '$H2'"; fi
if [ "$H1" != "$H3" ]; then ok "differs for different input"; else bad "collision: 'alpha' and 'beta' both '$H1'"; fi
case "$H1" in
  *[!0-9a-f]*) bad "digest is not lowercase hex: '$H1'" ;;
  *)           ok "digest is lowercase hex" ;;
esac

echo "-- done-detect.sh still derives the manager from the shared probe --"
# The behavioural contract of the extraction: done-detect's `detected` block is
# unchanged. test-detect.sh pins the npm path; this pins the pnpm one, which is
# the branch worktree-detect.sh cares most about.
D=$(mk pnpm-lock.yaml)
mkdir -p "$D/.claude"
cat > "$D/package.json" <<'JSON'
{ "name": "x", "scripts": { "test": "vitest", "build": "tsc" } }
JSON
OUT=$(CLAUDE_PROJECT_DIR="$D" bash "$SCRIPTS/done-detect.sh" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.package_manager == "pnpm" and .test == "pnpm test"' >/dev/null 2>&1; then
  ok "done-detect reports package_manager=pnpm and 'pnpm test' via hc_pkg_probe"
else
  bad "done-detect pnpm path changed; got: $OUT"
fi

echo
echo "test-pkg-probe: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
