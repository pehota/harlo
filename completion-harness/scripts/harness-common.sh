#!/bin/bash
#
# Completion Harness — shared identity resolver (sourced library).
#
# Single source of identity-resolution truth. Sourced, never executed.
# No `set -e`; every git call is guarded; on any failure we degrade to SESSION
# mode and never crash the caller.
#
# Public entrypoint: hc_resolve <session_id>
# Sets these shell globals:
#   PROJECT_DIR HARNESS_DIR
#   HC_BRANCH HC_TRUNK HC_MODE HC_TASK_KEY HC_BASE HC_BASE_ORIG HC_WARN
#   HC_TREE_BASE_FILE
#
# Idempotent: calling repeatedly returns the same pinned base.

# Resolve the contracts dir relative to THIS script's own location so callers
# never hardcode it. Works whether this file lives in completion-harness/scripts/
# (sibling completion-harness/contracts/) or .claude/scripts/ (sibling
# .claude/contracts/).
if [ -z "${HC_CONTRACTS_DIR:-}" ]; then
  HC_CONTRACTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../contracts" 2>/dev/null && pwd)"
fi

# Repo-relative paths the harness OWNS. Declared once, here, so no site has to
# re-spell them (see hc_is_harness_own_path for the ownership rule itself).
#   HC_CONFIG_REL   the config file the harness writes to itself.
#   HC_HARNESS_REL  the state directory; the fallback for deriving the same path
#                   relative to a project root when HARNESS_DIR is unavailable.
# Plain assignment, not readonly: this library is sourced more than once per
# process in places, and a readonly re-assignment would abort the caller.
HC_CONFIG_REL=".claude/done-config.json"
HC_HARNESS_REL=".claude/.harness"
# The SESSION override layer (see hc_cfg). Lives under the state dir, so it is
# harness-owned by hc_is_harness_own_path and never blocks the tree.
HC_SESSION_CONFIG_REL="$HC_HARNESS_REL/session-config.json"

# ---------------------------------------------------------------------------
# hc_read_hook_input
#
# Reads the hook JSON payload from stdin ONCE and parses the fields hook
# scripts actually consume out of it: session_id, tool_input.file_path,
# source, stop_hook_active. Was previously re-implemented independently by
# auto-branch.sh, baseline-snapshot.sh and done-gate.sh (each its own
# `cat` + jq-guarded parse); this is the one canonical read.
#
# Degrades every field to its default ("" / stop_hook_active to "false") when
# jq is missing, matching every prior call site's behavior — callers that need
# a different jq-missing fallback (e.g. done-gate.sh's fail-safe exit) should
# still make that check themselves before or after calling this.
#
# Sets (globals, caller may copy into its own local names):
#   HC_HOOK_RAW              raw stdin payload, verbatim
#   HC_HOOK_SESSION_ID       .session_id
#   HC_HOOK_TOOL_FILE_PATH   .tool_input.file_path
#   HC_HOOK_SOURCE           .source
#   HC_HOOK_STOP_ACTIVE      .stop_hook_active (text "true"/"false")
hc_read_hook_input() {
  HC_HOOK_RAW=$(cat 2>/dev/null)
  HC_HOOK_SESSION_ID=""
  HC_HOOK_TOOL_FILE_PATH=""
  HC_HOOK_SOURCE=""
  HC_HOOK_STOP_ACTIVE="false"
  if command -v jq >/dev/null 2>&1; then
    HC_HOOK_SESSION_ID=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.session_id // ""' 2>/dev/null)
    HC_HOOK_TOOL_FILE_PATH=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
    HC_HOOK_SOURCE=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.source // ""' 2>/dev/null)
    HC_HOOK_STOP_ACTIVE=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.stop_hook_active // false' 2>/dev/null)
  fi
}

# ---------------------------------------------------------------------------
# hc__harness_dir [project_root]
#
# Prints "<project_root>/$HC_HARNESS_REL" ($PROJECT_DIR when project_root is
# omitted). Single place callers derive the harness state dir path from a
# root other than the already-resolved $HARNESS_DIR global (e.g. a worktree
# root) — do not re-spell the concatenation at call sites.
hc__harness_dir() {
  printf '%s/%s\n' "${1:-$PROJECT_DIR}" "$HC_HARNESS_REL"
}

# ---------------------------------------------------------------------------
# hc_cfg <key> [default]
#
# THE single config read. Prints the effective value of a flat top-level key,
# first hit wins:
#   1. $HC_SESSION_CONFIG_REL — THIS task's overrides. Hooks fire as static
#      commands with no argv the conversation can reach, so an instruction the
#      user gives in chat ("work only on main", "this is a docs task") can only
#      reach a hook through a file. The agent writes that instruction here; the
#      file is ephemeral (dropped at the next fresh SessionStart), so it is a
#      per-task override and not a silent edit of the repo's config.
#   2. $HC_CONFIG_REL — the repo's persisted config.
#   3. <default> — the built-in.
#
# Keys read through this: auto_branch, branch_prefix, noncode_globs,
# untracked_policy. `trunk` is deliberately NOT among them — see hc__detect_trunk.
#
# A `has()` probe, never a bare `//` default: jq's `//` treats a literal `false`
# as empty and would flip an explicit auto_branch:false back to the default. A
# JSON `null` means "not set here" and falls through to the next layer. Arrays
# are printed space-joined (the shape the glob-list readers want).
#
# Fail direction: no jq, no file, unreadable key → the caller's default. Never
# fabricates a value.
hc_cfg() {
  local key="$1" def="${2:-}"
  # <proj> (3rd, optional) so a caller working on a checkout OTHER than the
  # ambient PROJECT_DIR reads THAT checkout's config — hc_changeset_is_code takes
  # such a proj, and silently ignoring it would answer from the wrong repo.
  local proj="${3:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"

  command -v jq >/dev/null 2>&1 || { printf '%s' "$def"; return 0; }

  local f v
  for f in "$proj/$HC_SESSION_CONFIG_REL" "$proj/$HC_CONFIG_REL"; do
    [ -f "$f" ] || continue
    jq -e --arg k "$key" 'has($k)' "$f" >/dev/null 2>&1 || continue
    v=$(jq -r --arg k "$key" \
      '.[$k] | if type == "array" then join(" ") else tostring end' "$f" 2>/dev/null) || continue
    # An explicit null is "unset at this layer" → keep looking.
    [ "$v" = "null" ] && continue
    printf '%s' "$v"
    return 0
  done

  printf '%s' "$def"
  return 0
}

# Sanitize a string for use in a filename / key: every char NOT in the safe
# set [A-Za-z0-9_.-] becomes '-'.
hc__sanitize() {
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_.-]/-/g' 2>/dev/null
}

# Is <s> a raw git object id — 40 (sha1) or 64 (sha256) lowercase hex chars?
# Returns 0 if so, 1 otherwise. Everything the harness keys by sha (review-log
# basenames, the carried review anchor) must pass this BEFORE the value reaches
# git as a rev: a symbolic name (HEAD, main, HEAD@{0}) resolves against the
# CURRENT tree, which turns a freshness check into a tautology.
hc__is_object_id() {
  case "${#1}" in 40|64) ;; *) return 1 ;; esac
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  return 0
}

# ---------------------------------------------------------------------------
# hc_is_harness_own_path <repo_relative_path> [proj]
#
# THE authoritative self-ownership predicate: does the HARNESS itself own this
# repo-relative path? Every site that classifies working-tree state calls this
# one function. There is deliberately no second implementation and no scattered
# path literal — writer/gate divergence over tree classification has already
# produced a silent forever-block in this codebase twice.
#
# WHY IT EXISTS. The harness writes into the project while it runs, and in a
# repo that TRACKS those files that write manufactures exactly the dirty tree
# the gate blocks on. Concretely: new-worktree.sh persists worktree-detect's
# `worktree` block into the SOURCE checkout's .claude/done-config.json, and
# done-detect rewrites the same file mid-/done (contract_version auto-upgrade,
# fingerprint refresh). Neither is the changeset's work; neither may block.
#
# OWNED — exactly these two, nothing more:
#   1. The STATE DIRECTORY and everything beneath it. Derived from HARNESS_DIR
#      (the same variable the rest of the code uses) made repo-relative; the
#      literal $HC_HARNESS_REL is used only as a fallback when HARNESS_DIR is
#      unset or does not sit under <proj>. Matches the bare directory, the
#      porcelain COLLAPSED form ("?? .claude/.harness/" — how git reports a
#      wholly-untracked directory), and any path under it.
#   2. The CONFIG FILE $HC_CONFIG_REL.
#
# NOT OWNED — deliberately, and this is the security-critical half:
#   - .claude/scripts/, .claude/skills/, .claude/dod/, .claude/contracts/.
#     install.sh mirrors the bundle there, but the harness never writes them
#     WHILE RUNNING; only a human invoking the installer does. Exempting them
#     would let an agent rewrite done-gate.sh itself without the gate noticing —
#     i.e. it would make the green forgeable.
#   - anything else under .claude/ (settings.local.json, user notes, other
#     tools' state). .claude/ is shared ground, not harness ground.
#
# The rule is PATH SHAPE ONLY, computed from the harness's own configured
# directories. It never reads file contents and never consults anything an agent
# supplies, so it is not an exemption an agent can claim: the only way in is to
# write AT a harness path, which is unavoidable and accepted — content there is
# harness state, never reviewable work.
#
# Deliberately NOT handled (each fails toward NOT-owned, i.e. toward blocking —
# the safe direction): porcelain rename lines ("R  old -> new") and C-quoted
# paths ("\"a b\"") do not match, so they keep their normal classification.
#
# Returns 0 when the path is harness-owned, 1 otherwise. Empty path → 1.
hc_is_harness_own_path() {
  local path="${1:-}"
  local proj="${2:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  [ -n "$path" ] || return 1

  # Porcelain collapses a wholly-untracked directory and reports it with a
  # trailing slash. Strip ONE so the directory and plain forms compare equal.
  path="${path%/}"

  if [ "$path" = "$HC_CONFIG_REL" ]; then
    return 0
  fi

  # <proj>'s OWN state dir is always owned. This is the shipped literal, and it
  # is checked UNCONDITIONALLY — never conditioned on HARNESS_DIR.
  #
  # WHY UNCONDITIONALLY, rather than "derive it from HARNESS_DIR or fall back":
  # a linked worktree lives UNDER the main checkout, so finish-worktree.sh
  # legitimately asks about the MAIN checkout while HARNESS_DIR still points at
  # the WORKTREE's state dir. Deriving by prefix-strip alone would then yield
  # ".worktrees/<task>/.claude/.harness" and answer "not owned" for MAIN's own
  # state dir — a verdict that drifts with whichever checkout the caller last
  # touched. A predicate that answers differently depending on ambient globals
  # is precisely the writer/gate divergence this function exists to remove.
  hc__path_under "$path" "$HC_HARNESS_REL" && return 0

  # A RELOCATED state dir is owned too. HARNESS_DIR is the variable the rest of
  # the code uses, so honour it — but only when it is a genuine
  # "<...>/.claude/.harness" sitting under <proj> (which is what it means for a
  # nested worktree). Anything else is ignored rather than trusted: this keeps
  # the accepted shape bounded instead of "whatever HARNESS_DIR happens to say".
  local hd="${HARNESS_DIR:-}"
  hd="${hd%/}"
  if [ -n "$hd" ] && [ -n "$proj" ]; then
    local rel="${hd#"${proj%/}"/}"
    if [ "$rel" != "$hd" ] && [ "${rel%"/$HC_HARNESS_REL"}" != "$rel" ]; then
      hc__path_under "$path" "$rel" && return 0
    fi
  fi

  return 1
}

