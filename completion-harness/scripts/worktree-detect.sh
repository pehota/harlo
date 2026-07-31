#!/bin/bash
#
# Completion Harness — worktree provisioning probe.
#
# Deterministic project probing so new-worktree.sh never guesses how to install
# dependencies or which gitignored config a fresh checkout is missing. Mirrors
# done-detect.sh exactly: probe files, never guess; recompute a
# source_fingerprint and rewrite the `detected` block ONLY when the source
# changed; PRESERVE the human-owned `overrides` across every re-detection;
# always emit the EFFECTIVE config (overrides over detected) on stdout.
#
# Namespaced under the `worktree` key of the SAME .claude/done-config.json that
# done-detect.sh owns — one config file, two independently-fingerprinted blocks.
# done-detect's merge is key-targeted, so it never clobbers this block, and this
# script never touches .detected/.overrides at the top level.
#
# Fail-safe: no `set -e`; every jq/git/file read is guarded; on any unexpected
# problem it exits 0 with best-effort output so provisioning is never blocked by
# the probe itself.
#
# WHAT IS DELIBERATELY *NOT* DETECTED: setup_cmd is always null in `detected`.
# A setup target found by heuristic is exactly how a provisioning script drops a
# database or overwrites a shared .env. Candidates are reported in
# `setup_candidates` for a human to promote into `overrides.setup_cmd`; nothing
# else ever makes one runnable.

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
CONFIG_FILE="$PROJECT_DIR/.claude/done-config.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

have_jq=false
command -v jq >/dev/null 2>&1 && have_jq=true

# --- filter limits ----------------------------------------------------------
# Overridable by env so the test suite can drive each ceiling without building a
# 100-deep tree or a 65 KiB fixture. Defaults are the shipped policy.
#
#   DEPTH  path components (".envrc" is 1; "a/b/c/d/.env" is 5). A depth cap is
#          what stops a deep ignored tree from exploding the candidate list.
#   BYTES  per-file ceiling. A "config" file is small; anything large is a
#          build artefact or a cache wearing a config-ish name.
#   LINK   hard cap on how many files are linked/reported in one list. Anything
#          beyond it is REPORTED in the overflow list, never silently dropped.
WT_MAX_DEPTH="${HC_WT_MAX_DEPTH:-5}"
WT_MAX_BYTES="${HC_WT_MAX_BYTES:-65536}"
WT_MAX_LINK="${HC_WT_MAX_LINK:-50}"

# --- install_cmd: lockfile → command ----------------------------------------
# Prefer the OFFLINE/FROZEN form wherever the tool has one. A fresh worktree
# should link from the shared store and honour the lockfile that is already in
# the tree, not re-resolve the dependency graph from the network.
#
# Node comes from the SHARED probe (hc_pkg_probe) so this script and
# done-detect.sh can never disagree about which package manager a repo uses.
# Everything else is a direct file probe, in a fixed precedence order.
INSTALL_CMD="null"
INSTALL_SOURCE="none"

if type hc_pkg_probe >/dev/null 2>&1; then
  hc_pkg_probe "$PROJECT_DIR"
fi

case "${HC_PKG_MGR:-}" in
  pnpm)
    INSTALL_CMD="pnpm install --prefer-offline"
    INSTALL_SOURCE="$HC_LOCKFILE" ;;
  yarn)
    # Berry vs classic is a FILE probe (.yarnrc.yml), not a version guess —
    # the frozen flag differs and the wrong one is a hard install failure.
    if [ "${HC_YARN_BERRY:-0}" = "1" ]; then
      INSTALL_CMD="yarn install --immutable"
    else
      INSTALL_CMD="yarn install --frozen-lockfile"
    fi
    INSTALL_SOURCE="$HC_LOCKFILE" ;;
  npm)
    # `npm ci` requires a lockfile; a bare package.json has none, so it must
    # fall back to a plain install rather than failing on arrival.
    if [ "${HC_LOCKFILE:-none}" = "package-lock.json" ]; then
      INSTALL_CMD="npm ci"
      INSTALL_SOURCE="package-lock.json"
    else
      INSTALL_CMD="npm install"
      INSTALL_SOURCE="package.json"
    fi ;;
esac

