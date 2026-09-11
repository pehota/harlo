#!/bin/bash
#
# task-DoD plugin — path classifier (sourced lib).
#
# Sourced by dod-nudge.sh and dod-gate.sh; never executed directly.
#
# THE ONE RULE: a changed path is PRODUCT surface unless it is matched by an
# `artifact_paths` glob. Fail CLOSED — an unlisted path (a brand-new top-level
# directory, say) is product, so a new area over-triggers the DoD rather than
# silently escaping the gate. The default list is deliberately directory-scoped
# and is NOT a blanket **/*.md: DOD.md and dod-protocol.md ARE the harness's
# behavioural contract and must never be exempted.
#
# Glob semantics implemented below (documented, because this picks a concrete
# reading of loose globs):
#   docs/**       anything at or under docs/            (docs/a.md, docs/x/y.md; also bare "docs/")
#   tasks/**      anything at or under tasks/
#   README*       basename starts with README  (README.md AND docs/README.md both artifact)
#   CHANGELOG*    basename starts with CHANGELOG
#   LICENSE*      basename starts with LICENSE
# A trailing `/**` means "the dir itself or anything under it". A trailing `*`
# with no slash is matched against the BASENAME only (so it is path-position
# independent — `docs/README.adoc` is artifact). A plain literal (no `*`) is an
# exact full-path match. This is a small, predictable subset — not fnmatch — and
# that is on purpose: the config is a hand-written list, not a pattern language.
#
# Guard discipline matches the sibling hooks: no `set -e`, every git call
# guarded, sourcing harness-common.sh is the CALLER's job (these helpers assume
# hc_cfg / PROJECT_DIR / HARNESS_DIR are already in scope).

# The built-in fallback list, used verbatim when `hc_cfg artifact_paths` yields
# nothing (no config, no jq, key absent). Kept identical to
# contracts/done-config.default.json's artifact_paths — test-dod.sh asserts the
# two agree so they can never drift.
DOD_DEFAULT_ARTIFACT_PATHS="docs/** tasks/** README* CHANGELOG* LICENSE*"

# dod__artifact_globs — prints the effective artifact-path globs, space-
# separated, one read. Session/repo config via hc_cfg (an array key → space-
# joined), else the built-in. Never fabricates.
dod__artifact_globs() {
  local v=""
  if hc_has_fn hc_cfg; then
    v=$(hc_cfg artifact_paths "" 2>/dev/null)
  fi
  [ -n "$v" ] || v="$DOD_DEFAULT_ARTIFACT_PATHS"
  printf '%s' "$v"
}

# dod__match_one <path> <glob> — 0 if <path> matches the single <glob> under the
# semantics documented above, 1 otherwise. Pure shell `case`, no fork.
dod__match_one() {
  local path="$1" glob="$2" base="${1##*/}"
  case "$glob" in
    */\*\*)
      # "<dir>/**" → the dir itself or anything beneath it.
      local dir="${glob%/\*\*}"
      case "$path" in
        "$dir"|"$dir"/*) return 0 ;;
      esac
      ;;
    *\*)
      # "<prefix>*" with no slash → basename prefix match, path-position free.
      case "$glob" in
        */*) case "$path" in $glob) return 0 ;; esac ;;   # slash-bearing glob: match full path
        *)   case "$base" in ${glob}) return 0 ;; esac ;;  # bare glob: match basename
      esac
      ;;
    *)
      # Literal — exact full-path match.
      [ "$path" = "$glob" ] && return 0
      ;;
  esac
  return 1
}

# dod_is_product_path <path> — exit 0 if <path> is PRODUCT surface, 1 if it is
# ARTIFACT surface. Repo-relative path expected (as `git diff --name-only` and
# `git status --porcelain`'s tail both give). Fail closed: no glob matches →
# product.
dod_is_product_path() {
  local path="$1" glob
  [ -n "$path" ] || return 0
  for glob in $(dod__artifact_globs); do
    if dod__match_one "$path" "$glob"; then
      return 1
    fi
  done
  return 0
}

# dod_changeset_has_product <session_id> — 0 iff at least one path the changeset
# touches (uncommitted tree OR committed HC_BASE..HEAD) is product surface,
# after excluding .claude/.harness/** (arming-exempt: the DoD file write must
# not itself count). 1 when the changeset is empty or artifact-only.
#
# Tree state comes from hc_tree_status — ONLY its blockers, never its warnings.
# Warnings are baseline dirt (paths already present at the session's tree
# baseline), not this session's work; counting them would make an idle /
# read-only session in a repo with any pre-existing product-file dirt demand a
# task DoD. This matches hc_state's own S0 logic. Committed range comes from
# `git diff --name-only HC_BASE..HEAD`. hc_resolve is the CALLER's job — this
# reads HC_BASE / PROJECT_DIR / HARNESS_DIR from scope.
dod_changeset_has_product() {
  local session_id="$1"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local line path

  # --- uncommitted tree ---------------------------------------------------
  if hc_has_fn hc_tree_status; then
    hc_tree_status "$session_id" 2>/dev/null
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      # porcelain path is everything after the "XY " prefix; a rename line
      # ("R  old -> new") — take the destination.
      path="${line:3}"
      case "$path" in *" -> "*) path="${path##* -> }" ;; esac
      case "$path" in .claude/.harness/*|.claude/.harness) continue ;; esac
      dod_is_product_path "$path" && return 0
    done <<EOF
$HC_TREE_BLOCKERS
EOF
  fi

  # --- committed range HC_BASE..HEAD ------------------------------------------
  if [ -n "${HC_BASE:-}" ]; then
    local head
    head=$(git -C "$proj" rev-parse -q --verify HEAD 2>/dev/null)
    if [ -n "$head" ] && [ "$HC_BASE" != "$head" ]; then
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in .claude/.harness/*|.claude/.harness) continue ;; esac
        dod_is_product_path "$path" && return 0
      done <<EOF
$(git -C "$proj" diff --name-only "$HC_BASE" "$head" 2>/dev/null)
EOF
    fi
  fi

  return 1
}