# Is <path> exactly <dir>, or somewhere beneath it? Both arguments are already
# trailing-slash-normalised by the caller. The quoted "$2" in the case pattern
# is load-bearing: it keeps the directory literal instead of a glob.
hc__path_under() {
  [ "$1" = "$2" ] && return 0
  case "$1" in
    "$2"/*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# hc_filter_harness_own [proj]
#
# Convenience over hc_is_harness_own_path for the sites that hold a RAW
# `git status --porcelain` blob rather than a classified set: reads porcelain
# lines on stdin and prints only the lines whose path is NOT harness-owned
# (blank lines are dropped). The matching rule stays in the predicate — this
# only walks lines and strips the 3-char "XY " prefix, the same space-safe
# whole-path discipline hc_tree_status uses.
hc_filter_harness_own() {
  local proj="${1:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    hc_is_harness_own_path "${line:3}" "$proj" && continue
    printf '%s\n' "$line"
  done
  return 0
}

# ---------------------------------------------------------------------------
# hc_hash_stdin
#
# Deterministic hash of stdin, printed to stdout. Prefers sha256sum, then
# `shasum -a 256`, then cksum as a stable-ish last resort so a host with neither
# coreutils flavour still produces a value that CHANGES when the input changes —
# which is all a fingerprint needs. Never fails the caller (an unhashable stdin
# yields empty; callers substitute their own sentinel).
#
# Shared by every probe that fingerprints its own source (done-detect.sh's
# `detected` block, worktree-detect.sh's `worktree.detected` block), so two
# blocks living in the SAME config file can never drift onto different digests.
hc_hash_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | cut -d' ' -f1
  else
    cksum 2>/dev/null | cut -d' ' -f1
  fi
}

# ---------------------------------------------------------------------------
# hc_pkg_probe [proj]
#
# LOCKFILE-DRIVEN Node package-manager probe. Prints nothing; sets:
#   HC_PKG_MGR     pnpm | yarn | npm | ""   ("" = not a Node project at all)
#   HC_LOCKFILE    pnpm-lock.yaml | yarn.lock | package-lock.json | none
#   HC_YARN_BERRY  1 when a .yarnrc.yml sits beside yarn.lock, else 0
#
# Probe files, never guess — the same discipline as the rest of Step 0. Order is
# deliberate: a repo carrying more than one lockfile resolves by precedence
# (pnpm > yarn > npm), and a bare package.json with NO lockfile still yields
# "npm" because npm is the default runner for a Node project. HC_LOCKFILE stays
# "none" in that last case: a lockfile appearing or disappearing is a meaningful
# source change and must move a fingerprint, which it only can if the probe
# reports the lockfile SEPARATELY from the manager.
#
# HC_YARN_BERRY exists because yarn's frozen-install flag is version-dependent
# (`--immutable` on berry, `--frozen-lockfile` on classic) and guessing wrong
# turns provisioning into a hard failure. `.yarnrc.yml` is berry-only, so its
# presence is a FILE PROBE, not a version heuristic.
#
# Never fails; a missing/unreadable project dir degrades every global to the
# not-a-Node-project answer.
hc_pkg_probe() {
  local proj="${1:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"

  HC_PKG_MGR=""
  HC_LOCKFILE="none"
  HC_YARN_BERRY=0

  if [ -f "$proj/pnpm-lock.yaml" ]; then
    HC_PKG_MGR="pnpm"; HC_LOCKFILE="pnpm-lock.yaml"
  elif [ -f "$proj/yarn.lock" ]; then
    HC_PKG_MGR="yarn"; HC_LOCKFILE="yarn.lock"
    [ -f "$proj/.yarnrc.yml" ] && HC_YARN_BERRY=1
  elif [ -f "$proj/package-lock.json" ]; then
    HC_PKG_MGR="npm"; HC_LOCKFILE="package-lock.json"
  elif [ -f "$proj/package.json" ]; then
    HC_PKG_MGR="npm"   # default runner for a Node project with no lockfile
  fi

  return 0
}

# ---------------------------------------------------------------------------
# hc__recover_base_from_state <done_state_file> [proj]
#
# Prints the changeset base recoverable from a done-state's `base_sha`, or
# NOTHING when nothing is safely recoverable. Never fails the caller.
#
# `base_sha` is a FACT stamped by done-write-state.sh from its own resolved
# HC_BASE — the merge there is `payload * {facts}` and an EMPTY base DELETES the
# key rather than defaulting it, so the field can never carry an agent-supplied
# value. That provenance is the whole reason it is admissible as an anchor when
# the SessionStart baseline has gone missing (state dir deleted, age-reaped).
#
# Three guards, all required:
#   - jq present (else we cannot read the field at all);
#   - the value is a RAW object id (hc__is_object_id) — a symbolic name like
#     HEAD would resolve against the CURRENT tree and self-validate;
#   - the object still EXISTS as a commit in THIS repo (cat-file -e) — a stale
#     or foreign sha must not become a rev git would later error on. This also
#     rejects the literal "no-git" that baseline-snapshot.sh writes when HEAD
#     does not resolve.
#
# CALLER CONTRACT: the returned value is a RECOVERED anchor, not the
# SessionStart baseline. It must only feed checks that make the gate STRICTER
# (review coverage, the changeset summary). It must NEVER be assigned to
# HC_BASE, because HC_BASE also drives the two steps that GRANT a pass — the
# gate's Step 3 quiet-exit and Step 3c empty-changeset allow — where a recovered
# base equal to HEAD would wave a whole unverified session through.
# ---------------------------------------------------------------------------
# hc_verification_state <done_state_file> <head_sha> <head_tree> [proj]
#
# "Is this done-state's verification still describing what is at HEAD?" — the
# gate's Step 5 question, extracted so a SECOND caller cannot answer it
# differently. Writer/gate divergence has already produced a silent forever-block
# twice in this codebase; finish-worktree.sh asking the same question with its
# own `verified_sha == HEAD` comparison would be the third, and it would be the
# dangerous direction (integrating work the gate would still block on).
#
# Prints exactly one sentinel; always returns 0.
#   exact  verified_sha == head_sha. The plain case.
#   carry  the shas DIFFER but the TREES are identical, so every blob and mode
#          byte is what was verified (reset --soft + recommit to reword, a
#          pull --rebase replaying the same patches). Tree equality is the WHOLE
#          guarantee — deliberately NOT ancestry, which is strictly weaker.
#   stale  anything else, including: no state file, no jq, an empty head_tree,
#          no obtainable recorded tree, or any mismatch. FAIL TOWARD STALE.
#
# Recorded-tree sources, in order: the done-state's writer-injected `head_tree`,
# else — for LEGACY states written before that field existed — the tree
# recomputed live from verified_sha. When verified_sha STILL resolves, its tree
# is additionally cross-checked; after a gc it does not resolve and the recorded
# head_tree carries alone.
#
# This function decides FRESHNESS ONLY. It says nothing about whether the
# recorded outcomes are green, whether a review-log exists, or whether coverage
# holds — callers must keep enforcing those themselves.
hc_verification_state() {
  local state="$1" head_sha="$2" head_tree="$3"
  local proj="${4:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"

  command -v jq >/dev/null 2>&1 || { printf 'stale'; return 0; }
  [ -f "$state" ] || { printf 'stale'; return 0; }

  local verified_sha
  verified_sha=$(jq -r '.verified_sha // ""' "$state" 2>/dev/null)

  if [ -n "$verified_sha" ] && [ "$verified_sha" = "$head_sha" ]; then
    printf 'exact'
    return 0
  fi

  # No HEAD tree → no proof of identical content → refuse to carry.
  if [ -z "$head_tree" ]; then printf 'stale'; return 0; fi

  local ds_tree vs_tree
  ds_tree=$(jq -r '.head_tree // ""' "$state" 2>/dev/null)
  vs_tree=$(git -C "$proj" rev-parse -q --verify "${verified_sha}^{tree}" 2>/dev/null)
  [ -z "$ds_tree" ] && ds_tree="$vs_tree"

  if [ -z "$ds_tree" ] || [ "$ds_tree" != "$head_tree" ]; then printf 'stale'; return 0; fi
  if [ -n "$vs_tree" ] && [ "$vs_tree" != "$head_tree" ]; then printf 'stale'; return 0; fi

  printf 'carry'
  return 0
}

hc__recover_base_from_state() {
  local state="$1"
  local proj="${2:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  [ -f "$state" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local b
  b=$(jq -r '.base_sha // ""' "$state" 2>/dev/null)
  [ -n "$b" ] || return 0
  hc__is_object_id "$b" || return 0
  git -C "$proj" cat-file -e "${b}^{commit}" 2>/dev/null || return 0

  printf '%s' "$b"
  return 0
}

# Offline, conservative trunk detection. Prints the trunk name, or nothing
# (empty = UNCONFIDENT). Never consults origin/HEAD (repos may have no remote).
hc__detect_trunk() {
  local cfg="$PROJECT_DIR/$HC_CONFIG_REL"
  local t=""

  # Deliberately NOT hc_cfg: `trunk` is the ONE knob the session layer must not
  # reach. It selects task-vs-session mode, computes the task key, drives
  # auto-branch, and feeds SessionStart's terminal reap, which DELETES the state
  # of branches it judges merged. A wrong trunk there destroys state rather than
  # merely loosening a check — too much authority for an ephemeral,
  # agent-written file, and nothing asked for a per-task trunk.
  if command -v jq >/dev/null 2>&1 && [ -f "$cfg" ]; then
    t=$(jq -r '.trunk // empty' "$cfg" 2>/dev/null)
    if [ -n "$t" ] && [ "$t" != "null" ]; then
      printf '%s' "$t"
      return 0
    fi
  fi

  if git -C "$PROJECT_DIR" show-ref --verify -q refs/heads/main 2>/dev/null; then
    printf 'main'
    return 0
  fi
  if git -C "$PROJECT_DIR" show-ref --verify -q refs/heads/master 2>/dev/null; then
    printf 'master'
    return 0
  fi

  # UNCONFIDENT: emit nothing.
  return 0
}

hc_resolve() {
  local session_id="$1"

  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  HARNESS_DIR="$PROJECT_DIR/$HC_HARNESS_REL"

  # Reset outputs so a repeat call never leaks stale values.
  HC_BRANCH=""
  HC_TRUNK=""
  HC_MODE="session"
  HC_TASK_KEY=""
  HC_BASE=""
  HC_BASE_ORIG=""
  HC_WARN=""
  HC_TREE_BASE_FILE=""

  # Current branch ('' when detached or not a git repo).
  HC_BRANCH=$(git -C "$PROJECT_DIR" symbolic-ref --short -q HEAD 2>/dev/null)

  # Conservative offline trunk.
  HC_TRUNK=$(hc__detect_trunk)

  # Task mode requires a real branch, a confident trunk, and branch != trunk.
  if [ -n "$HC_BRANCH" ] && [ -n "$HC_TRUNK" ] && [ "$HC_BRANCH" != "$HC_TRUNK" ]; then
    HC_MODE="task"
  else
    HC_MODE="session"
    # Warn only when we fell back BECAUSE of trunk (on trunk, or unconfident).
    if [ -n "$HC_BRANCH" ] && [ -n "$HC_TRUNK" ] && [ "$HC_BRANCH" = "$HC_TRUNK" ]; then
      HC_WARN="on trunk $HC_TRUNK, session fallback"
    elif [ -n "$HC_BRANCH" ] && [ -z "$HC_TRUNK" ]; then
      HC_WARN="unconfident trunk, session fallback"
    fi
  fi

  if [ "$HC_MODE" = "task" ]; then
    HC_TASK_KEY="br-$(hc__sanitize "$HC_BRANCH")"
    hc__resolve_task_base "$session_id"
  else
    HC_TASK_KEY="session-${session_id}"
    hc__resolve_session_base "$session_id"
  fi

  # Resolve the tree-baseline file (the "pre-existing" porcelain set for the
  # classifier). Keyed on the FINAL HC_MODE — hc__resolve_task_base may have
  # degraded task→session (unrelated histories), so set this AFTER it runs.
  #   TASK mode    → tree-base/<HC_TASK_KEY>.dirty  (pinned ONCE at the task's
  #                  fork point, reused across every session on the branch —
  #                  parallel to task-base/<HC_TASK_KEY>.sha). This is what stops
  #                  a later session re-seeding "pre-existing" from live porcelain
  #                  and thereby whitelisting the agent's own uncommitted work.
  #   SESSION mode → baselines/<session_id>.dirty  (per-session is correct — in
  #                  session mode the changeset IS the session; NOT HC_TASK_KEY,
  #                  which is "session-<id>").
  if [ "$HC_MODE" = "task" ]; then
    HC_TREE_BASE_FILE="$HARNESS_DIR/tree-base/$HC_TASK_KEY.dirty"
  else
    HC_TREE_BASE_FILE="$HARNESS_DIR/baselines/${session_id}.dirty"
  fi

  return 0
}

# Pin (or read pinned) merge-base for task mode. Falls back to session mode on
# unrelated histories (empty merge-base), without pinning.
hc__resolve_task_base() {
  local session_id="$1"
  local pin_dir="$HARNESS_DIR/task-base"
  local pin_file="$pin_dir/$HC_TASK_KEY.sha"

  # Task mode never advances the base past foreign commits — the pinned fork
  # point IS the changeset anchor. HC_BASE_ORIG therefore always mirrors HC_BASE.
  if [ -f "$pin_file" ]; then
    HC_BASE=$(cat "$pin_file" 2>/dev/null)
    HC_BASE_ORIG="$HC_BASE"
    return 0
  fi

  local mb=""
  mb=$(git -C "$PROJECT_DIR" merge-base "$HC_TRUNK" HEAD 2>/dev/null)

  if [ -n "$mb" ]; then
    mkdir -p "$pin_dir" 2>/dev/null
    printf '%s\n' "$mb" > "$pin_file" 2>/dev/null
    HC_BASE="$mb"
    HC_BASE_ORIG="$HC_BASE"
    return 0
  fi

  # Unrelated histories: no anchor. Degrade to session mode, do NOT pin.
  HC_MODE="session"
  HC_TASK_KEY="session-${session_id}"
  HC_WARN="unrelated histories, session fallback"
  hc__resolve_session_base "$session_id"
  return 0
}

# ---------------------------------------------------------------------------
# hc__commit_confidently_foreign <commit_sha> <session_id>
#
# CONFIDENTLY-FOREIGN attribution predicate (shared by base-advance / P1-a /
# P2-a). Returns 0 (CONFIDENTLY-FOREIGN — provably NOT this session's work) iff
# ALL of:
#   - `git config user.email` (session_email) is NON-EMPTY, AND
#   - the commit's committer_email is NON-EMPTY, AND
#   - they DIFFER.
# Returns 1 (NOT confidently foreign) on ANY other outcome — same email, either
# email empty, session_email empty, or any git error.
#
# This is deliberately EMAIL-ONLY. The old predicate also required the commit's
# committer_date >= mtime(baselines/<sid>.sha); that mtime is MUTABLE (a
# touch/copy-without-`-p`/clock-skew can advance it past a genuinely-authored
# commit's date), which would misclassify a real session commit as FOREIGN, let
# the base advance past it, and allow the gate to PASS with real work unverified
# — a false-PASS (the exact bug #6 prevents). The commit range orig_base..HEAD
# already guarantees "after the session baseline" by ancestry, so the mtime
# signal added only risk, no signal, and is dropped.
#
# FAIL-SAFE: the caller (hc__resolve_session_base) advances the base ONLY while
# the leading commit is CONFIDENTLY-FOREIGN and STOPS on the first commit that is
# NOT — so any uncertainty (this predicate returning 1) keeps the commit (and
# everything after) in the changeset and the gate engages. NEVER advances past a
# commit that might be the session's.
hc__commit_confidently_foreign() {
  local sha="$1" session_id="$2"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"

  local session_email committer_email
  session_email=$(git -C "$proj" config user.email 2>/dev/null)
  [ -z "$session_email" ] && return 1
  committer_email=$(git -C "$proj" show -s --format='%ce' "$sha" 2>/dev/null)
  [ -z "$committer_email" ] && return 1
  [ "$committer_email" = "$session_email" ] && return 1

  return 0
}

# ---------------------------------------------------------------------------
# hc__session_authored_count <orig_base> <head> <session_id>
#
# Prints the integer count of SESSION-AUTHORED commits in orig_base..HEAD
# (oldest→newest). AUTHORED (email-only, consistent with the confidently-foreign
# predicate): committer_email non-empty AND == session_email (git config
# user.email). Guarded; on any git failure or an empty range it prints 0. Shared
# by P2-a (preflight divergence warn) and the changeset summary (P1-a).
hc__session_authored_count() {
  local orig_base="$1" head="$2" session_id="$3"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  [ -z "$orig_base" ] && { printf '0'; return 0; }
  local revs n=0 c
  revs=$(git -C "$proj" rev-list --reverse "$orig_base..$head" 2>/dev/null) || { printf '0'; return 0; }
  [ -z "$revs" ] && { printf '0'; return 0; }
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if hc__commit_session_authored "$c" "$session_id"; then
      n=$((n + 1))
    fi
  done <<EOF
$revs
EOF
  printf '%s' "$n"
  return 0
}

# ---------------------------------------------------------------------------
# hc__commit_session_authored <commit_sha> <session_id>
#
# Positive session-authorship predicate (email-only). Returns 0 iff the commit's
# committer_email is NON-EMPTY AND == session_email (git config user.email, which
# must itself be non-empty). Returns 1 otherwise. This is the summary/preflight
# counterpart to hc__commit_confidently_foreign — a commit can be neither (either
# email empty) so the two are NOT strict negations; this one answers "is THIS
# commit positively the session's?" for the human-readable authored tally.
hc__commit_session_authored() {
  local sha="$1" session_id="$2"
  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local session_email committer_email
  session_email=$(git -C "$proj" config user.email 2>/dev/null)
  [ -z "$session_email" ] && return 1
  committer_email=$(git -C "$proj" show -s --format='%ce' "$sha" 2>/dev/null)
  [ -z "$committer_email" ] && return 1
  [ "$committer_email" = "$session_email" ] || return 1
  return 0
}

# Session-mode base: read the SessionStart baseline if present, else empty.
# Then ADVANCE past any LEADING run of CONFIDENTLY-FOREIGN commits (P0-a, #6): a
# commit whose committer email PROVABLY differs from the session's (both emails
# non-empty) that HEAD sits atop must not be re-verified as this session's work.
#
# Advance rule: walk orig_base..HEAD oldest→newest; while the leading commit is
# CONFIDENTLY-FOREIGN (hc__commit_confidently_foreign), set the new base to that
# commit; STOP at the FIRST commit that is NOT confidently-foreign (same email,
# OR either email empty, OR session_email empty, OR any git error). HC_BASE
# becomes the new (advanced) base; HC_BASE_ORIG stays the original unadvanced
# baseline.
#
# FAIL-SAFE: session_email empty → nothing is confidently-foreign → NO advance
# (full changeset). Any uncertainty → STOP → keep the commit (and everything
# after) in the changeset → gate engages. We NEVER advance past a commit that
# might be the session's. Note we do NOT consult the baseline .sha mtime at all
# any more — it is MUTABLE and was the M1 false-PASS risk (see
# hc__commit_confidently_foreign); ancestry (orig_base..HEAD) already bounds the
# range to commits after the baseline.
hc__resolve_session_base() {
  local session_id="$1"
  local base_file="$HARNESS_DIR/baselines/${session_id}.sha"
  if [ -f "$base_file" ]; then
    HC_BASE=$(cat "$base_file" 2>/dev/null)
  else
    HC_BASE=""
  fi
  HC_BASE_ORIG="$HC_BASE"

  # Nothing to advance past without a real base anchor.
  [ -z "$HC_BASE" ] && return 0

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local head
  head=$(git -C "$proj" rev-parse HEAD 2>/dev/null)
  [ -z "$head" ] && return 0

  local revs c
  revs=$(git -C "$proj" rev-list --reverse "$HC_BASE_ORIG..$head" 2>/dev/null) || return 0
  [ -z "$revs" ] && return 0

  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if hc__commit_confidently_foreign "$c" "$session_id"; then
      # Leading CONFIDENTLY-FOREIGN commit → advance the base to it.
      HC_BASE="$c"
    else
      # NOT confidently foreign (same email, empty email, or any doubt) → STOP;
      # base sits just below it. Keep it (and everything after) in the changeset.
      break
    fi
  done <<EOF
$revs
EOF
  return 0
}

# ---------------------------------------------------------------------------
# hc_tree_status <session_id>
#
# Baseline-relative working-tree classifier. THE single shared predicate used by
# the Stop gate (done-gate.sh Step 6), the /done writer (done-write-state.sh),
# and the preflight (done-preflight.sh) — none reimplements it.
#
# Classifies each current `git status --porcelain` line relative to the pinned
# tree baseline recorded at SessionStart. The baseline PATH comes from
# HC_TREE_BASE_FILE (set by hc_resolve), NOT a hardcoded session-keyed path:
#   TASK mode    → $HARNESS_DIR/tree-base/<HC_TASK_KEY>.dirty  (pinned once at
#                  the task fork; shared across all sessions on the branch).
#   SESSION mode → $HARNESS_DIR/baselines/<session_id>.dirty  (per session).
# Requires hc_resolve to have run first (it sets HC_TREE_BASE_FILE). If
# HC_TREE_BASE_FILE is empty (resolver not run), the baseline is treated as
# MISSING → empty set → everything blocks (safe direction). The session_id
# param is retained for signature stability but is vestigial in task mode (the
# path no longer derives from it).
#
# Sets shell globals (both newline-separated, empty if none):
#   HC_TREE_BLOCKERS — entries introduced THIS session (the changeset's own
#                      uncommitted work) → must block.
#   HC_TREE_WARNINGS — entries already present at baseline → pre-existing, PLUS
#                      harness-owned paths (hc_is_harness_own_path), which are
#                      exempt at any policy and under any baseline. Computed for
#                      classification/tests, but NOT surfaced in any message
#                      (pre-existing dirt is irrelevant to the task).
#
# Membership is by EXACT whole-line equality (robust to paths with spaces —
# the porcelain formatting is identical on both sides, so no field splitting).
#
# untracked_policy (done-config.json, default "baseline"):
#   "baseline" — a current line is a BLOCKER iff it is NOT in the baseline set;
#                lines present at baseline are WARNINGS. Applies to both tracked-
#                modified and untracked lines.
#   "strict"   — every untracked ("??") line is a BLOCKER regardless of baseline
#                (restores old strictness). Tracked-modified lines stay
#                baseline-relative in both modes.
#
# A MISSING baseline .dirty file is treated as the EMPTY baseline set (strict
# direction): every current change is "introduced" → blocks. Never silently
# passes. Requires PROJECT_DIR/HARNESS_DIR set (hc_resolve, or set by caller).
#
#   HC_TREE_BASELINE_MISSING — 1 when there is no baseline file to classify
#                      against, else 0. The VERDICT is unaffected (still strict,
#                      still blocks); it only tells the caller that authorship is
#                      unknowable, so the message must not assert the session
#                      introduced those paths. Always set, even on a clean tree.
#
# ACCEPTED GAP — what a porcelain-only view cannot see (documented, NOT fixed).
# This classifier's whole input is plain `git status --porcelain`: no --ignored,
# no `ls-files -v` cross-check. So on-disk content can decouple from the tree in
# several ways that all present as a CLEAN tree here, and every one of them is
# reachable by an agent with a shell:
#   - GITIGNORED files. Mutating one changes what runs without changing what git
#     reports. (The obvious case, and the reason this note exists.)
#   - `git update-index --assume-unchanged <path>` and `--skip-worktree <path>`.
#     Both hide edits to a TRACKED file from porcelain. Distinguishing them needs
#     `git ls-files -v` (flags `h`/`S`), which is not consulted.
#   - `.git/info/exclude`. A repo-LOCAL ignore list with the same force as
#     .gitignore, but invisible in a reviewable, committed .gitignore diff.
# Consequence: "clean tree" here means "git reports nothing", not "the working
# directory matches HEAD". The review-coverage checks are blob-based against
# committed content, so anything hidden this way is also outside what the review
# ever attested. Detecting it is deliberately out of scope — this note exists so
# the limit is stated rather than assumed away.
#
# Returns 0 always; callers test `[ -n "$HC_TREE_BLOCKERS" ]`.
hc_tree_status() {
  local session_id="$1"

  # Reset outputs so a repeat call never leaks stale values.
  HC_TREE_BLOCKERS=""
  HC_TREE_WARNINGS=""
  HC_TREE_BASELINE_MISSING=0

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local hdir="${HARNESS_DIR:-$proj/.claude/.harness}"

  # Baseline path is the resolver-pinned HC_TREE_BASE_FILE (task- or session-
  # scoped). Empty (resolver not run) → `[ -f "" ]` is false → treated as
  # missing → strict direction.
  local baseline_file="${HC_TREE_BASE_FILE:-}"

  # DEGRADED-BASELINE flag. The CLASSIFICATION is unchanged (see the header): no
  # baseline file → EMPTY baseline set → every current change blocks. What it
  # changes is the CLAIM: without a baseline the harness cannot know who authored
  # a path, so the message must not assert the session introduced it (see
  # hc_tree_remediation). Set BEFORE the clean-tree early return so it is always
  # defined for the caller.
  #
  # Keyed on the file being ABSENT only — a ZERO-LENGTH .dirty is NOT degraded.
  # baseline-snapshot.sh writes `git status --porcelain > "$HC_TREE_BASE_FILE"`
  # and documents "always create the file (even when empty) so 'missing' (→
  # strict) is distinguishable from 'clean at baseline'": a clean repo at
  # SessionStart legitimately yields 0 bytes, and an EMPTY baseline set means
  # nothing was pre-existing — there "you introduced this" is TRUE.
  [ -f "$baseline_file" ] || HC_TREE_BASELINE_MISSING=1

  # Current tree state (guarded).
  local current
  current=$(git -C "$proj" status --porcelain 2>/dev/null)
  [ -z "$current" ] && return 0

  # untracked_policy override (default "baseline"), session layer first.
  local policy
  policy=$(hc_cfg untracked_policy "baseline")
  [ -n "$policy" ] || policy="baseline"

  local line in_baseline is_untracked
  while IFS= read -r line; do
    [ -z "$line" ] && continue

    # SELF-OWNED EXEMPTION. Files the HARNESS itself writes (its state dir and
    # its config — see hc_is_harness_own_path for the exact rule) are never the
    # changeset's own task work, tracked or not. Classifying them as introduced
    # would force a needless commit → new HEAD → full re-review cascade, or, in
    # a repo that tracks the config, a permanent block the harness manufactured
    # itself. They are never a blocker under ANY policy — recorded as a warning
    # (never surfaced, never gated).
    #
    # PLACEMENT IS LOAD-BEARING: this must stay ABOVE the untracked_policy
    # branch below. Under policy "strict" every "??" line blocks unconditionally,
    # so an untracked state dir ("?? .claude/.harness/", the shape a repo that
    # never ran install.sh reports) would block if this ran second.
    #
    # The porcelain path is everything after the "XY " prefix.
    if hc_is_harness_own_path "${line:3}" "$proj"; then
      HC_TREE_WARNINGS="${HC_TREE_WARNINGS:+$HC_TREE_WARNINGS
}$line"
      continue
    fi

    # First two chars are the porcelain status; "??" == untracked.
    is_untracked=0
    case "$line" in
      '??'*) is_untracked=1 ;;
    esac

    # strict policy: any untracked line blocks regardless of baseline.
    if [ "$policy" = "strict" ] && [ "$is_untracked" -eq 1 ]; then
      HC_TREE_BLOCKERS="${HC_TREE_BLOCKERS:+$HC_TREE_BLOCKERS
}$line"
      continue
    fi

    # Baseline-relative: present at baseline → warning; else → blocker.
    in_baseline=0
    if [ -f "$baseline_file" ] && grep -Fxq -- "$line" "$baseline_file" 2>/dev/null; then
      in_baseline=1
    fi

    if [ "$in_baseline" -eq 1 ]; then
      HC_TREE_WARNINGS="${HC_TREE_WARNINGS:+$HC_TREE_WARNINGS
}$line"
    else
      HC_TREE_BLOCKERS="${HC_TREE_BLOCKERS:+$HC_TREE_BLOCKERS
}$line"
    fi
  done <<EOF
$current
EOF

  return 0
}

# ---------------------------------------------------------------------------
# hc_changeset_is_code <base> <head> [proj]
#
# Scope predicate for the harness (#5): decides whether the current changeset is
# a CODING changeset (the DoD applies) or entirely NON-CODE (the harness must
# fully stand down — silent Stop gate, no SessionStart steering).
#
# Changed-file set = the UNION of:
#   (1) `git diff --name-only <base> <head>` — the COMMITTED range, and
#   (2) the INTRODUCED tree paths — the paths of HC_TREE_BLOCKERS as classified
#       by hc_tree_status (baseline-relative introduced set, NOT raw git status).
#       The caller must have run hc_tree_status first; if HC_TREE_BLOCKERS is
#       unset/empty this contributes nothing. Each blocker line is a porcelain
#       "XY <path>" line; we take everything after the 3-char prefix (space-safe,
#       whole-path — same discipline hc_tree_status uses).
#
# A file is NON-CODE iff its path matches >=1 glob in `noncode_globs` (read from
# done-config.json; falls back to the conservative built-in default set when the
# key is absent/empty/unreadable). Matching uses bash `[[ "$path" == $glob ]]`
# (unquoted RHS = glob match); `*` spans `/`, so `*.md` matches `docs/a.md`.
# An ABSENT/EMPTY noncode_globs → NO file is recognised non-code → every file is
# code → the changeset is always CODE (safe direction).
#
# Contract (FAIL TOWARD GATING — a misclassification must never silently skip
# gating real code):
#   prints "code"    / returns 0  — the changed set is NON-EMPTY and >=1 file is
#                                   NOT recognised non-code (a coding changeset),
#                                   OR on ANY error (git failure, etc.). CODE.
#   prints "noncode" / returns 1  — the changed set is NON-EMPTY and EVERY file
#                                   matches a noncode glob. NON-CODE.
#   prints "empty"   / returns 2  — the changed set is EMPTY (no committed range,
#                                   no introduced dirt). Caller treats as "no
#                                   changeset" (S0 territory), NOT as non-code.
# Any error/ambiguity resolves to CODE ("code"/0). Sets no globals.
# ---------------------------------------------------------------------------
# hc_noncode_globs
#
# The effective `noncode_globs` list, space-separated. Split out from the path
# predicate so a caller looping over N paths reads the config ONCE. This is not
# a micro-optimisation: hc_changeset_is_code runs inside the Stop hook, which the
# runtime kills at `"timeout": 10`, and a killed hook emits no stdout — which the
# gate's own contract reads as ALLOW. A per-path jq spawn (~6ms) would therefore
# turn a large changeset into a silently disarmed gate.
hc_noncode_globs() {
  # <proj> (1st, optional) — forwarded to hc_cfg; see there.
  # Built-in default set; overridden only when the key is PRESENT at some config
  # layer (hc_cfg's has() probe). A present-but-empty array yields "" → no match
  # → code, which is the strict direction.
  hc_cfg noncode_globs '*.md *.markdown *.txt *.rst *.adoc *.org LICENSE LICENSE.* NOTICE *.png *.jpg *.jpeg *.gif *.svg *.webp *.ico *.pdf' "${1:-}"
}

# ---------------------------------------------------------------------------
# hc_path_is_noncode <repo_relative_path> [globs]
#
# THE per-path half of the scope rule (#5): does this ONE path match >=1 glob in
# the effective `noncode_globs`? Extracted from hc_changeset_is_code so the
# PreToolUse branch hook and the Stop gate decide "is this prose?" with the same
# implementation — the branch hook used to have no scope test at all, which is
# how a docs-only task ended up on a task/ branch.
#
# <globs> is the optional pre-read list (hc_noncode_globs); pass it when calling
# in a loop. Omitted → read here from the ambient project, for the one-path
# callers. There is deliberately no proj parameter: a caller that needs another
# checkout's globs reads them itself with `hc_noncode_globs <proj>` and passes
# the list — which is exactly what a loop caller already does.
#
# An ABSENT/EMPTY noncode_globs → nothing is recognised non-code → every path is
# code (safe direction: gate more, branch more, never less).
#
# Returns 0 (non-code) / 1 (code, or empty path). Prints nothing.
hc_path_is_noncode() {
  local path="${1:-}"
  [ -n "$path" ] || return 1

  # Presence of the ARG decides, not its emptiness: a config with
  # `noncode_globs: []` legitimately passes an empty list, and re-reading on
  # empty would restore the per-path jq spawn this parameter exists to avoid.
  local globs
  if [ "$#" -ge 2 ]; then globs="$2"; else globs=$(hc_noncode_globs); fi

  # Disable pathname expansion for the duration: `for g in $globs` word-splits
  # the space-separated list, and with globbing ON bash would EXPAND each glob
  # (e.g. `*.md`) against the CWD before the loop body ever sees it — silently
  # turning the pattern list into a list of matching filenames. `set -f` keeps
  # the patterns literal so `[[ "$path" == $g ]]` performs the intended glob
  # match. `*` spans `/`, so `*.md` matches `docs/a.md`.
  local restore_glob=0
  case "$-" in *f*) ;; *) restore_glob=1 ;; esac
  set -f

  local g rc=1
  for g in $globs; do
    if [[ "$path" == $g ]]; then
      rc=0
      break
    fi
  done

  [ "$restore_glob" -eq 1 ] && set +f
  return "$rc"
}

hc_changeset_is_code() {
  local base="$1" head="$2"
  local proj="${3:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"

  # --- assemble the changed-file set (union, newline-separated) ---------------
  local files="" line path

  # (1) committed range base..head. Only when we have a real base AND head; a
  # git failure here is an ERROR → fail toward CODE (return 0 below).
  if [ -n "$base" ] && [ -n "$head" ]; then
    local diff_out diff_rc
    diff_out=$(git -C "$proj" diff --name-only "$base" "$head" 2>/dev/null)
    diff_rc=$?
    if [ "$diff_rc" -ne 0 ]; then
      printf 'code\n'
      return 0
    fi
    files="$diff_out"
  fi

  # (2) introduced tree paths — strip the 3-char porcelain prefix from each
  # HC_TREE_BLOCKERS line (whole path after "XY ", space-safe).
  if [ -n "${HC_TREE_BLOCKERS:-}" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      path="${line:3}"
      [ -z "$path" ] && continue
      files="${files:+$files
}$path"
    done <<EOF
$HC_TREE_BLOCKERS
EOF
  fi

  # Empty changed set → not our territory (S0). Distinct return code so callers
  # never confuse "nothing changed" with "everything is non-code".
  if [ -z "$files" ]; then
    printf 'empty\n'
    return 2
  fi

  # --- classify: NON-CODE only if EVERY file matches >=1 noncode glob ---------
  # Config read ONCE, outside the loop — see hc_noncode_globs on why a per-path
  # read is a gate-disarming timeout risk, not a micro-optimisation.
  local globs f verdict="noncode" rc=1
  globs=$(hc_noncode_globs "$proj")
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! hc_path_is_noncode "$f" "$globs"; then
      # A single unrecognised (code / unknown-ext) file → whole changeset CODE.
      verdict="code"
      rc=0
      break
    fi
  done <<EOF
$files
EOF

  printf '%s\n' "$verdict"
  return "$rc"
}

# ---------------------------------------------------------------------------
# hc_review_blocking <review_log_file> <min_level>
#
# Prints the integer count of BLOCKING findings (severity rank >= min_level
# rank). Single source of truth for severity gating — like hc_tree_status is for
# the tree — sourced identically by done-gate.sh (Step 8) and done-write-state.sh
# so they can never diverge.
#
# - Severity ranks: low=0 medium=1 high=2 critical=3.
# - A finding BLOCKS iff rank(finding.severity) >= rank(min_level).
#     default min_level "high" → high+critical block; medium+low are advisory.
#     min_level "low" → everything blocks (strictest).
# - UNKNOWN or MISSING finding severity ranks as BLOCKING (rank 99) — safe
#   direction: a typo'd/absent severity can never dodge the gate.
# - If min_level is unknown/empty, normalize to "high".
# - If the "findings" key is PRESENT it is authoritative and MUST be an array:
#   count from it (an EMPTY array counts 0 -> allow, reviewer found nothing).
#   A present-but-non-array findings (object/string/number/null) is a malformed
#   or forged log -> jq errors -> "ERR" -> block (the self-reported open_findings
#   is NEVER consulted when findings is present).
# - If the "findings" key is ABSENT, FALL BACK to the log's .open_findings
#   integer (backward compat with old-style logs; missing -> 1 so it blocks).
# - If the log is missing or jq fails, print "ERR" (caller treats != "0" as
#   block). NEVER prints "0" on error — fail toward block.
hc_review_blocking() {
  local log="$1" min_level="$2"

  # jq is required to reason structurally; without it, fail toward block.
  command -v jq >/dev/null 2>&1 || { printf 'ERR'; return 0; }
  [ -f "$log" ] || { printf 'ERR'; return 0; }

  # Normalize an unknown/empty min_level to "high".
  case "$min_level" in
    low|medium|high|critical) ;;
    *) min_level="high" ;;
  esac

  local out
  out=$(jq -r --arg min "$min_level" '
    ({"low":0,"medium":1,"high":2,"critical":3}) as $rank
    | ($rank[$min] // 2) as $threshold
    | if (has("findings")) then
        # findings key PRESENT → it is authoritative. It MUST be an array; a
        # present-but-non-array findings (object/string/number/null) can never
        # dodge the gate by riding the self-reported open_findings — jq errors
        # here, the outer guard prints ERR, the caller blocks. An EMPTY array is
        # a legitimate "reviewer found nothing" → counts 0 → allow.
        if ((.findings | type) == "array") then
          [ .findings[]
            | (($rank[(.severity // "")] // 99)) as $r
            | select($r >= $threshold)
          ] | length
        else
          error("findings present but not an array")
        end
      else
        # findings key ABSENT → old-style log; fall back to the self-reported
        # open_findings integer (missing → 1 → block).
        (.open_findings // 1)
      end
  ' "$log" 2>/dev/null)

  # Guard: any failure (empty / non-numeric) fails toward block.
  case "$out" in
    ''|*[!0-9]*) printf 'ERR' ;;
    *) printf '%s' "$out" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# hc_review_coverage_gap <review_log_file> <base> <head> [proj] [extra_admit]
#                        [chain_admit]
#
# TWO admission overrides, both bypassing the ancestry test that an ORPHANED
# anchor's rewritten sha can no longer satisfy. They differ ONLY in the rev their
# attested blobs resolve against, and that difference is the whole safety
# argument — do not merge them:
#
# <extra_admit> (5th, optional) — a CARRIED anchor whose content the caller has
#   already proven identical to <head> (its recorded tree equals HEAD's tree).
#   Its blobs resolve at <head>. That is byte-identical to resolving them at the
#   anchor — equal trees, same blobs — minus the reflog/gc dependency, so the
#   carry survives a gc that pruned the anchor. Callers must pass it ONLY after
#   proving tree equality; passing it without that proof is a coverage HOLE (the
#   attestation would resolve against the CURRENT tree and self-validate).
#
# <chain_admit> (6th, optional) — an ORPHANED anchor whose content the caller has
#   NOT proven equal to <head>: the tree HAS moved on (a later real commit), but
#   the anchor still attests files that commit did not touch. Its blobs resolve
#   at ITS OWN sha, so coverage is decided by a GENUINE blob comparison
#   (<chain_admit>:p == <head>:p) and a file the later commit actually changed is
#   NOT covered. No tree-equality precondition is needed, and none is assumed.
#   If the sha no longer resolves (gc), its blobs come back empty, it contributes
#   nothing, and the files fall into the gap — fail toward block, never a
#   head-resolution fallback.
#
# Both are checked AFTER the hc__is_object_id basename guard, so a symbolic name
# can never enter the chain through either door.
#
# STRUCTURAL coverage check for the review step. Answers: "did the reviewer
# actually attest to having examined every file the changeset touched, AT ITS
# CURRENT CONTENT?" — turning "the review covered the whole changeset" from
# prose hope into a gate check. Companion to hc_review_blocking (severity) —
# same fail-toward-block discipline, sourced identically by done-gate.sh
# (Step 8) and done-write-state.sh so they can never diverge.
#
# Prints the newline-separated changeset files NOT attested as reviewed.
#   EMPTY output  → full coverage (PASS).
#   non-empty     → those files changed but were not attested → caller BLOCKS.
#   the token SKIP → coverage cannot be computed (no changeset base) → caller
#                    must NOT block on coverage (no-regression degrade; there was
#                    no coverage check before this feature).
#
# BLOB semantics (per-file, not per-log). A changed file is COVERED iff its
# CURRENT blob (its content at <head>) was attested by SOME review-log in the
# task's chain. Previously coverage was per-log at HEAD only — every HEAD move
# forced re-attestation of the ENTIRE changeset (the "too many review loops"
# churn). Now a follow-up commit only needs re-attestation of the files whose
# CONTENT it actually changed; files whose blob is unchanged carry their
# attestation forward from an earlier chain-log for free.
#
# The CHAIN (which logs count). The signature still takes a single <review_log>
# file (call sites unchanged); the chain is derived from its DIRECTORY. For each
# `<sha>.json` in dirname(<log>), the log is IN the chain iff <sha> is an
# ancestor of <head> AND is NOT an ancestor of <base> — i.e. a commit on the
# task side of the fork, up to and including HEAD (HEAD's own log qualifies:
# a commit is its own ancestor). Logs for superseded/unreachable commits are
# ignored.
#
# Attested blob of file `p` in chain-log `f`: `git rev-parse -q --verify
# <f.reviewed_sha>:p`. Current blob: `git rev-parse -q --verify <head>:p`.
# `p` is covered iff some chain-log both LISTS `p` in files_reviewed AND its
# attested blob for `p` equals the current blob.
#
# DELETED-file carve-out. If `p` has NO blob at <head> (deleted at head), there
# is no content to blob-match — a tombstone has no blob. Then `p` is covered iff
# SOME chain-log simply LISTS `p` in files_reviewed (path attestation: the
# reviewer attested examining the file, and the file is now gone).
#
# REBASE / GC consequence (INTENTIONAL, fail-toward-block). A chain-log's
# attested blob is recomputed live from its reviewed_sha. If a rebase (or gc)
# makes an old reviewed_sha unreachable, `git rev-parse <old_sha>:p` fails →
# that log contributes no attested blob → the file falls into the gap →
# re-review is forced. We prefer forcing an unnecessary re-review over trusting
# an attestation whose commit no longer exists.
#
# Guards / fail direction (PRESERVED verbatim from the pre-blob version):
#   - <base> empty/unset OR the git diff command fails → print SKIP. Coverage is
#     meaningless without a changeset base; this is the ONLY no-block degrade.
#   - Everything else guarded toward BLOCK: on a jq error, an unreadable log, or
#     any other failure with a non-empty changed set, print the FULL changed set
#     (block) rather than empty (allow).
#   - jq missing → we cannot read files_reviewed at all → gap = all changed
#     files → block. This is what FORCES the attestation.
#
# Space-safety: paths may contain spaces, so files_reviewed membership is by
# EXACT WHOLE-LINE equality (`grep -Fxq`), never field-splitting — the same
# discipline hc_tree_status uses for porcelain lines.
hc_review_coverage_gap() {
  local log="$1" base="$2" head="$3"
  local proj="${4:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  # extra: a CARRIED review anchor — the sha of a log the caller has already
  # proven still describes the current content (its tree == HEAD's tree). Its
  # own sha may no longer be an ancestor of head (amend/rebase rewrote it) and
  # may not even resolve after a gc, so it is admitted to the chain by NAME and
  # its blobs are resolved at <head>. That is byte-identical to resolving them
  # at the anchor — equal trees, same blobs — minus the reflog/gc dependency.
  # Empty (the normal case) admits nothing extra.
  local extra="${5:-}"
  # chain: an ORPHANED review anchor whose content is NOT claimed equal to
  # <head>. Admitted to the chain by NAME (the ancestry test cannot see it after
  # an amend/rebase rewrote its sha) but resolved at ITS OWN sha, so every
  # coverage decision it makes is a real blob comparison. See the header.
  local chain="${6:-}"

  # No changeset base → coverage is not computable. SKIP (no-block degrade).
  [ -z "$base" ] && { printf 'SKIP'; return 0; }

  # Changed set from the two-dot range. A git failure here means we cannot
  # compute a changeset at all → SKIP (parity with the missing-base case: no
  # changeset base we can trust).
  local changed
  if ! changed=$(git -C "$proj" diff --name-only "$base" "$head" 2>/dev/null); then
    printf 'SKIP'
    return 0
  fi

  # Empty changed set → nothing to cover → full coverage trivially (PASS).
  [ -z "$changed" ] && return 0

  # From here a non-empty changeset EXISTS; every remaining failure path prints
  # the full changed set (block), never empty (allow).

  # jq is required to read files_reviewed from any log. Missing → nothing can be
  # attested → gap = all changed files → block.
  if ! command -v jq >/dev/null 2>&1; then
    printf '%s' "$changed"
    return 0
  fi

  # --- Build the chain: task-side ancestor logs of <head> ------------------
  # For each <sha>.json in the log's DIRECTORY, keep it iff <sha> is an ancestor
  # of <head> AND NOT an ancestor of <base>. We record each attested path keyed
  # by the log's reviewed_sha, so blob resolution later uses the right rev.
  local dir; dir=$(dirname "$log")
  # Attested paths, one "<reviewed_sha>\x1f<path>" record per line (\x1f = US,
  # a byte that cannot occur in a path → space-safe delimiter).
  local US=$'\x1f'
  local attested=""

  local f fname fsha rsha paths p
  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    fname=$(basename "$f" .json)
    # The basename MUST be a raw object id. Anything else is not a sha the
    # harness ever wrote, and feeding it to git as a rev is a coverage HOLE: a
    # symbolic name (HEAD, main, HEAD@{0}) satisfies `merge-base --is-ancestor`
    # and then resolves its attested blob via `rev-parse HEAD:<path>` — i.e.
    # against the CURRENT tree, so its attestation self-validates and never
    # expires. Skipped BEFORE the two merge-base calls, so junk basenames also
    # cost zero forks.
    hc__is_object_id "$fname" || continue
    if [ -n "$extra" ] && [ "$fname" = "$extra" ]; then
      # CARRIED ANCHOR: admitted by name, resolved at head (see `extra` above).
      rsha="$head"
    elif [ -n "$chain" ] && [ "$fname" = "$chain" ]; then
      # ORPHANED ANCHOR: admitted by name, resolved at its OWN sha, so its
      # attestations are blob-checked against head rather than self-validating.
      rsha="$fname"
    else
      # Filename sha must be an ancestor of head and NOT of base (task-side).
      git -C "$proj" merge-base --is-ancestor "$fname" "$head" 2>/dev/null || continue
      git -C "$proj" merge-base --is-ancestor "$fname" "$base" 2>/dev/null && continue
      # reviewed_sha to blob against; fall back to the filename sha if absent.
      rsha=$(jq -r 'if (has("reviewed_sha") and (.reviewed_sha|type=="string") and (.reviewed_sha|length>0)) then .reviewed_sha else empty end' "$f" 2>/dev/null)
      [ -z "$rsha" ] && rsha="$fname"
    fi
    # Attested paths (array only; anything else contributes none).
    paths=$(jq -r 'if (has("files_reviewed") and ((.files_reviewed|type)=="array")) then .files_reviewed[] else empty end' "$f" 2>/dev/null)
    [ -z "$paths" ] && continue
    while IFS= read -r p; do
      [ -z "$p" ] && continue
      attested="${attested:+$attested
}${rsha}${US}${p}"
    done <<EOF
$paths
EOF
  done

  # --- Per-file coverage ---------------------------------------------------
  local gap="" cur covered rec asha apath ablob
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    covered=0
    # Current blob of p at head. Empty → deleted at head → path-attestation.
    cur=$(git -C "$proj" rev-parse -q --verify "$head:$p" 2>/dev/null)
    if [ -z "$cur" ]; then
      # DELETED: covered iff some chain-log simply lists p (no blob to match).
      while IFS= read -r rec; do
        [ -z "$rec" ] && continue
        apath="${rec#*"$US"}"
        if [ "$apath" = "$p" ]; then covered=1; break; fi
      done <<EOF
$attested
EOF
    else
      # PRESENT: covered iff some chain-log lists p AND its attested blob == cur.
      while IFS= read -r rec; do
        [ -z "$rec" ] && continue
        asha="${rec%%"$US"*}"
        apath="${rec#*"$US"}"
        [ "$apath" = "$p" ] || continue
        ablob=$(git -C "$proj" rev-parse -q --verify "$asha:$p" 2>/dev/null)
        if [ -n "$ablob" ] && [ "$ablob" = "$cur" ]; then
          covered=1
          break
        fi
      done <<EOF
$attested
EOF
    fi
    [ "$covered" -eq 0 ] && gap="${gap:+$gap
}$p"
  done <<EOF
$changed
EOF

  printf '%s' "$gap"
  return 0
}

# ---------------------------------------------------------------------------
# hc_live_task_keys [proj] [trunk] [current_branch]
#
# Prints the KEEP-set of task keys for the terminal reap — one `br-<sanitized>`
# key per local branch that is an IN-PROGRESS task, newline-separated. The pure
# decision logic for "which task state is load-bearing" lives here so it can be
# unit-tested without any deletion (baseline-snapshot.sh does the rm).
#
# A local branch's task state is LIVE (KEEP) iff ALL hold:
#   - the branch is NOT the trunk itself, AND
#   - the branch is NOT merged into trunk
#     (`! git merge-base --is-ancestor <branch> <trunk>`).
# A merged branch's changeset is integrated → its task state is dead → NOT in
# the keep-set → reapable. A branch that is GONE contributes no key at all →
# its stale key is likewise absent from the keep-set → reapable.
#
# SAFETY: if trunk is EMPTY/UNCONFIDENT, integration cannot be judged, so this
# prints NOTHING and the caller MUST skip the terminal reap entirely (never
# guess "merged"). Callers detect skip via the trunk being empty, not via empty
# output (a repo with only a merged trunk also yields empty output but that is a
# confident-trunk state — the caller checks trunk emptiness itself before reap).
#
# Args: [proj] defaults to PROJECT_DIR/CLAUDE_PROJECT_DIR/PWD; [trunk] defaults
# to hc__detect_trunk; [current_branch] should be the branch hc_resolve already
# resolved (HC_BRANCH) — passing it avoids a second, racy `symbolic-ref` here
# (a HEAD that detaches between hc_resolve's pin and this call would otherwise
# drop the just-pinned current-task key from the keep-set). Falls back to a live
# `symbolic-ref` only when the arg is omitted. Guarded; always returns 0.
hc_live_task_keys() {
  local proj="${1:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local trunk="${2:-}"
  local cur_arg="${3-__UNSET__}"
  # Resolve trunk lazily against `proj` if not supplied.
  if [ -z "$trunk" ]; then
    local _saved_proj="$PROJECT_DIR"
    PROJECT_DIR="$proj"
    trunk=$(hc__detect_trunk)
    PROJECT_DIR="$_saved_proj"
  fi
  # Unconfident trunk → cannot judge integration → keep-set is undefined; the
  # caller skips reap. Emit nothing.
  [ -z "$trunk" ] && return 0

  # The CURRENT branch is the active in-progress task — ALWAYS live, regardless
  # of merge status. A freshly-forked branch with no divergent commits yet is an
  # ancestor of trunk (would look "merged"), but its task is just beginning and
  # its state is load-bearing. Reaping it mid-task violates the hard invariant.
  # Prefer the caller-supplied branch (hc_resolve's HC_BRANCH); fall back to a
  # live symbolic-ref only when no arg was passed.
  local cur
  if [ "$cur_arg" = "__UNSET__" ]; then
    cur=$(git -C "$proj" symbolic-ref --short -q HEAD 2>/dev/null)
  else
    cur="$cur_arg"
  fi

  local br
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    [ "$br" = "$trunk" ] && continue
    if [ -n "$cur" ] && [ "$br" = "$cur" ]; then
      printf 'br-%s\n' "$(hc__sanitize "$br")"
      continue
    fi
    # Merged into trunk → integrated → NOT live (skip). Unmerged → live (keep).
    if git -C "$proj" merge-base --is-ancestor "$br" "$trunk" 2>/dev/null; then
      continue
    fi
    printf 'br-%s\n' "$(hc__sanitize "$br")"
  done <<EOF
$(git -C "$proj" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# hc_live_review_shas [proj]
#
# Prints the KEEP-set of review-log SHAs — one per line — for review-log
# hygiene. A `review-log/<sha>.json` is load-bearing if <sha> is a commit the
# gate might still check across a LIVE task's chain:
#   - the current HEAD, and every local branch tip (baseline: always emitted);
#   - PLUS every done-state's verified_sha and review_anchor_sha (baseline too):
#     a tree-identical HEAD move leaves the anchored log's sha unreachable, so
#     no git-derived source names it and the next SessionStart would reap the
#     log the carry depends on;
#   - PLUS, for each live task branch (unmerged non-trunk, same liveness logic
#     hc_live_task_keys uses), EVERY commit on its chain `git rev-list B..T`
#     (B = the branch's pinned task-base, T = its tip). Blob-keyed coverage
#     (hc_review_coverage_gap) now walks the WHOLE chain of a task's logs, not
#     just HEAD's — so an intermediate-commit log on a live branch is still
#     load-bearing and must NOT be reaped as "superseded fix-churn".
#
# SAFETY (matches the terminal-reap discipline): if trunk is UNCONFIDENT, or a
# task's pinned base file is missing/unreadable, or `git rev-list B..T` fails,
# we do NOT narrow — we still emit at least HEAD + all branch tips (the
# pre-widening behaviour), never nothing. Widening only ADDS shas; it can never
# drop a tip or HEAD.
#
# The pure "which shas are live" decision lives here; the deletion stays in
# baseline-snapshot.sh. Guarded; always returns 0.
hc_live_review_shas() {
  local proj="${1:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local hdir="${HARNESS_DIR:-$proj/.claude/.harness}"
  # Baseline keep-set (ALWAYS emitted, even if the widening below no-ops):
  #   Current HEAD (empty in a non-git / unborn-branch repo).
  git -C "$proj" rev-parse HEAD 2>/dev/null
  #   Every local branch tip.
  git -C "$proj" for-each-ref --format='%(objectname)' refs/heads/ 2>/dev/null
  #   Every sha a live done-state still points at — its verified_sha AND its
  #   review_anchor_sha. The anchor is a log for a sha that a tree-identical
  #   HEAD move (amend / rebase) left unreachable, so NONE of the git-derived
  #   sources above can name it: without this the very next SessionStart reaps
  #   it and the carry silently expires. Part of the BASELINE set deliberately —
  #   the widening below returns early on an unconfident trunk, and a reaped
  #   anchor is not a degrade we can accept. Guarded; a missing dir is a no-op.
  local ds
  for ds in "$hdir"/done-state/*.json; do
    [ -e "$ds" ] || continue
    jq -r '(.verified_sha // empty), (.review_anchor_sha // empty)' "$ds" 2>/dev/null
  done

  # --- Widening: chain commits of every LIVE task branch -------------------
  # Trunk must be confident to judge liveness; otherwise skip widening (the
  # baseline above already kept tips+HEAD → fail toward keeping everything live).
  local trunk
  local _saved_proj="$PROJECT_DIR"
  PROJECT_DIR="$proj"
  trunk=$(hc__detect_trunk 2>/dev/null)
  PROJECT_DIR="$_saved_proj"
  [ -z "$trunk" ] && return 0

  local br tip base_file base
  while IFS= read -r br; do
    [ -z "$br" ] && continue
    [ "$br" = "$trunk" ] && continue
    # LIVE iff NOT merged into trunk (unmerged non-trunk = in-progress task).
    git -C "$proj" merge-base --is-ancestor "$br" "$trunk" 2>/dev/null && continue
    # Pinned task-base for this branch: task-base/br-<sanitized>.sha.
    base_file="$hdir/task-base/br-$(hc__sanitize "$br").sha"
    [ -f "$base_file" ] && [ -r "$base_file" ] || continue
    base=$(cat "$base_file" 2>/dev/null)
    [ -z "$base" ] && continue
    tip=$(git -C "$proj" rev-parse -q --verify "refs/heads/$br" 2>/dev/null)
    [ -z "$tip" ] && continue
    # Every commit on the task chain base..tip (rev-list failure → emit nothing
    # extra for this branch; the tip is already in the baseline set).
    git -C "$proj" rev-list "$base..$tip" 2>/dev/null
  done <<EOF
$(git -C "$proj" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null)
EOF
  return 0
}

# ---------------------------------------------------------------------------
# hc_changeset_summary <base_orig> <head> [proj]
#
# Human-readable one-shot summary of the changeset the gate is about to block
# on, so a block message says WHAT is in the range instead of a bare "/done".
# Uses base_orig (the UNADVANCED base — HC_BASE_ORIG) so it can honestly report
# "0 authored this session" when every commit in the range is foreign (P1-a,
# #6). Reuses the email-only authorship predicate (hc__commit_session_authored).
#
# Prints up to three newline-joined lines:
#   changeset <b7>..<h7> — N files, +add/-del
#   C commits, A authored this session (Name n, ...)
#   tree: B pre-existing, I new
# The third line is emitted only when hc_tree_status globals are populated.
#
# Fail-safe: on any git failure it emits whatever partial lines it can and STILL
# returns 0 — the caller always still blocks; this only enriches the reason.
hc_changeset_summary() {
  local base_orig="$1" head="$2"
  local proj="${3:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  local session_id="${HC_SESSION_ID:-}"

  local b7 h7 out=""
  b7=$(printf '%s' "$base_orig" | cut -c1-7 2>/dev/null)
  h7=$(printf '%s' "$head" | cut -c1-7 2>/dev/null)

  # Line 1: files + insertions/deletions from --shortstat.
  local nfiles adds dels shortstat
  if [ -n "$base_orig" ]; then
    shortstat=$(git -C "$proj" diff --shortstat "$base_orig" "$head" 2>/dev/null)
    nfiles=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' | head -1)
    adds=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' | head -1)
    dels=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' | head -1)
  fi
  [ -z "$nfiles" ] && nfiles=0
  [ -z "$adds" ] && adds=0
  [ -z "$dels" ] && dels=0
  out="changeset ${b7}..${h7} — ${nfiles} files, +${adds}/-${dels}"

  # Line 2: commit count + session-authored count with a compact author list.
  if [ -n "$base_orig" ]; then
    local revs c total=0 authored=0 authors="" name
    revs=$(git -C "$proj" rev-list --reverse "$base_orig..$head" 2>/dev/null)
    if [ -n "$revs" ]; then
      # Tally committer names for the author list (all commits in range).
      local names_raw
      names_raw=$(git -C "$proj" log --format='%cn' "$base_orig..$head" 2>/dev/null | sort | uniq -c | sort -rn)
      while IFS= read -r c; do
        [ -z "$c" ] && continue
        total=$((total + 1))
        if hc__commit_session_authored "$c" "$session_id"; then
          authored=$((authored + 1))
        fi
      done <<EOF
$revs
EOF
      # Compact "Name n, ..." list from the tally.
      local cnt nm
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        cnt=$(printf '%s' "$line" | awk '{print $1}')
        nm=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')
        authors="${authors:+$authors, }${nm} ${cnt}"
      done <<EOF
$names_raw
EOF
    fi
    out="$out
${total} commits, ${authored} authored this session${authors:+ ($authors)}"
  fi

  # Line 3: tree breakdown from the last hc_tree_status call (if populated).
  if [ -n "${HC_TREE_BLOCKERS+x}" ] || [ -n "${HC_TREE_WARNINGS+x}" ]; then
    local nb ni
    nb=$(printf '%s' "$HC_TREE_WARNINGS" | grep -c . 2>/dev/null)
    ni=$(printf '%s' "$HC_TREE_BLOCKERS" | grep -c . 2>/dev/null)
    out="$out
tree: ${nb:-0} pre-existing, ${ni:-0} new"
  fi

  printf '%s' "$out"
  return 0
}

# hc_tree_remediation — build the exact remediation text from the globals set by
# the most recent hc_tree_status call. Names ONLY the blocking (introduced)
# files. Pre-existing (warned-only) entries are intentionally NOT surfaced —
# they are irrelevant to the task. Prints to stdout.
#
# DEGRADED BASELINE (HC_TREE_BASELINE_MISSING=1). Without a baseline file the
# classifier has no way to tell the session's own work from a two-month-old
# worktree, so "changes you introduced" would be an assertion the harness cannot
# support — and a false one destroys trust in the gate. The verdict is unchanged
# (these paths still block); only the CLAIM is softened, and the remediation
# names the real repair: restart the session so SessionStart rewrites the
# baseline. Kept as a drop-in replacement for the parenthetical, so every caller
# ("finish the slice (...)", the preflight problem line, the writer's refusal)
# inherits the honest wording without its own branch.
hc_tree_remediation() {
  local msg=""
  local list
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    list=$(printf '%s' "$HC_TREE_BLOCKERS" | tr '\n' ';' | sed 's/;$//' | sed 's/;/; /g')
    if [ "${HC_TREE_BASELINE_MISSING:-0}" = "1" ]; then
      msg="no session baseline is recorded, so authorship cannot be determined — these changes MAY predate this session: ${list}; restart the session (SessionStart rewrites the baseline), then commit or stash whatever is yours"
    else
      msg="commit or stash these changes you introduced: ${list}"
    fi
  fi
  printf '%s' "$msg"
}

# ---------------------------------------------------------------------------
# hc_validate <schema_file> <json_file>
#
# Hard-contract validator. Validates a JSON instance against a JSON-Schema
# subset using ONLY jq — no node/ajv/new runtime. This is a SECURITY GATE:
# every ambiguity fails toward `return 1` (reject).
#
# Supported keyword subset (exactly these — NO $ref/anyOf/allOf/pattern/format):
# type (string OR array-of-strings union), required (array), properties (object
# name→subschema), items (subschema applied to every array element), enum (array
# of allowed scalars), const (exact required scalar), minLength (integer — the
# instance, when a string, must have length >= it), oneOf (array of subschemas —
# valid iff EXACTLY ONE matches), not (subschema the instance must NOT match),
# additionalProperties (boolean, default true). Nullable is expressed as a type
# union, e.g. ["string","null"].
#
# Fail-closed on UNSUPPORTED keywords: any schema keyword outside the enforced
# subset above and the benign-annotation allowlist ($schema, $id, title,
# description, $comment, examples, default, deprecated, readOnly, writeOnly,
# definitions, $defs) is REJECTED at the node where it appears (e.g. pattern,
# minimum, anyOf, $ref). This prevents a false-pass where an author writes a
# constraint this validator does not enforce. The lint rides the v() recursion,
# inspecting only schema-object keys — never property names, `required` entries,
# or const/enum/default values.
#
# Contract: prints "OK" and returns 0 when the instance is valid; prints
# "ERR: <path>: <what>" (the FIRST violation in document order) and returns 1
# on any invalidity or error. Fail-closed: jq missing, unreadable/unparseable
# schema or instance, or a jq runtime error → "ERR: ..." + return 1.
hc_validate() {
  local schema_file="$1" json_file="$2"

  # jq is mandatory — without it we cannot reason about JSON at all → reject.
  command -v jq >/dev/null 2>&1 || { printf 'ERR: jq unavailable\n'; return 1; }

  # Schema and instance must both be present, readable, and parseable JSON.
  [ -f "$schema_file" ] && [ -r "$schema_file" ] || { printf 'ERR: %s: schema missing or unreadable\n' "$schema_file"; return 1; }
  [ -f "$json_file" ]   && [ -r "$json_file" ]   || { printf 'ERR: %s: instance missing or unreadable\n' "$json_file"; return 1; }
  jq . "$schema_file" >/dev/null 2>&1 || { printf 'ERR: %s: schema not valid JSON\n' "$schema_file"; return 1; }
  jq . "$json_file"   >/dev/null 2>&1 || { printf 'ERR: %s: instance not valid JSON\n' "$json_file"; return 1; }

  # Each file must be EXACTLY ONE JSON document. `jq .` over an empty or
  # whitespace-only file reads zero inputs and exits 0 (silent success), which
  # would make the validator body below run over no input and pass — a
  # fail-OPEN hole. `jq -s 'length'` slurps every value into an array; require
  # length 1 so empty/whitespace (0) and concatenated multi-doc (>1) both fail
  # toward reject. Applied to BOTH files: an empty schema arrives via
  # --slurpfile as [] → $schema[0] == null → every check is skipped → OK, the
  # same fail-open. Fail-closed for both.
  [ "$(jq -s 'length' "$schema_file" 2>/dev/null)" = "1" ] || { printf 'ERR: %s: schema is not exactly one JSON document\n' "$schema_file"; return 1; }
  [ "$(jq -s 'length' "$json_file"   2>/dev/null)" = "1" ] || { printf 'ERR: %s: instance is not exactly one JSON document\n' "$json_file"; return 1; }

  # The recursive validator `v($schema; $path)` RETURNS a flat array of
  # "path: why" error strings (empty array = valid), collected depth-first in
  # document order. In bash we take `.[0]` — the FIRST error. Keyword order per
  # node: type → const → enum → minLength → not → oneOf → (object) required →
  # additionalProperties → properties(recurse) → (array) items(recurse). Every keyword and every
  # recursion is guarded on the INSTANCE's actual type so a union type or an
  # absent keyword never crashes jq (a crash → empty stdout + nonzero rc →
  # handled as fail-closed below). The schema arrives via --slurpfile, which
  # wraps it in a one-element array, so the root schema is `$schema[0]`.
  local errs rc
  errs=$(jq -r --slurpfile schema "$schema_file" '
    # jq type name of the instance mapped to a schema type name. Objects,
    # arrays, strings, booleans and null map straight through; numbers map to
    # "number" (schema "integer" is checked separately below).
    def jtype:
      (. | type) as $t
      | if $t == "number" then "number" else $t end ;

    # Does the instance satisfy a single schema type name $want?
    #  - "integer": instance is a number equal to its own floor (no fractional
    #    part). We use (. == (.|floor)) rather than (. % 1 == 0) because the jq
    #    % operator truncates both operands first, so 3.5 % 1 == 3 % 1 == 0
    #    would wrongly accept 3.5 as an integer.
    #  - "number":  any number.
    #  - anything else: exact jq-type-name match.
    def type_ok($want):
      if $want == "integer" then
        ((. | type) == "number") and (. == (. | floor))
      elif $want == "number" then
        ((. | type) == "number")
      else
        (jtype == $want)
      end ;

    # Recursive validator. Returns [] when valid, else an array of error
    # strings. $schema is the (sub)schema node; $path is a jq-path string used
    # only for human-readable error messages.
    # ENFORCED keywords — validation semantics implemented by v() below.
    ["type","required","properties","items","enum","const","additionalProperties","oneOf","not","minLength"] as $enforced_kw
    # ALLOWED-and-ignored keywords — benign JSON-Schema annotations that carry
    # no validation semantics; present for documentation only, safe to skip.
    | ["$schema","$id","title","description","$comment","examples","default","deprecated","readOnly","writeOnly","definitions","$defs"] as $allowed_kw
    | ($enforced_kw + $allowed_kw) as $known_kw
    |
    def v($schema; $path):
      # --- unsupported-keyword lint (fail-closed). Rides this recursion so it
      # runs at EVERY schema node v() visits (root, each properties value, items,
      # each oneOf branch, not). A keyword this validator neither enforces nor
      # knows to be a benign annotation is REJECTED: a schema author who writes
      # e.g. `pattern`/`minimum` must not silently believe it is enforced in a
      # security gate. We inspect ONLY the KEYS of the schema OBJECT itself —
      # never instance data, property NAMES (which live under .properties, one
      # level down), `required`/`enum`/`const`/`default` VALUES, or $defs member
      # names — so a property literally named "pattern" is not misread.
      ( if ($schema | type) == "object" then
          [ ($schema | keys[]) | select( . as $k | ($known_kw | any(. == $k)) | not )
            | ($path + ": unsupported schema keyword: " + .) ]
        else [] end ) as $kw_errs

      # --- additionalProperties form check (fail-closed). We ONLY enforce the
      # BOOLEAN form (true/false); the object-subschema form
      # (`additionalProperties: {...}`) is NOT descended into or validated, so
      # any nested keywords would be silently ignored — the same fail-open
      # pocket as an unsupported keyword (#2), in a different idiom. When present
      # and NOT a boolean, REJECT it as unsupported. Rides this recursion so it
      # fires at every schema node. Boolean values (true/false) are unaffected.
      | ( if ($schema | type) == "object" and ($schema | has("additionalProperties"))
             and (($schema.additionalProperties | type) != "boolean") then
            [ ($path + ": additionalProperties as a subschema is not supported") ]
          else [] end ) as $addlprop_errs

      # --- type: single string OR array-of-strings union (pass if ANY match).
      | ( if ($schema | type) == "object" and ($schema | has("type")) then
            ($schema.type) as $ty
            | ( if ($ty | type) == "array"
                then ( . as $inst
                       | if any($ty[]; . as $w | ($inst | type_ok($w)))
                         then [] else [ ($path + ": expected type " + ($ty|tostring) + ", got " + jtype) ] end )
                else ( . as $inst
                       | if ($inst | type_ok($ty))
                         then [] else [ ($path + ": expected type " + ($ty|tostring) + ", got " + jtype) ] end )
                end )
          else [] end ) as $type_errs

      # --- const: exact equality.
      | ( if ($schema | type) == "object" and ($schema | has("const")) then
            ( if . == $schema.const then []
              else [ ($path + ": expected const " + ($schema.const|tostring)) ] end )
          else [] end ) as $const_errs

      # --- enum: membership.
      | ( if ($schema | type) == "object" and ($schema | has("enum")) then
            ( . as $inst
              | if any($schema.enum[]; . == $inst) then []
                else [ ($path + ": not in enum " + ($schema.enum|tostring)) ] end )
          else [] end ) as $enum_errs

      # --- minLength: when the instance is a STRING it must be at least this
      # long. Non-string instances are unconstrained by minLength (type handles
      # them). Fail-closed: a present-but-shorter string errors.
      | ( if ($schema | type) == "object" and ($schema | has("minLength")) then
            ( if (. | type) == "string" and ((. | length) < $schema.minLength)
              then [ ($path + ": string shorter than minLength " + ($schema.minLength|tostring)) ]
              else [] end )
          else [] end ) as $minlen_errs

      # --- not: the instance must NOT satisfy the subschema. If it DOES match
      # (the recursive validator returns [] = valid), that is an error here.
      | ( if ($schema | type) == "object" and ($schema | has("not")) then
            ( if (v($schema.not; $path + ".not") | length) == 0
              then [ ($path + ": must not match the 'not' subschema") ]
              else [] end )
          else [] end ) as $not_errs

      # --- oneOf: EXACTLY ONE subschema must match. Count the matching branches
      # (a branch matches iff v(...) returns []); anything other than exactly one
      # is an error. Fail-closed: zero matches OR multiple matches both error.
      | ( if ($schema | type) == "object" and ($schema | has("oneOf")) then
            ( . as $inst
              | ( [ $schema.oneOf[] | . as $sub
                    | ($inst | v($sub; $path + ".oneOf")) | length
                    | select(. == 0) ] | length ) as $matches
              | if $matches == 1 then []
                else [ ($path + ": matched " + ($matches|tostring) + " oneOf branches, expected exactly 1") ] end )
          else [] end ) as $oneof_errs

      # --- object keywords (only when the INSTANCE is an object).
      | ( if (. | type) == "object" and ($schema | type) == "object" then
            . as $inst
            # required: each listed name must exist on the instance.
            | ( if ($schema | has("required")) then
                  [ $schema.required[] | . as $rk
                    | select(($inst | has($rk)) | not)
                    | ($path + ": missing required: " + $rk) ]
                else [] end ) as $req_errs
            # additionalProperties==false: no instance key outside properties.
            | ( ($schema.properties // {} | keys) as $allowed
                | if ($schema.additionalProperties == false) then
                    [ $inst | keys[] | select( . as $k | ($allowed | any(. == $k)) | not )
                      | ($path + ": additional property: " + .) ]
                  else [] end ) as $addl_errs
            # properties: recurse into each declared key the instance HAS,
            # in stable key order for determinism.
            | ( [ ($schema.properties // {} | keys[])
                  | . as $k
                  | select($inst | has($k))
                  | ($inst[$k] | v($schema.properties[$k]; $path + "." + $k)) ]
                | add // [] ) as $prop_errs
            | ($req_errs + $addl_errs + $prop_errs)
          else [] end ) as $obj_errs

      # --- array keyword (only when the INSTANCE is an array and items given).
      | ( if (. | type) == "array" and ($schema | type) == "object" and ($schema | has("items")) then
            . as $arr
            | ( [ range(0; ($arr | length)) as $i
                  | ($arr[$i] | v($schema.items; $path + "[" + ($i|tostring) + "]")) ]
                | add // [] )
          else [] end ) as $items_errs

      # Concatenate in the documented order; caller takes the first.
      | ( $kw_errs + $addlprop_errs + $type_errs + $const_errs + $enum_errs + $minlen_errs + $not_errs + $oneof_errs + $obj_errs + $items_errs ) ;

    v($schema[0]; "$") | .[0] // empty
  ' "$json_file" 2>/dev/null)
  rc=$?

  # A jq runtime error (malformed program/data) → nonzero rc → fail-closed.
  if [ "$rc" -ne 0 ]; then printf 'ERR: validator failure\n'; return 1; fi
  # A non-empty first-error string → invalid.
  if [ -n "$errs" ]; then printf 'ERR: %s\n' "$errs"; return 1; fi
  printf 'OK\n'; return 0
}

# ---------------------------------------------------------------------------
# hc_done_state_blocked <done_state_file> <head_sha> <base> <harness_dir> \
#                       <contracts_dir> <min_level>
#
# The single shared predicate for "is this done-state's recorded outcome (plus
# the live review evidence at HEAD) a GREEN completion, or is something still
# blocking?" — an EXACT faithful extraction of done-gate.sh's Step-8 blocker
# aggregation (the 7-part checklist-outcome gate). Sourced so the gate and any
# other consumer can never diverge from this logic — the same discipline that
# makes hc_tree_status / hc_review_blocking single-source predicates.
#
# It does NOT re-check commit hygiene (SHA==HEAD, clean tree, escalation) — those
# are Steps 4b/5/6/7 upstream of Step 8 and remain the caller's responsibility
# (hc_state composes them). This predicate is ONLY the Step-8 outcome aggregation.
#
# Sets shell global:
#   HC_DONE_BLOCKED_REASON — empty string ("") when NOT blocked (all 7 green);
#     otherwise a short human-readable reason naming the FIRST failing check, in
#     Step-8 document order. Callers test the variable, NOT the return code.
#
# ALWAYS returns 0 (like hc_tree_status) — the verdict is the global, never $?.
#
# Fail direction is INVERTED from the library's usual fail-safe (matching the
# gate's Step 8): a MISSING / null / malformed outcome, an absent review-log, a
# jq crash, or jq itself being unavailable, are ALL treated as NOT green → block.
# A green verdict requires every check to affirmatively pass.
#
# The 7 aggregated blockers, in order (first failure wins):
#   1. tests.exit_code must be exactly "0" (absent → "MISSING" → block).
#   2. lint.exit_code checked ONLY when .lint is present/non-null; if present it
#      must be "0" (a present-but-nonzero blocks; absent lint is not a failure —
#      not every project configures lint).
#   3. an admissible review-log must EXIST. Preferred:
#      <harness_dir>/review-log/<head_sha>.json, keyed by the LIVE head sha
#      passed in, NOT the task key. Failing that, the done-state's recorded
#      review_anchor_sha (legacy states: verified_sha) — the SAME two-path
#      candidate set the gate's Step 8 resolves, so a carried verification is not
#      reported blocked here while the gate allows it. Neither present → block.
#   4. review-log must pass hc_validate against <contracts_dir>/review-log.schema.json.
#   5. hc_review_blocking <review_log> <min_level> must be exactly "0" — "ERR" or
#      any non-zero blocking count → block.
#   6. hc_review_coverage_gap <review_log> <base> <head_sha> <proj> must be empty
#      OR the token "SKIP" — a non-empty non-SKIP result (uncovered files) → block.
#      (SKIP = coverage not computable, a graceful no-regression degrade, NOT a block.)
#      The anchor is passed through in the mode check 3 admitted it under.
#   7. task_checks: the count of entries with status != "passed" must be 0.
#
# jq is guarded behind `command -v jq`; if jq is missing we cannot read any
# recorded outcome → degrade fail-toward-block on check 1.
hc_done_state_blocked() {
  local done_state_file="$1" head_sha="$2" base="$3"
  local harness_dir="$4" contracts_dir="$5" min_level="$6"

  # Reset the verdict so a repeat call never leaks a stale reason.
  HC_DONE_BLOCKED_REASON=""

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"

  # jq is mandatory to read any recorded outcome. Without it we cannot verify
  # a single field → fail toward block (mirrors the gate, whose jq-missing top
  # guard would already have exited before Step 8 could pass).
  if ! command -v jq >/dev/null 2>&1; then
    HC_DONE_BLOCKED_REASON="jq unavailable (cannot verify recorded outcomes)"
    return 0
  fi

  # --- 1. tests must be GREEN with EVIDENCE (P1-c, #6). -----------------------
  # Reaching Step 8 means NO escalation short-circuited (Step 7 ran first). So a
  # tests.status=="not_run" here is a green claim WITHOUT verification → block.
  # A green result must carry exit_code==0 AND non-empty command AND non-empty
  # output_tail (un-forgeable green). Any missing field → "MISSING" → block.
  local tests_status
  tests_status=$(jq -r '.tests.status // ""' "$done_state_file" 2>/dev/null)
  if [ "$tests_status" = "not_run" ]; then
    HC_DONE_BLOCKED_REASON="tests not run (no escalation)"
    return 0
  fi
  local tests_exit
  tests_exit=$(jq -r '.tests.exit_code // "MISSING"' "$done_state_file" 2>/dev/null)
  if [ "$tests_exit" != "0" ]; then
    HC_DONE_BLOCKED_REASON="tests failed (exit ${tests_exit})"
    return 0
  fi
  local tests_cmd tests_tail
  tests_cmd=$(jq -r '.tests.command // ""' "$done_state_file" 2>/dev/null)
  tests_tail=$(jq -r '.tests.output_tail // ""' "$done_state_file" 2>/dev/null)
  if [ -z "$tests_cmd" ] || [ -z "$tests_tail" ]; then
    HC_DONE_BLOCKED_REASON="tests green but missing evidence (command/output_tail)"
    return 0
  fi

  # --- 2. lint.exit_code — conditional; only when .lint is present/non-null. --
  local lint_exit
  lint_exit=$(jq -r '.lint.exit_code // "MISSING"' "$done_state_file" 2>/dev/null)
  if [ "$lint_exit" != "MISSING" ] && [ "$lint_exit" != "0" ]; then
    HC_DONE_BLOCKED_REASON="lint failed (exit ${lint_exit})"
    return 0
  fi

  # --- 3. an admissible review-log must EXIST. --------------------------------
  # CANDIDATE SET — the SAME two harness-derived paths the gate's Step 8 uses,
  # never a directory listing: review-log/<head_sha>.json, and the done-state's
  # recorded review_anchor_sha (legacy states fall back to verified_sha). Without
  # the anchor this predicate reports "no review-log at HEAD" for exactly the
  # states the gate ALLOWS via a carry — hc_state would then steer "run /done" at
  # a HEAD the Stop gate is happy with, which is the contradiction this shares
  # its logic to prevent.
  #
  # The admission MODE mirrors the gate's split on the same discriminator (see
  # done-gate.sh Step 8 and hc_review_coverage_gap's header) — it is a safety
  # boundary, not a style choice:
  #   no HEAD-exact log  → the anchor IS the log; blobs resolve at head
  #                        (extra_admit) because the caller proved tree equality.
  #   HEAD-exact log     → the anchor is an ORPHAN; blobs resolve at its OWN sha
  #                        (chain_admit) so it cannot self-validate.
  local review_log="$harness_dir/review-log/$head_sha.json"
  local extra_admit="" chain_admit="" anchor_sha=""
  anchor_sha=$(jq -r '.review_anchor_sha // .verified_sha // ""' "$done_state_file" 2>/dev/null)
  if [ -n "$anchor_sha" ] && { command -v hc__is_object_id >/dev/null 2>&1 || type hc__is_object_id >/dev/null 2>&1; }; then
    if hc__is_object_id "$anchor_sha" && [ -f "$harness_dir/review-log/$anchor_sha.json" ]; then
      if [ ! -f "$review_log" ]; then
        review_log="$harness_dir/review-log/$anchor_sha.json"
        extra_admit="$anchor_sha"
      else
        chain_admit="$anchor_sha"
      fi
    fi
  fi
  if [ ! -f "$review_log" ]; then
    HC_DONE_BLOCKED_REASON="no review-log at HEAD"
    return 0
  fi

  # --- 4. review-log must pass the hard-contract schema. ----------------------
  # A missing schema file → hc_validate nonzero → block (broken install, safe).
  if command -v hc_validate >/dev/null 2>&1 || type hc_validate >/dev/null 2>&1; then
    if ! hc_validate "$contracts_dir/review-log.schema.json" "$review_log" >/dev/null 2>&1; then
      HC_DONE_BLOCKED_REASON="review-log fails schema"
      return 0
    fi
  else
    HC_DONE_BLOCKED_REASON="contract validator unavailable"
    return 0
  fi

  # --- 5. hc_review_blocking must be exactly "0" (ERR / non-zero → block). ----
  local open
  if command -v hc_review_blocking >/dev/null 2>&1 || type hc_review_blocking >/dev/null 2>&1; then
    open=$(hc_review_blocking "$review_log" "$min_level")
  else
    open="ERR"
  fi
  if [ "$open" != "0" ]; then
    HC_DONE_BLOCKED_REASON="${open} blocking review finding(s)"
    return 0
  fi

  # --- 6. hc_review_coverage_gap must be empty OR "SKIP". ---------------------
  # SKIP (no changeset base → not computable) is a graceful degrade, NOT a block.
  local gap
  if command -v hc_review_coverage_gap >/dev/null 2>&1 || type hc_review_coverage_gap >/dev/null 2>&1; then
    gap=$(hc_review_coverage_gap "$review_log" "$base" "$head_sha" "$proj" "$extra_admit" "$chain_admit")
  else
    # Library failed to source — fail toward block, never toward an allow.
    gap="LIBUNAVAILABLE"
  fi
  if [ -n "$gap" ] && [ "$gap" != "SKIP" ]; then
    HC_DONE_BLOCKED_REASON="review coverage gap"
    return 0
  fi

  # --- 7. task_checks: count of entries with status != "passed" must be 0. ----
  # An absent task_checks yields length 0 (vacuously green). A jq crash yields ""
  # which is != "0" → block. The FIRST not-passed check names the reason.
  local task_failed
  task_failed=$(jq -r '[.task_checks[]? | select(.status != "passed")] | length' "$done_state_file" 2>/dev/null)
  if [ "$task_failed" != "0" ]; then
    local first_failed
    first_failed=$(jq -r 'first(.task_checks[]? | select(.status != "passed") | .desc) // "?"' "$done_state_file" 2>/dev/null)
    [ -z "$first_failed" ] && first_failed="?"
    HC_DONE_BLOCKED_REASON="task check '${first_failed}' not passed"
    return 0
  fi

  # All 7 green → not blocked (HC_DONE_BLOCKED_REASON stays "").
  return 0
}

# ---------------------------------------------------------------------------
# hc_state <session_id>
#
# The composed state classifier: maps the current changeset+tree+done-state to
# exactly ONE of five operator-facing states, and derives the canonical next
# action. It COMPOSES the existing single-source predicates (hc_resolve,
# hc_tree_status, hc_validate, hc_done_state_blocked) — it invents no new
# semantics; each branch mirrors a decision already made in done-gate.sh so the
# operator-facing state can never drift from what the Stop gate actually enforces.
#
# Sets shell globals:
#   HC_STATE — one of: S0 S_OOS S1 S2 S4 S5.
#   HC_NEXT  — the canonical next-action string (empty "" for silent states).
#
# The states and their gate correspondence:
#   S0 idle      — tree clean, no committed work past base. Nothing to gate.
#                  (gate Step 3 quiet-exit.) Silent: HC_NEXT="".
#   S_OOS out-of-scope — there IS a changeset (introduced tree blockers OR
#                  HEAD past base) but hc_changeset_is_code reports the WHOLE
#                  changeset is NON-CODE (#5). The harness stands down entirely:
#                  the Stop gate exits 0 silently (its own scope short-circuit)
#                  and SessionStart emits nothing. Terminal, silent: HC_NEXT="".
#                  Evaluated AFTER the S0-idle/empty check (an empty changeset
#                  stays S0) and BEFORE S1/S2/S4/S5. Fail-safe: is-code error →
#                  CODE → this branch is not taken → normal gating.
#   S1 working   — introduced tree blockers exist. "Introduced-dirty dominates":
#                  checked FIRST, before any commit/done reasoning, exactly as the
#                  gate would ultimately block on Step 6. HC_NEXT points at finishing
#                  and committing the slice.
#   S2 committed-unverified — committed work past base, tree clean, but the
#                  done-state is MISSING / schema-invalid / stale (verified_sha !=
#                  HEAD). (gate Steps 4/4b/5 block.) HC_NEXT points at running /done.
#   S4 blocked-on-X — a VALID done-state at the current HEAD, no escalation, but
#                  hc_done_state_blocked reports a live blocking outcome. (gate
#                  Step 8 blocks.) HC_NEXT is the specific remedy for that reason.
#   S5 verified  — either a valid done-state at HEAD with an escalation override
#                  (gate Step 7 allow), OR a valid done-state at HEAD whose Step-8
#                  outcomes are all green (gate Step 9 allow). Silent: HC_NEXT="".
#
# Escalation sits ABOVE the blocked predicate (mirroring gate Step 7 running
# before Step 8): when a non-null .escalation is present we go straight to S5
# and do NOT even call hc_done_state_blocked.
#
# Reachability / disjointness: every tree maps to exactly one state. The empty
# changeset (no introduced dirt AND no committed work past base) maps to S0.
# Given a NON-empty changeset, the scope gate (S_OOS) splits first: a wholly
# non-code changeset is out of scope. A CODING changeset then flows through the
# normal ladder — S1 is the introduced-dirty guard (dominates). Given a clean
# tree, S0 vs {S2,S4,S5} splits on "committed work past base?". Given committed
# work, S2 vs {S4,S5} splits on
# "valid done-state at HEAD?". Given a valid done-state at HEAD, S5-via-escalation
# vs {S4,S5-green} splits on "escalation present?", and finally S4 vs S5-green
# splits on hc_done_state_blocked's verdict. No overlap.
#
# --- S4-vs-S2 boundary (verified from done-write-state.sh, DO NOT GUESS) -----
# done-write-state.sh stamps verified_sha=HEAD ONLY on a full-success (or
# escalated) write: with NO escalation it `exit 1`s BEFORE writing whenever
# tests/lint/review/coverage/task_checks are not green (lines 132-217), so a
# FAILED /done attempt with no escalation writes NO done-state at all — leaving
# the prior (stale or absent) done-state whose verified_sha != HEAD. That case
# therefore collapses into S2 (committed-unverified), NOT S4.
#
# Consequence: in the normal /done flow S4 is NOT reachable via a plain failed
# attempt. S4 is reachable ONLY when a done-state that is VALID and stamped at the
# CURRENT HEAD nonetheless has a live blocking outcome — i.e. the recorded outcome
# or the live HEAD-keyed review evidence has diverged from green AT this HEAD.
# Concretely reachable via:
#   (a) the review-log for HEAD is later deleted/absent  → check 3 blocks,
#   (b) an escalated write recorded a red tests.exit_code and the escalation is
#       then removed/nulled (Step 7 no longer short-circuits) → check 1 blocks,
#   (c) a done-state stamped at HEAD recording a failed task_check with an
#       escalation later dropped → check 7 blocks,
#   (d) a coverage gap at HEAD after the review-log's files_reviewed no longer
#       covers the changeset → check 6 blocks.
# All four are states the Stop gate's Step 8 would itself block on at this HEAD —
# hc_state surfaces the same verdict pre-emptively. The fixture test exercises S4
# by writing a valid done-state stamped at HEAD with tests.exit_code=1 and no
# escalation (case (b)'s end-state), and a separate coverage-gap fixture (case (d)).
hc_state() {
  local session_id="$1"

  # Reset outputs so a repeat call never leaks stale values.
  HC_STATE=""
  HC_NEXT=""

  # Compose the identity resolver + tree classifier. hc_resolve sets HC_MODE /
  # HC_BASE / HC_TASK_KEY / HARNESS_DIR / HC_CONTRACTS_DIR; hc_tree_status sets
  # HC_TREE_BLOCKERS relative to the pinned baseline (needs hc_resolve first).
  hc_resolve "$session_id"
  hc_tree_status "$session_id"

  local proj="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  local head_sha head_tree
  head_sha=$(git -C "$proj" rev-parse HEAD 2>/dev/null)
  # HEAD's TREE id — the content fingerprint the S2-vs-S5 boundary compares
  # against, exactly as the gate's Step 5 does. Empty → no tree, no proof of
  # identical content → the carry below refuses (strict).
  head_tree=$(git -C "$proj" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)

  # "Committed work exists" = HEAD has moved past the resolver's anchor (HC_BASE).
  # In task mode HC_BASE is the pinned fork base; in session mode it is the
  # SessionStart baseline sha (empty when SessionStart recorded nothing). We have
  # committed work iff HC_BASE is a real sha AND HEAD != HC_BASE.
  local committed_work=0
  if [ -n "$HC_BASE" ] && [ -n "$head_sha" ] && [ "$head_sha" != "$HC_BASE" ]; then
    committed_work=1
  fi

  # --- S0 idle: empty changeset. ----------------------------------------------
  # No introduced tree blockers AND no committed work past base → nothing we can
  # attribute to this changeset → idle (gate Step 3 quiet-exit). Checked FIRST so
  # a genuinely empty changeset never reaches the scope gate below. Silent state.
  if [ -z "$HC_TREE_BLOCKERS" ] && [ "$committed_work" -eq 0 ]; then
    HC_STATE="S0"
    HC_NEXT=""
    return 0
  fi

  # --- S_OOS out-of-scope: the WHOLE changeset is non-code (#5). ---------------
  # A changeset exists (introduced dirt OR committed work). Ask the scope
  # predicate whether every changed file is non-code. NON-CODE (rc 1) → the
  # harness stands down entirely (terminal, silent). CODE (rc 0) or the "empty"
  # sentinel (rc 2, cannot occur here — we established a non-empty changeset) →
  # fall through to normal gating. Fail-safe: any predicate error resolves to
  # CODE inside hc_changeset_is_code, so an error never lands us in S_OOS.
  if command -v hc_changeset_is_code >/dev/null 2>&1 || type hc_changeset_is_code >/dev/null 2>&1; then
    local scope
    scope=$(hc_changeset_is_code "$HC_BASE" "$head_sha" "$proj" 2>/dev/null)
    if [ "$scope" = "noncode" ]; then
      HC_STATE="S_OOS"
      HC_NEXT=""
      return 0
    fi
  fi

  # --- S1 working: introduced-dirty dominates. --------------------------------
  # Uncommitted (coding) work THIS session blocks first, before any commit/done
  # reasoning (gate Step 6).
  if [ -n "$HC_TREE_BLOCKERS" ]; then
    HC_STATE="S1"
    HC_NEXT="finish the slice, then commit"
    return 0
  fi

  # Tree is clean from here on.

  # --- committed work exists, tree clean: locate the done-state. --------------
  local done_state_file="$HARNESS_DIR/done-state/$HC_TASK_KEY.json"

  # S2 committed-unverified: done-state MISSING, schema-invalid, or stale. Any of
  # these means the current changeset was never verified at THIS HEAD (gate
  # Steps 4 / 4b / 5). Because done-write-state.sh only stamps verified_sha=HEAD
  # on a successful/escalated write, a failed plain /done attempt lands here (its
  # verified_sha != HEAD), not in S4.
  #
  # "STALE" is TREE equality, not sha equality — the identical test gate Step 5
  # applies. Classifying by sha alone made the harness CONTRADICT ITSELF after a
  # tree-identical HEAD move (an amend that only rewords, a rebase replaying the
  # same patches): the Stop gate carried the verification and ALLOWED, while the
  # next SessionStart still classified S2 and steered "run /done" for a changeset
  # already verified. Same sources, same order, same fail direction as Step 5:
  # the done-state's recorded head_tree, else — for LEGACY states written before
  # that field existed — the tree recomputed live from verified_sha; and when
  # verified_sha still resolves, its tree is cross-checked too. An empty
  # head_tree, an unobtainable recorded tree, or any mismatch → NOT valid at head
  # → S2, exactly as before.
  local verified_sha=""
  local valid_at_head=0
  if [ -f "$done_state_file" ]; then
    if hc_validate "$HC_CONTRACTS_DIR/done-state.schema.json" "$done_state_file" >/dev/null 2>&1; then
      verified_sha=$(jq -r '.verified_sha // ""' "$done_state_file" 2>/dev/null)
      if [ -n "$verified_sha" ] && [ "$verified_sha" = "$head_sha" ]; then
        valid_at_head=1
      elif [ -n "$verified_sha" ] && [ -n "$head_tree" ]; then
        local ds_tree vs_tree
        ds_tree=$(jq -r '.head_tree // ""' "$done_state_file" 2>/dev/null)
        vs_tree=$(git -C "$proj" rev-parse -q --verify "${verified_sha}^{tree}" 2>/dev/null)
        [ -z "$ds_tree" ] && ds_tree="$vs_tree"
        if [ -n "$ds_tree" ] && [ "$ds_tree" = "$head_tree" ] \
           && { [ -z "$vs_tree" ] || [ "$vs_tree" = "$head_tree" ]; }; then
          valid_at_head=1
        fi
      fi
    fi
  fi
  if [ "$valid_at_head" -eq 0 ]; then
    HC_STATE="S2"
    HC_NEXT="run /done to verify the changeset (owns the Step-5 review)"
    return 0
  fi

  # --- valid done-state stamped at HEAD. --------------------------------------
  # Escalation sits ABOVE the blocked predicate (gate Step 7 before Step 8): a
  # non-null .escalation short-circuits straight to S5 (verified), WITHOUT calling
  # hc_done_state_blocked. Silent state.
  local escalation
  escalation=$(jq -r '.escalation // "null"' "$done_state_file" 2>/dev/null)
  if [ -n "$escalation" ] && [ "$escalation" != "null" ]; then
    HC_STATE="S5"
    HC_NEXT=""
    return 0
  fi

  # No escalation → the Step-8 outcome aggregation decides S4 vs S5.
  local min_level
  min_level=$(jq -r '.min_review_level // "high"' "$proj/.claude/done-config.json" 2>/dev/null)
  [ -z "$min_level" ] && min_level="high"

  hc_done_state_blocked "$done_state_file" "$head_sha" "$HC_BASE" \
    "$HARNESS_DIR" "$HC_CONTRACTS_DIR" "$min_level"

  if [ -n "$HC_DONE_BLOCKED_REASON" ]; then
    # --- S4 blocked-on-X: derive the specific remedy from the reason. ---------
    HC_STATE="S4"
    case "$HC_DONE_BLOCKED_REASON" in
      tests\ failed*)          HC_NEXT="fix failing tests, re-commit, re-run /done" ;;
      lint\ failed*)           HC_NEXT="fix lint, re-commit, re-run /done" ;;
      "review coverage gap")   HC_NEXT="review the uncovered files, then re-run /done" ;;
      "no review-log at HEAD") HC_NEXT="run an independent code review, then re-run /done" ;;
      *blocking\ review*)      HC_NEXT="address the blocking review findings, then re-run /done" ;;
      task\ check\ *)          HC_NEXT="resolve: ${HC_DONE_BLOCKED_REASON}, then re-run /done" ;;
      *)                       HC_NEXT="resolve: ${HC_DONE_BLOCKED_REASON}, then re-run /done" ;;
    esac
    return 0
  fi

  # --- S5 verified: valid done-state at HEAD, no escalation, all outcomes green.
  # Silent state (gate Step 9 allow).
  HC_STATE="S5"
  HC_NEXT=""
  return 0
}