if [ "$INSTALL_CMD" = "null" ]; then
  if   [ -f "$PROJECT_DIR/Cargo.lock" ];        then INSTALL_CMD="cargo fetch --locked";                INSTALL_SOURCE="Cargo.lock"
  elif [ -f "$PROJECT_DIR/Cargo.toml" ];        then INSTALL_CMD="cargo fetch";                         INSTALL_SOURCE="Cargo.toml"
  elif [ -f "$PROJECT_DIR/go.sum" ];            then INSTALL_CMD="go mod download";                     INSTALL_SOURCE="go.sum"
  elif [ -f "$PROJECT_DIR/go.mod" ];            then INSTALL_CMD="go mod download";                     INSTALL_SOURCE="go.mod"
  elif [ -f "$PROJECT_DIR/uv.lock" ];           then INSTALL_CMD="uv sync --frozen";                    INSTALL_SOURCE="uv.lock"
  elif [ -f "$PROJECT_DIR/poetry.lock" ];       then INSTALL_CMD="poetry install --no-interaction";     INSTALL_SOURCE="poetry.lock"
  elif [ -f "$PROJECT_DIR/requirements.txt" ];  then INSTALL_CMD="pip install -r requirements.txt";     INSTALL_SOURCE="requirements.txt"
  elif [ -f "$PROJECT_DIR/Gemfile.lock" ];      then INSTALL_CMD="bundle install --local";              INSTALL_SOURCE="Gemfile.lock"
  elif [ -f "$PROJECT_DIR/composer.lock" ];     then INSTALL_CMD="composer install --no-interaction";   INSTALL_SOURCE="composer.lock"
  fi
fi
# Still null = an unknown stack. That is a legitimate answer, not an error:
# new-worktree.sh reports "no install command detected" and provisions the links
# anyway, and the human can set overrides.install_cmd.

# --- setup_candidates: reported, NEVER promoted ------------------------------
# Names only. Nothing here is ever written into `detected.setup_cmd`.
SETUP_CANDIDATES=""
add_setup_candidate() {
  SETUP_CANDIDATES="${SETUP_CANDIDATES}${SETUP_CANDIDATES:+
}$1"
}

if [ -f "$PROJECT_DIR/package.json" ] && [ "$have_jq" = true ]; then
  for s in setup bootstrap prepare postinstall; do
    if jq -e --arg k "$s" '.scripts | has($k)' "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
      case "${HC_PKG_MGR:-npm}" in
        pnpm) add_setup_candidate "pnpm run $s" ;;
        yarn) add_setup_candidate "yarn $s" ;;
        *)    add_setup_candidate "npm run $s" ;;
      esac
    fi
  done
fi
for mk in Makefile makefile GNUmakefile; do
  if [ -f "$PROJECT_DIR/$mk" ] && grep -qE '^setup[[:space:]]*:' "$PROJECT_DIR/$mk" 2>/dev/null; then
    add_setup_candidate "make setup"
    break
  fi
done
for jf in justfile Justfile .justfile; do
  if [ -f "$PROJECT_DIR/$jf" ] && grep -qE '^setup[[:space:]]*:' "$PROJECT_DIR/$jf" 2>/dev/null; then
    add_setup_candidate "just setup"
    break
  fi
done

# --- the gitignored-config filter -------------------------------------------
# "What a fresh worktree needs" == "gitignored but present in the source
# checkout". git can answer that stack-agnostically:
#
#   git ls-files --others --ignored --exclude-standard --directory -z
#
# `--directory` COLLAPSES a wholly-ignored directory into a single entry ending
# in "/" instead of listing its contents — the difference between 112 entries
# and 253,786 in a real monorepo. It is used deliberately, and the two rules it
# implies are both enforced explicitly rather than assumed:
#
#   1. FILES ONLY. Any entry ending in "/" is a directory: dropped.
#   2. SKIP ANYTHING NESTED INSIDE AN IGNORED DIRECTORY. `--directory` does NOT
#      always collapse cleanly — git still lists individual files under a
#      collapsed directory when they ALSO match an ignore pattern in their own
#      right (observed live: ".claude/hooks/" and ".claude/hooks/*.log" both
#      appear). So every surviving file is re-checked against the collected
#      directory prefixes. Without this, linking would reach into node_modules/.
#
# A CONSEQUENCE worth stating, because it looks like a miss and is not: when git
# tracks NOTHING inside a directory, the whole directory collapses, so a config
# living in it is not a candidate. That is correct — a fresh worktree will not
# contain that directory at all, so there is nothing to link the config into.
# (Observed live: a monorepo's projects/mcp-server/ was entirely local, and its
# .env is genuinely not carryable.)
#
# Then, in order: depth cap, per-file size ceiling, allowlist split, total cap.
# `-z` throughout — paths with spaces are whole paths, the same discipline
# hc_tree_status uses on porcelain lines.
IGN_DIRS=""
CAND_FILES=""
SKIP_DEPTH=0
SKIP_SIZE=0
SKIP_NESTED=0

while IFS= read -r -d '' entry; do
  [ -z "$entry" ] && continue
  case "$entry" in
    */) IGN_DIRS="${IGN_DIRS}${entry}"$'\n' ;;
    *)  CAND_FILES="${CAND_FILES}${entry}"$'\n' ;;
  esac
done < <(git -C "$PROJECT_DIR" ls-files --others --ignored --exclude-standard --directory -z 2>/dev/null)

