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
# separated, one read. Repo config only, else the built-in. Never fabricates.
#
# Deliberately NOT hc_cfg: `artifact_paths` is, like `trunk`, a knob the
# SESSION layer must not reach. hc_cfg consults the agent-writable
# .claude/.harness/session-config.json FIRST, so a single
# {"artifact_paths":["*"]} written there hits the bare-glob branch of
# dod__match_one, matches every basename, classifies the entire repo as
# artifact surface, and silences the gate completely. That is an
# agent-authored signal making the gate LOOSER — barred. Read the REPO config
# (.claude/done-config.json) directly with jq, exactly as hc__detect_trunk
# refuses the session layer for `trunk`, and for the same stated reason.
dod__artifact_globs() {
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local cfg="$proj/${HC_CONFIG_REL:-.claude/done-config.json}"
  local v=""
  if hc_has_jq && [ -f "$cfg" ]; then
    v=$(jq -r '.artifact_paths
               | if type == "array" then join(" ")
                 elif type == "string" then .
                 else empty end' "$cfg" 2>/dev/null)
    [ "$v" = "null" ] && v=""
  fi
  [ -n "$v" ] || v="$DOD_DEFAULT_ARTIFACT_PATHS"
  printf '%s' "$v"
}

# dod__valid_base_sha <sha> — 0 iff <sha> is a plausible, resolvable commit id.
#
# baselines/<sid>.sha is AGENT-WRITABLE and its contents are handed straight to
# git. `git rev-parse -q --verify <x>` succeeds for ANY resolvable refname, so
# the literal string "HEAD" written into that file collapses HC_BASE..HEAD to
# the empty range and the committed half of the changeset disappears. Require
# a raw object id first — 40 hex (sha1) or 64 hex (sha256 repos exist) — and
# only then confirm it resolves to a commit. Precedent: review-log basenames in
# this repo are already required to be 40/64 lowercase hex.
dod__valid_base_sha() {
  local sha="$1"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  case "$sha" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  case "${#sha}" in
    40|64) : ;;
    *) return 1 ;;
  esac
  git -C "$proj" rev-parse -q --verify "${sha}^{commit}" >/dev/null 2>&1 || return 1
  return 0
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
  # set -f (noglob): the globs from dod__artifact_globs are intentionally
  # word-split (space-separated list) but must NOT be filename-expanded
  # against the cwd — otherwise a real docs/ dir or README.md on disk gets
  # substituted in place of the literal pattern before dod__match_one ever
  # sees it, corrupting the classification. Restored unconditionally after.
  set -f
  for glob in $(dod__artifact_globs); do
    if dod__match_one "$path" "$glob"; then
      set +f
      return 1
    fi
  done
  set +f
  return 0
}

