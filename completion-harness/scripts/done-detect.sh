#!/bin/bash
#
# Completion Harness — /done Step 0: config detect / refresh.
#
# Deterministic project probing so the LLM never guesses command names.
# Probes lockfiles + package.json/Cargo.toml/go.mod/pyproject/Makefile,
# recomputes a source_fingerprint, and — only if the config is missing or the
# fingerprint changed — rewrites the `detected` block via a targeted jq merge
# that PRESERVES the human-owned sticky fields (overrides, max_fix_attempts,
# baseline_snapshot, deploy_check_cmd). Idempotent: an unchanged source never
# touches the file. Always emits the EFFECTIVE config (overrides over detected)
# to stdout for the caller.
#
# Fail-safe: no `set -e`; every jq/git/file read is guarded; on any unexpected
# problem it exits 0 with best-effort output so /done is never blocked.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"

have_jq=false
command -v jq >/dev/null 2>&1 && have_jq=true

# --- hashing helper (deterministic over stdin) ------------------------------
hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  else
    # Last-resort stable-ish fallback; length + cksum.
    cksum 2>/dev/null | cut -d' ' -f1
  fi
}

# --- detect package manager via lockfile ------------------------------------
PKG_MGR="null"
if [ -f "$PROJECT_DIR/pnpm-lock.yaml" ]; then
  PKG_MGR="pnpm"
elif [ -f "$PROJECT_DIR/yarn.lock" ]; then
  PKG_MGR="yarn"
elif [ -f "$PROJECT_DIR/package-lock.json" ]; then
  PKG_MGR="npm"
elif [ -f "$PROJECT_DIR/package.json" ]; then
  PKG_MGR="npm"  # default runner for a Node project with no lockfile
fi

# Lockfile name feeds the fingerprint (a lockfile appearing/disappearing is a
# meaningful source change).
LOCKFILE_NAME="none"
for lf in pnpm-lock.yaml yarn.lock package-lock.json; do
  if [ -f "$PROJECT_DIR/$lf" ]; then LOCKFILE_NAME="$lf"; break; fi
done

# --- detect commands + fingerprint source -----------------------------------
# DETECTED_JSON is a jq object literal built up below.
# FP_SOURCE is the exact text hashed into source_fingerprint.
DET_TEST="null"; DET_BUILD="null"; DET_START="null"; DET_LINT="null"
FP_SOURCE=""

runner_cmd() {
  # $1 = npm script name → the invocation string for the detected package mgr.
  local script="$1"
  case "$PKG_MGR" in
    pnpm) printf 'pnpm %s' "$script" ;;
    yarn) printf 'yarn %s' "$script" ;;
    *)    printf 'npm run %s' "$script" ;;
  esac
}

if [ -f "$PROJECT_DIR/package.json" ] && [ "$have_jq" = true ]; then
  # The scripts block is the fingerprint source for a Node project.
  SCRIPTS_JSON=$(jq -c '.scripts // {}' "$PROJECT_DIR/package.json" 2>/dev/null)
  [ -z "$SCRIPTS_JSON" ] && SCRIPTS_JSON="{}"
  FP_SOURCE="node:${LOCKFILE_NAME}:${SCRIPTS_JSON}"

  has_script() { jq -e --arg k "$1" '.scripts | has($k)' "$PROJECT_DIR/package.json" >/dev/null 2>&1; }

  has_script test  && DET_TEST=$(runner_cmd test)
  has_script build && DET_BUILD=$(runner_cmd build)
  has_script lint  && DET_LINT=$(runner_cmd lint)
  # start OR dev (start preferred).
  if has_script start; then
    DET_START=$(runner_cmd start)
  elif has_script dev; then
    DET_START=$(runner_cmd dev)
  fi