# file_size <abs_path> → byte count, or empty when it cannot be determined.
file_size() {
  wc -c < "$1" 2>/dev/null | tr -d ' '
}

# is_allowlisted <basename> → 0 when the file is linked BY DEFAULT.
# Everything outside this list is reported as a candidate for the human to
# promote via overrides.link. The list is deliberately narrow: these are the
# shapes that are always local configuration and never a build artefact.
is_allowlisted() {
  case "$1" in
    .env*|.envrc|*.local.json|*.local.yaml|*.local.yml|appsettings.Development.json|local.settings.json) return 0 ;;
  esac
  return 1
}

LINK_LIST=""
LINK_OVERFLOW=""
CANDIDATE_LIST=""
CANDIDATE_OVERFLOW=""
LINK_N=0
CAND_N=0

while IFS= read -r p; do
  [ -z "$p" ] && continue

  # 2. nested inside an ignored directory → not a candidate.
  nested=0
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    case "$p" in "$d"*) nested=1; break ;; esac
  done <<EOF
$IGN_DIRS
EOF
  if [ "$nested" -eq 1 ]; then SKIP_NESTED=$((SKIP_NESTED + 1)); continue; fi

  # 1. files only (belt-and-braces: the entry could name a path that is a dir
  #    on disk even without a trailing slash, e.g. a submodule).
  [ -d "$PROJECT_DIR/$p" ] && continue
  [ -f "$PROJECT_DIR/$p" ] || continue

  # 3. depth cap.
  depth=$(printf '%s' "$p" | awk -F'/' '{print NF}')
  if [ "$depth" -gt "$WT_MAX_DEPTH" ]; then SKIP_DEPTH=$((SKIP_DEPTH + 1)); continue; fi

  # 4. size ceiling.
  sz=$(file_size "$PROJECT_DIR/$p")
  if [ -z "$sz" ] || [ "$sz" -gt "$WT_MAX_BYTES" ]; then SKIP_SIZE=$((SKIP_SIZE + 1)); continue; fi

  # 5. allowlist split + 6. total cap (overflow is REPORTED, never dropped).
  if is_allowlisted "$(basename "$p")"; then
    if [ "$LINK_N" -lt "$WT_MAX_LINK" ]; then
      LINK_LIST="${LINK_LIST}${p}"$'\n'; LINK_N=$((LINK_N + 1))
    else
      LINK_OVERFLOW="${LINK_OVERFLOW}${p}"$'\n'
    fi
  else
    if [ "$CAND_N" -lt "$WT_MAX_LINK" ]; then
      CANDIDATE_LIST="${CANDIDATE_LIST}${p}"$'\n'; CAND_N=$((CAND_N + 1))
    else
      CANDIDATE_OVERFLOW="${CANDIDATE_OVERFLOW}${p}"$'\n'
    fi
  fi
done <<EOF
$CAND_FILES
EOF

# --- fingerprint the detection SOURCE ---------------------------------------
# Everything the `detected` block is derived from: the install probe's source
# file, the setup candidates, the filter limits, and the surviving path set.
# The path set belongs in here because `link` is detected FROM it — a new
# gitignored .env must move the fingerprint or the block would go stale.
FP_SOURCE="wt:1
install:${INSTALL_SOURCE}:${INSTALL_CMD}
limits:${WT_MAX_DEPTH}:${WT_MAX_BYTES}:${WT_MAX_LINK}
setup:${SETUP_CANDIDATES}
link:${LINK_LIST}${LINK_OVERFLOW}
cand:${CANDIDATE_LIST}${CANDIDATE_OVERFLOW}"

if type hc_hash_stdin >/dev/null 2>&1; then
  NEW_FP=$(printf '%s' "$FP_SOURCE" | hc_hash_stdin)
else
  NEW_FP=""
fi
[ -z "$NEW_FP" ] && NEW_FP="unknown"

# --- build the detected object ----------------------------------------------
# to_json_array <newline-separated> → compact JSON array (empty input → []).
to_json_array() {
  if [ -z "$1" ]; then printf '[]'; return; fi
  printf '%s' "$1" | grep -v '^$' | jq -R . | jq -sc . 2>/dev/null
}

