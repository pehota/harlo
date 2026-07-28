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

# Source shared helpers for hc_validate + HC_CONTRACTS_DIR (write-time contract
# validation). Guarded on the file's presence, same as sibling scripts.
# shellcheck source=harness-common.sh
if [ -f "$(dirname "$0")/harness-common.sh" ]; then
  . "$(dirname "$0")/harness-common.sh" 2>/dev/null
fi

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

# --- write-time contract validation -----------------------------------------
# Validate an assembled config (in a tempfile) against the done-config schema
# before it is allowed to touch disk. Producer-side fail-closed: on any contract
# failure, print to stderr and return nonzero so the caller aborts the write and
# leaves existing state untouched. Only meaningful on the jq-available path
# (hc_validate itself requires jq); callers only invoke it there.
CONTRACT_SCHEMA="${HC_CONTRACTS_DIR:-}/done-config.schema.json"

validate_config_file() {
  # $1 = path to assembled candidate config JSON.
  local candidate="$1" out
  # If the validator or schema is unavailable, we cannot enforce — treat as a
  # hard failure so we never write an unvalidated config on the jq path.
  if ! type hc_validate >/dev/null 2>&1; then
    printf 'done-detect: hc_validate unavailable — cannot validate done-config against contract\n' >&2
    return 1
  fi
  out=$(hc_validate "$CONTRACT_SCHEMA" "$candidate" 2>&1)
  if [ $? -ne 0 ]; then
    printf 'done-detect: done-config failed contract %s: %s\n' "$CONTRACT_SCHEMA" "$out" >&2
    return 1
  fi
  return 0
}

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
  # contract_version stamps the config as conforming to schema v1.
  mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null
  TMP=$(mktemp 2>/dev/null)
  if [ -n "$TMP" ]; then
    jq -n \
      --argjson detected "$DETECTED_JSON" \
      --arg fp "$NEW_FP" '
      {
        contract_version: 1,
        source_fingerprint: $fp,
        detected: $detected,
        overrides: {},
        max_fix_attempts: 3,
        max_review_rounds: 2,
        baseline_snapshot: true,
        deploy_check_cmd: null,
        start_check_cmd: null,
        start_timeout: 30,
        trunk: null,
        auto_branch: true,
        branch_prefix: "task/",
        untracked_policy: "baseline",
        min_review_level: "high"
      }
    ' > "$TMP" 2>/dev/null
    # Write-time gate: only publish a contract-valid config.
    if validate_config_file "$TMP"; then
      mv "$TMP" "$CONFIG_FILE" 2>/dev/null
    else
      rm -f "$TMP" 2>/dev/null
      emit_effective
      exit 1
    fi
    [ -f "$TMP" ] && rm -f "$TMP" 2>/dev/null
  fi

else
  # Config already exists. Two independent reasons to rewrite:
  #   (a) the source fingerprint changed → refresh the detected block, OR
  #   (b) the config predates contract v1 (missing/mismatched contract_version)
  #       → auto-upgrade in place.
  # Both are handled by the SAME targeted jq merge so that upgrade also seeds
  # any keys added in later versions, while PRESERVING every human-owned field
  # (overrides, max_fix_attempts, baseline_snapshot, deploy_check_cmd, trunk,
  # identity + review keys). The merge only touches .detected/.source_fingerprint
  # when the fingerprint actually changed; otherwise it re-uses the stored values
  # so an upgrade-only run stays a minimal, idempotent change.
  STORED_CV=$(jq -r '.contract_version // empty' "$CONFIG_FILE" 2>/dev/null)
  NEEDS_UPGRADE=false
  [ "$STORED_CV" != "1" ] && NEEDS_UPGRADE=true
  NEEDS_REFRESH=false
  [ "$STORED_FP" != "$NEW_FP" ] && NEEDS_REFRESH=true

  if [ "$NEEDS_UPGRADE" = true ] || [ "$NEEDS_REFRESH" = true ]; then
    # On a pure upgrade (no fingerprint change) keep the stored detected block and
    # fingerprint intact; on a refresh, replace them with the freshly detected
    # values. The seed-if-absent, preserve-if-present rule (via
    # `if has(...) then . else .k = default end`) never clobbers an existing
    # value — including a literal `false`.
    TMP=$(mktemp 2>/dev/null)
    if [ -n "$TMP" ]; then
      jq \
        --argjson detected "$DETECTED_JSON" \
        --arg fp "$NEW_FP" \
        --argjson refresh "$([ "$NEEDS_REFRESH" = true ] && echo true || echo false)" '
        (if $refresh then (.detected = $detected | .source_fingerprint = $fp) else . end)
        | .contract_version = 1
        | (if has("overrides") then . else .overrides = {} end)
        | (if has("max_fix_attempts") then . else .max_fix_attempts = 3 end)
        | (if has("baseline_snapshot") then . else .baseline_snapshot = true end)
        | (if has("trunk") then . else .trunk = null end)
        | (if has("auto_branch") then . else .auto_branch = true end)
        | (if has("branch_prefix") then . else .branch_prefix = "task/" end)
        | (if has("untracked_policy") then . else .untracked_policy = "baseline" end)
        | (if has("max_review_rounds") then . else .max_review_rounds = 2 end)
        | (if has("min_review_level") then . else .min_review_level = "high" end)
        | (if has("start_check_cmd") then . else .start_check_cmd = null end)
        | (if has("start_timeout") then . else .start_timeout = 30 end)
      ' "$CONFIG_FILE" > "$TMP" 2>/dev/null
      # Write-time gate: never overwrite existing valid state with an invalid one.
      if validate_config_file "$TMP"; then
        mv "$TMP" "$CONFIG_FILE" 2>/dev/null
      else
        rm -f "$TMP" 2>/dev/null
        emit_effective
        exit 1
      fi
      [ -f "$TMP" ] && rm -f "$TMP" 2>/dev/null
    fi
  fi
  # else: fingerprint unchanged AND already at contract v1 → leave the file
  # exactly as-is (idempotent — a second run is byte-identical).
fi

emit_effective
exit 0