elif [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  DET_TEST="cargo test"; DET_BUILD="cargo build"; DET_START="cargo run"
  FP_SOURCE="cargo:$(cat "$PROJECT_DIR/Cargo.toml" 2>/dev/null)"

elif [ -f "$PROJECT_DIR/go.mod" ]; then
  DET_TEST="go test ./..."; DET_BUILD="go build ./..."
  FP_SOURCE="go:$(cat "$PROJECT_DIR/go.mod" 2>/dev/null)"

elif [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/pytest.ini" ]; then
  DET_TEST="pytest"
  FP_SOURCE="py:$(cat "$PROJECT_DIR/pyproject.toml" "$PROJECT_DIR/pytest.ini" 2>/dev/null)"

elif [ -f "$PROJECT_DIR/Makefile" ]; then
  # Detect targets by name.
  MK=$(cat "$PROJECT_DIR/Makefile" 2>/dev/null)
  printf '%s' "$MK" | grep -qE '^test:'  && DET_TEST="make test"
  printf '%s' "$MK" | grep -qE '^build:' && DET_BUILD="make build"
  printf '%s' "$MK" | grep -qE '^run:'   && DET_START="make run"
  FP_SOURCE="make:$MK"
fi

# If nothing matched, still produce a stable (empty) fingerprint source.
[ -z "$FP_SOURCE" ] && FP_SOURCE="none"

NEW_FP=$(printf '%s' "$FP_SOURCE" | hash_stdin)
[ -z "$NEW_FP" ] && NEW_FP="unknown"

# --- build the detected object (jq) -----------------------------------------
# Emit as a compact JSON object, dropping null-valued keys.
build_detected() {
  [ "$have_jq" = true ] || { printf '{}'; return; }
  jq -nc \
    --arg pm "$PKG_MGR" \
    --arg t "$DET_TEST" \
    --arg b "$DET_BUILD" \
    --arg s "$DET_START" \
    --arg l "$DET_LINT" '
    {
      package_manager: (if $pm == "null" then null else $pm end),
      test:  (if $t == "null" then null else $t end),
      build: (if $b == "null" then null else $b end),
      start: (if $s == "null" then null else $s end),
      lint:  (if $l == "null" then null else $l end)
    }
    | with_entries(select(.value != null))
  ' 2>/dev/null
}

DETECTED_JSON=$(build_detected)
[ -z "$DETECTED_JSON" ] && DETECTED_JSON="{}"

# --- decide whether to (re)write the config ---------------------------------
STORED_FP=""
if [ -f "$CONFIG_FILE" ] && [ "$have_jq" = true ]; then
  STORED_FP=$(jq -r '.source_fingerprint // ""' "$CONFIG_FILE" 2>/dev/null)
fi

emit_effective() {
  # effective = detected * overrides  (overrides win on flat keys).
  if [ "$have_jq" = true ] && [ -f "$CONFIG_FILE" ]; then
    jq -c '((.detected // {}) * (.overrides // {}))' "$CONFIG_FILE" 2>/dev/null && return
  fi
  # No file yet: effective == detected.
  printf '%s\n' "$DETECTED_JSON"
}

if [ "$have_jq" != true ]; then
  # Can't safely rewrite JSON without jq; emit best-effort and bail.
  emit_effective
  exit 0
fi

if [ ! -f "$CONFIG_FILE" ]; then
  # Missing: seed the full starter shape (matches installer) with fresh detect.
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
  jq -n \
    --argjson detected "$DETECTED_JSON" \
    --arg fp "$NEW_FP" '
    {
      source_fingerprint: $fp,
      detected: $detected,
      overrides: {},
      max_fix_attempts: 3,
      baseline_snapshot: true,
      deploy_check_cmd: null
    }
  ' > "$CONFIG_FILE" 2>/dev/null

elif [ "$STORED_FP" != "$NEW_FP" ]; then
  # Changed: targeted merge — replace only detected + fingerprint, preserve rest.
  TMP=$(mktemp 2>/dev/null)
  if [ -n "$TMP" ]; then
    jq \
      --argjson detected "$DETECTED_JSON" \
      --arg fp "$NEW_FP" '
      .detected = $detected
      | .source_fingerprint = $fp
    ' "$CONFIG_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$CONFIG_FILE" 2>/dev/null
    [ -f "$TMP" ] && rm -f "$TMP" 2>/dev/null
  fi
fi
# else: fingerprint unchanged → leave the file exactly as-is (idempotent).

emit_effective
exit 0