build_detected() {
  [ "$have_jq" = true ] || { printf '{}'; return; }
  jq -nc \
    --arg install "$INSTALL_CMD" \
    --argjson link "$(to_json_array "$LINK_LIST")" \
    --argjson link_overflow "$(to_json_array "$LINK_OVERFLOW")" \
    --argjson candidates "$(to_json_array "$CANDIDATE_LIST")" \
    --argjson candidates_overflow "$(to_json_array "$CANDIDATE_OVERFLOW")" \
    --argjson setup_candidates "$(to_json_array "$SETUP_CANDIDATES")" \
    --argjson skipped_depth "$SKIP_DEPTH" \
    --argjson skipped_size "$SKIP_SIZE" \
    --argjson skipped_nested "$SKIP_NESTED" \
    --argjson max_depth "$WT_MAX_DEPTH" \
    --argjson max_bytes "$WT_MAX_BYTES" \
    --argjson max_link "$WT_MAX_LINK" '
    {
      install_cmd: (if $install == "null" then null else $install end),
      # setup_cmd is ALWAYS null here. Promotion is a human act.
      setup_cmd: null,
      setup_candidates: $setup_candidates,
      link: $link,
      link_overflow: $link_overflow,
      link_candidates: $candidates,
      link_candidates_overflow: $candidates_overflow,
      skipped: {
        nested_in_ignored_dir: $skipped_nested,
        over_depth: $skipped_depth,
        over_size: $skipped_size
      },
      limits: { max_depth: $max_depth, max_bytes: $max_bytes, max_link: $max_link }
    }
  ' 2>/dev/null
}

DETECTED_JSON=$(build_detected)
[ -z "$DETECTED_JSON" ] && DETECTED_JSON="{}"

emit_effective() {
  # effective = detected * overrides (overrides win on flat keys) — the same
  # rule done-detect.sh uses for the top-level block.
  #
  # The stored `detected` falls back to THIS RUN's fresh detection when the
  # config has no worktree block yet. That matters more here than for
  # done-detect: a done-config that fails the contract (an older hand-written
  # one, say) makes the write abort, and without this fallback the caller would
  # receive an EMPTY config and silently provision nothing — links skipped,
  # install skipped, no error anywhere. Overrides still win, so a human value in
  # an otherwise-unwritable config is honoured too.
  if [ "$have_jq" = true ] && [ -f "$CONFIG_FILE" ]; then
    jq -c --argjson fresh "$DETECTED_JSON" \
      '(((.worktree.detected // {}) | if . == {} then $fresh else . end) * (.worktree.overrides // {}))' \
      "$CONFIG_FILE" 2>/dev/null && return
  fi
  printf '%s\n' "$DETECTED_JSON"
}

if [ "$have_jq" != true ]; then
  # Can't safely rewrite JSON without jq; emit best-effort and bail.
  emit_effective
  exit 0
fi

# --- seed the config file if it does not exist yet --------------------------
# done-detect.sh OWNS the file's overall shape (contract_version, the required
# top-level keys, the schema it must validate against). Rather than write a
# second, divergent seeder here, delegate to it and then merge our block in.
if [ ! -f "$CONFIG_FILE" ] && [ -f "$SCRIPT_DIR/done-detect.sh" ]; then
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/done-detect.sh" >/dev/null 2>&1
fi
if [ ! -f "$CONFIG_FILE" ]; then
  # Still nothing to write into (unwritable dir, done-detect refused). Emit the
  # fresh detection and leave disk alone — best-effort, never blocking.
  printf '%s\n' "$DETECTED_JSON"
  exit 0
fi

# --- write-time contract validation -----------------------------------------
CONTRACT_SCHEMA="${HC_CONTRACTS_DIR:-}/done-config.schema.json"

validate_config_file() {
  local candidate="$1" out
  if ! type hc_validate >/dev/null 2>&1; then
    printf 'worktree-detect: hc_validate unavailable — cannot validate done-config against contract\n' >&2
    return 1
  fi
  out=$(hc_validate "$CONTRACT_SCHEMA" "$candidate" 2>&1)
  if [ $? -ne 0 ]; then
    printf 'worktree-detect: done-config failed contract %s: %s\n' "$CONTRACT_SCHEMA" "$out" >&2
    return 1
  fi
  return 0
}

# --- rewrite `worktree.detected` only when the source changed ---------------
# The sticky-field property: `worktree.overrides` is seeded once and never
# written again by this script, so a human value survives every re-detection.
STORED_FP=$(jq -r '.worktree.source_fingerprint // ""' "$CONFIG_FILE" 2>/dev/null)
HAS_BLOCK=$(jq -r 'if (.worktree | type) == "object" then "yes" else "no" end' "$CONFIG_FILE" 2>/dev/null)

if [ "$HAS_BLOCK" != "yes" ] || [ "$STORED_FP" != "$NEW_FP" ]; then
  TMP=$(mktemp 2>/dev/null)
  if [ -n "$TMP" ]; then
    jq \
      --argjson detected "$DETECTED_JSON" \
      --arg fp "$NEW_FP" '
      (if (.worktree | type) == "object" then . else .worktree = {} end)
      | .worktree.detected = $detected
      | .worktree.source_fingerprint = $fp
      | (if (.worktree | has("overrides")) then . else .worktree.overrides = {} end)
    ' "$CONFIG_FILE" > "$TMP" 2>/dev/null
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
# else: fingerprint unchanged → leave the file byte-identical (idempotent).

emit_effective
exit 0