# dod__expand_untracked_dir <path> — prints the repo-relative paths of the real
# files git has collapsed under the untracked directory <path> (which carries a
# trailing "/"), one per line. Prints nothing and returns 1 when the expansion
# cannot be performed — the CALLER must treat that as product (fail closed).
#
# WHY THIS EXISTS — the collapse. `git status --porcelain` does NOT list the
# files inside a WHOLLY untracked directory; it emits one summary line for the
# directory itself, e.g. "?? .claude/". Classifying that literal directory path
# is wrong in both directions, and here it is wrong in the expensive one:
# ".claude/" matches neither the ".claude/.harness" exclusion arm below nor any
# artifact glob, so dod_is_product_path fails closed and calls it PRODUCT
# surface. And dod-session-start.sh CREATES ".claude/" itself (it writes
# current-session into .claude/.harness/), so in any repo that does not already
# gitignore .claude/.harness/ the plugin manufactures its own permanent
# product-surface dirt and every consumer of the predicate fires forever.
#
# WHY ":/" IS NOT OPTIONAL — the pathspec trap. Porcelain paths are always
# REPO-ROOT-relative, but a git pathspec is resolved relative to git's CWD.
# PROJECT_DIR (CLAUDE_PROJECT_DIR) is legitimately a SUBDIRECTORY of the repo,
# and `git -C <subdir> ls-files -o -- ".claude/"` then looks for
# <subdir>/.claude/, finds nothing, and exits 0 with EMPTY output. That reads as
# "the directory holds no files" — a total classification bypass, silent, with a
# zero exit status. The ":/"-prefixed magic pathspec pins resolution to the repo
# root regardless of where git was invoked, which is what the porcelain path
# actually means.
#
# --full-name IS THE OTHER HALF OF THE SAME TRAP. ":/" fixes which files MATCH,
# but ls-files still PRINTS them relative to git's CWD: from a subdirectory the
# same files come back as "../../.claude/.harness/current-session", which the
# ".claude/.harness" exclusion below does not match — so the harness's own state
# would classify as product anyway. --full-name forces repo-root-relative
# output, the one form every path predicate in this file expects.
dod__expand_untracked_dir() {
  local path="$1"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local out
  # Guarded like every other git call here: a failure is an UNKNOWN set, never
  # an empty one, so it is reported to the caller as such.
  out=$(git -C "$proj" ls-files -o --exclude-standard --full-name -- ":/$path" 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
  return 0
}

# dod__porcelain_has_product <porcelain_line> — 0 iff the line names at least
# one PRODUCT-surface path, 1 otherwise. The single place a porcelain line is
# turned into classified paths, so tree callers cannot drift apart.
#
# An untracked-directory line ("??" + trailing "/") is EXPANDED and each real
# file underneath is classified; everything else (" M file", "?? file.txt",
# "R  old -> new") keeps its previous handling untouched. If the expansion
# fails or yields nothing, the collapsed directory is classified as it was
# before this function existed — i.e. handed to dod_is_product_path, which fails
# closed to product. Failing OPEN here would be a gate bypass.
#
# Quoted porcelain paths (git quotes a path containing specials, e.g.
# `?? ".claude/odd dir/"`) do not end in "/" and so are never expanded — they
# fall through to the pre-existing literal handling. Same fail-closed direction.
dod__porcelain_has_product() {
  local line="$1"
  local path expanded sub
  # porcelain path is everything after the "XY " prefix; a rename line
  # ("R  old -> new") — take the destination.
  path="${line:3}"
  case "$path" in *" -> "*) path="${path##* -> }" ;; esac

  case "$line" in
    '??'*)
      case "$path" in
        */)
          if expanded=$(dod__expand_untracked_dir "$path"); then
            while IFS= read -r sub; do
              [ -z "$sub" ] && continue
              case "$sub" in .claude/.harness/*|.claude/.harness) continue ;; esac
              dod_is_product_path "$sub" && return 0
            done <<EOF
$expanded
EOF
            return 1
          fi
          # Expansion unavailable → fall through to the literal classification
          # below (fail closed).
          ;;
      esac
      ;;
  esac

  case "$path" in .claude/.harness/*|.claude/.harness) return 1 ;; esac
  dod_is_product_path "$path" && return 0
  return 1
}

# dod_tree_has_product <session_id> — 0 iff the UNCOMMITTED tree carries at
# least one product-surface path (session-scoped blockers only, per
# hc_tree_status), 1 otherwise. Factored out of dod_changeset_has_product so a
# caller that already knows the relevant COMMITTED range (dod_range_has_product)
# can check tree dirt without re-scanning the session's full HC_BASE..HEAD.
dod_tree_has_product() {
  local session_id="$1"
  local line
  hc_has_fn hc_tree_status || return 1
  hc_tree_status "$session_id" 2>/dev/null
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Per-line classification (including the untracked-directory expansion)
    # lives in dod__porcelain_has_product — see the collapse note there.
    dod__porcelain_has_product "$line" && return 0
  done <<EOF
$HC_TREE_BLOCKERS
EOF
  return 1
}

# dod_changeset_has_product <session_id> — 0 iff at least one path the changeset
# touches (uncommitted tree OR committed HC_BASE..HEAD) is product surface,
# after excluding .claude/.harness/** (arming-exempt: the DoD file write must
# not itself count). 1 when the changeset is empty or artifact-only.
#
# Tree state comes via dod_tree_has_product — session-scoped blockers only,
# never baseline warnings (pre-existing dirt at the session's tree baseline);
# counting warnings would make an idle / read-only session in a repo with any
# pre-existing product-file dirt demand a task DoD. This matches hc_state's own
# S0 logic. Committed range comes from `git diff --name-only HC_BASE..HEAD`.
# hc_resolve is the CALLER's job — this reads HC_BASE_ORIG / PROJECT_DIR /
# HARNESS_DIR from scope.
#
# THE BASE IS HC_BASE_ORIG, NOT HC_BASE — the single most important correctness
# point in this file. hc__resolve_session_base ADVANCES HC_BASE past every
# commit absent from a commit ledger, and `dod` does not ship a commit-ledger
# hook: no commit is ever ledgered, so the advance walks HC_BASE all the way to
# HEAD and `git diff HC_BASE..HEAD` is ALWAYS empty. With HC_BASE the committed
# half of the changeset is invisible and the gate can only ever see uncommitted
# dirt. HC_BASE_ORIG is assigned (harness-common.sh) BEFORE that advance loop
# runs, and hc__resolve_task_base keeps the two equal in task mode, so it is
# the unadvanced base in BOTH modes.
dod_changeset_has_product() {
  local session_id="$1"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"

  # --- uncommitted tree ---------------------------------------------------
  # Delegated, so the untracked-directory collapse (see
  # dod__expand_untracked_dir) is handled here too, in exactly one place. The
  # committed half below reads `git diff --name-only`, which lists real blobs
  # and never collapses a directory — it needs no expansion.
  dod_tree_has_product "$session_id" && return 0

  # --- committed range HC_BASE_ORIG..HEAD -----------------------------------
  local base="${HC_BASE_ORIG:-}"
  if [ -n "$base" ]; then
    # Shape-validate before handing an agent-writable value to git. An invalid
    # or unresolvable base means we CANNOT compute the committed range — that
    # is an unknown changeset, not an empty one, so fail STRICT: report "has
    # product" rather than silently reporting nothing changed.
    dod__valid_base_sha "$base" || return 0
    local head
    head=$(git -C "$proj" rev-parse -q --verify HEAD 2>/dev/null)
    if [ -n "$head" ] && [ "$base" != "$head" ]; then
      while IFS= read -r path; do
        [ -z "$path" ] && continue
        case "$path" in .claude/.harness/*|.claude/.harness) continue ;; esac
        dod_is_product_path "$path" && return 0
      done <<EOF
$(git -C "$proj" diff --name-only "$base" "$head" 2>/dev/null)
EOF
    fi
  fi

  return 1
}

# dod_range_has_product <from_sha> <to_sha> — 0 iff `git diff --name-only
# <from_sha> <to_sha>` touches at least one product-surface path (after
# excluding .claude/.harness/**), 1 if the range is empty or artifact-only.
#
# Used at the verified boundary: once a task's DoD is archived at
# <verified_sha>, whether a LATER commit reopens the DoD requirement must be
# decided from what actually changed since that verified point — not from the
# session's full HC_BASE..HEAD range, which still includes the already-
# verified content and would false-positive on a bare re-commit of it (e.g.
# `git add && git commit` of a file written and verified in a prior turn).
dod_range_has_product() {
  local from="$1" to="$2"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local path
  [ -n "$from" ] && [ -n "$to" ] || return 0
  [ "$from" = "$to" ] && return 1
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    case "$path" in .claude/.harness/*|.claude/.harness) continue ;; esac
    dod_is_product_path "$path" && return 0
  done <<EOF
$(git -C "$proj" diff --name-only "$from" "$to" 2>/dev/null)
EOF
  return 1
}
