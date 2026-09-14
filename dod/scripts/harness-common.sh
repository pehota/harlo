#!/bin/bash
#
# task-DoD plugin — shared identity resolver (sourced library).
#
# Trimmed copy of completion-harness/scripts/harness-common.sh: only the
# functions dod/*.sh actually call, plus the globals/preamble they read.
# Function bodies are verbatim — nothing rewritten, only unreferenced
# functions and their attached comment blocks removed. See
# completion-harness/scripts/harness-common.sh for the full library this was
# trimmed from.
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
# hc_has_fn <name>
#
# "Is a function or command named <name> available in this shell?" — the
# `hc_has_fn X` probe every call
# site re-spelled before calling an hc_* helper that might not exist (e.g.
# this library failed to source). One name, one probe.
hc_has_fn() {
  command -v "$1" >/dev/null 2>&1 || type "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# hc_has_jq — "is jq on PATH?" boolean. The `command -v jq >/dev/null 2>&1`
# check recurred ~26 times across scripts touching config/state, most of
# them branching (degrade/allow) rather than dying, hence a boolean helper
# rather than only a die-on-missing one.
hc_has_jq() {
  command -v jq >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# hc_read_hook_input
#
# Reads the hook JSON payload from stdin ONCE and parses the fields hook
# scripts actually consume out of it: session_id, tool_input.file_path,
# tool_input.command, source, stop_hook_active. Was previously re-implemented
# independently by baseline-snapshot.sh and done-gate.sh (each
# its own `cat` + jq-guarded parse); this is the one canonical read.
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
#   HC_HOOK_TOOL_COMMAND     .tool_input.command (Bash tool payloads only —
#                            empty for every other tool_name, which is fine:
#                            no current consumer reads it — commit-ledger.sh
#                            observes HEAD movement instead of parsing command
#                            text)
#   HC_HOOK_TOOL_BACKGROUND  .tool_input.run_in_background (text "true"/"false";
#                            Bash tool payloads only, "false" everywhere else).
#                            commit-ledger.sh needs it because PostToolUse fires
#                            when the TOOL RETURNS, not when a backgrounded
#                            shell exits — so a session that backgrounded a job
#                            can commit BETWEEN call windows and the
#                            "outside every window ⇒ foreign" inference dies.
#   HC_HOOK_TOOL_USE_ID      .tool_use_id — the id of the ONE tool call this
#                            event belongs to. Both PreToolUse and PostToolUse
#                            carry it (verified against the Claude Code 2.1.267
#                            payload builder); older CLIs may not, so every
#                            consumer must degrade when it is empty.
#                            commit-ledger.sh keys its per-call cursor on it, so
#                            parallel tool calls in one session cannot narrow
#                            each other's sweep window.
#   HC_HOOK_SOURCE           .source
#   HC_HOOK_STOP_ACTIVE      .stop_hook_active (text "true"/"false")
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

hc_read_hook_input() {
  HC_HOOK_RAW=$(cat 2>/dev/null)
  HC_HOOK_SESSION_ID=""
  HC_HOOK_TOOL_FILE_PATH=""
  HC_HOOK_TOOL_COMMAND=""
  HC_HOOK_TOOL_BACKGROUND="false"
  HC_HOOK_TOOL_USE_ID=""
  HC_HOOK_SOURCE=""
  HC_HOOK_STOP_ACTIVE="false"
  if hc_has_jq; then
    HC_HOOK_SESSION_ID=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.session_id // ""' 2>/dev/null)
    HC_HOOK_TOOL_FILE_PATH=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
    HC_HOOK_TOOL_COMMAND=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.tool_input.command // ""' 2>/dev/null)
    HC_HOOK_TOOL_BACKGROUND=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)
    HC_HOOK_TOOL_USE_ID=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.tool_use_id // ""' 2>/dev/null)
    HC_HOOK_SOURCE=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.source // ""' 2>/dev/null)
    HC_HOOK_STOP_ACTIVE=$(printf '%s' "$HC_HOOK_RAW" | jq -r '.stop_hook_active // false' 2>/dev/null)
  fi
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
# Keys read through this (in this plugin): artifact_paths (dod/lib-classify.sh
# — the task-DoD skeleton's product/artifact glob split; an ARRAY key, printed
# space-joined by the `join(" ")` branch below), and untracked_policy (below,
# in hc_tree_status). `trunk` is deliberately NOT among them — see
# hc__detect_trunk.
#
# A `has()` probe, never a bare `//` default: jq's `//` treats a literal `false`
# as empty and would flip an explicit `false` back to the default. A
# JSON `null` means "not set here" and falls through to the next layer. Arrays
# are printed space-joined (the shape the glob-list readers want).
#
# Fail direction: no jq, no file, unreadable key → the caller's default. Never
# fabricates a value.
hc_cfg() {
  local key="$1" def="${2:-}"
  # <proj> (3rd, optional) so a caller working on a checkout OTHER than the
  # ambient PROJECT_DIR reads THAT checkout's config — the worktree callers pass
  # such a proj, and silently ignoring it would answer from the wrong repo.
  local proj="${3:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"

  hc_has_jq || { printf '%s' "$def"; return 0; }

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

# Offline, conservative trunk detection. Prints the trunk name, or nothing
# (empty = UNCONFIDENT). Never consults origin/HEAD (repos may have no remote).
hc__detect_trunk() {
  local cfg="$PROJECT_DIR/$HC_CONFIG_REL"
  local t=""

  # Deliberately NOT hc_cfg: `trunk` is the ONE knob the session layer must not
  # reach. It selects task-vs-session mode, computes the task key, drives
  # task tree-base, and feeds SessionStart's terminal reap, which DELETES the state
  # of branches it judges merged. A wrong trunk there destroys state rather than
  # merely loosening a check — too much authority for an ephemeral,
  # agent-written file, and nothing asked for a per-task trunk.
  if hc_has_jq && [ -f "$cfg" ]; then
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
# hc__commit_in_any_ledger <commit_sha>
#
# THE session-authorship predicate. Returns 0 iff <commit_sha> is a recorded
# whole line in ANY session's commit ledger under $HARNESS_DIR/baselines/
# *.own-commits — the append-only files the commit-ledger.sh Bash hook writes
# (PreToolUse pins HEAD, PostToolUse sweeps whatever HEAD moved over during the
# call). Ledger membership is a POSITIVE, DIRECTLY-OBSERVED signal: HEAD moved
# inside an agent tool-call window, so an agent produced it.
#
# WHY ACROSS ALL SESSIONS, not just the querying one: a commit authored by a
# CONCURRENT agent session is still agent-authored. Scoped per-session it would
# look foreign to every reader — the peer's commit absent from OUR ledger, ours
# absent from THEIRS — and both sessions would advance their base past work that
# nobody then reviews. Cross-session membership needs no extra age/scope bound:
# every query runs over base..HEAD (commits created after the querying session's
# own baseline), and session baselines are age-reaped at 14 days.
#
# Returns 1 on ANY other outcome: empty sha, no baselines dir, no ledger files,
# or the sha simply absent from all of them. A READ FAILURE is never read as a
# positive — a file we could not read contributes no lines, so it can only make
# the answer negative (exactly the old grep-failure semantics).
#
# COST. This used to fork one `grep -qxF` PER LEDGER FILE PER COMMIT. The old
# single-ledger predicate was one grep per commit; widening membership to the
# whole peer set multiplied that by the file count, so a 30-commit range against
# 40 peer ledgers cost ~1200 forks per range walk — and the populated-ledger
# path walks the range up to four times per Stop (base advance, changeset set,
# summary, coverage), against done-gate.sh's 10s hook timeout. A killed Stop
# hook emits no decision, i.e. a BLOCK silently becomes an allow.
#
# So the union of every ledger's SHAs is built ONCE per range walk
# (hc__ledger_set_load) into a newline-FRAMED blob and membership is an
# in-process `case` match — zero forks per COMMIT, and the walk's cost stops
# scaling with the range at all. The load itself costs one fork per ledger
# FILE; see hc__ledger_set_load for why that trade is the right way round, and
# for the file-count ceiling it leaves behind. Do NOT restate this as "zero
# forks": that exact claim sat here while the loader underneath it was
# quadratic, and an over-confident comment is what let the regression ship.
#
# WHY A BLOB AND NOT AN ASSOCIATIVE ARRAY: `declare -A` needs bash 4, and macOS
# still ships bash 3.2 as /bin/bash — the interpreter of every hook here. The
# blob also gives the two semantics that must not drift for free:
#   - WHOLE-LINE matching: the searched pattern is "\n<sha>\n", so a sha that is
#     a prefix/substring of a ledgered one cannot match.
#   - NO PATTERN INTERPRETATION: the needle is QUOTED inside the case pattern,
#     so glob metacharacters in it are literal (the -F half of `grep -qxF`).
hc__commit_in_any_ledger() {
  local sha="$1"
  [ -z "$sha" ] && return 1
  [ -z "$HARNESS_DIR" ] && return 1
  # Outside a walker's scope the cache is REBUILT on every call: a caller that
  # mutates a ledger and re-queries in the same process (the test suites, a
  # writer resolving twice) must never read a stale set, and a stale MISS is the
  # silent-skip direction. Inside a scope the ledger cannot change under us
  # (single-threaded walk), so the loop pays nothing.
  if [ "${HC__LEDGER_SET_SCOPE:-0}" -le 0 ]; then
    hc__ledger_set_load
  fi
  case "$HC__LEDGER_SET" in
    *"$HC__NL$sha$HC__NL"*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# The ledger membership cache. HC__LEDGER_SET holds the union of every
# baselines/*.own-commits line, newline-FRAMED (a leading and a trailing
# newline) so every entry is delimited on both sides and a whole-line `case`
# match needs no extra bookkeeping.
HC__NL='
'
HC__LEDGER_SET=""
HC__LEDGER_SET_SCOPE=0

# hc__ledger_set_load — rebuild HC__LEDGER_SET from $HARNESS_DIR/baselines.
# ONE fork per ledger FILE. An unreadable file simply contributes nothing (see
# the failure semantics above). No interpretation is applied: whatever a ledger
# holds is compared verbatim.
#
# WHY PER-FILE AND NOT PER-LINE: the obvious pure-builtin form — `read` a line
# and append it — is O(lines^2) in shell, because each append copies the whole
# accumulated blob. Forks were traded for quadratic copying, which measured
# WORSE than the per-commit grep it replaced: 5851 aggregate ledger lines took
# done-gate.sh 12.39s against its own Stop "timeout": 10, where a cancelled
# hook emits NO decision and a BLOCK silently becomes a pass. One `cat` per
# file is 0.24s at 6000 lines. A ledger that big is one `git pull` away, since
# a fast-forward window sweeps every commit it brings in.
#
# WHY NOT ONE `cat` OVER THE WHOLE GLOB: command substitution strips trailing
# newlines, so a file whose last line has no newline would be spliced onto the
# next file's first line and LOSE both memberships — the silent-skip direction.
# Substituting per file and re-framing with HC__NL restores the delimiter that
# the splice would have eaten. Blank interior lines survive here where the old
# loop dropped them; harmless, since a match needs HC__NL<sha>HC__NL and
# hc__commit_in_any_ledger rejects an empty sha before looking.
#
# THE CEILING THIS LEAVES: the concat is quadratic in LEDGER FILES now, not
# lines. Measured end-to-end on done-gate.sh: 40 files 0.32s, 200 2.02s, 500
# 9.24s, 1000 30.4s — so ~500 files is where the 10s Stop timeout is in play
# again, and a timed-out gate emits no decision. caseP guards the LINE axis
# (5851) but pins files at 40, so this axis is unguarded by test. Reachability
# is remote today (one file per session, age-reaped at 14 days, live dirs hold
# single digits), which is why it is documented rather than fixed.
# ponytail: quadratic in file count; chunk the concat or accumulate into an
# array joined once if a repo ever carries hundreds of session ledgers.
hc__ledger_set_load() {
  HC__LEDGER_SET=""
  [ -z "${HARNESS_DIR:-}" ] && return 0
  local dir="$HARNESS_DIR/baselines"
  [ -d "$dir" ] || return 0
  local f chunk blob=""
  for f in "$dir"/*.own-commits; do
    # No-glob-match leaves the literal pattern; -f filters it out.
    [ -f "$f" ] || continue
    chunk=$(cat "$f" 2>/dev/null)
    [ -n "$chunk" ] && blob="$blob$chunk$HC__NL"
  done
  [ -n "$blob" ] && HC__LEDGER_SET="$HC__NL$blob"
  return 0
}

# hc__ledger_set_open / _close — hold the cache across ONE range walk. Every
# function that loops hc__commit_in_any_ledger over a rev range brackets its
# loop with these, so the union is read once per walk instead of once per
# commit. The counter makes nesting safe (hc_session_changeset_files walks via
# hc_session_changeset_commits); both are placed around the tight loop only, so
# no early return can leak a scope.
hc__ledger_set_open() {
  HC__LEDGER_SET_SCOPE=$(( ${HC__LEDGER_SET_SCOPE:-0} + 1 ))
  hc__ledger_set_load
  return 0
}
hc__ledger_set_close() {
  if [ "${HC__LEDGER_SET_SCOPE:-0}" -gt 0 ]; then
    HC__LEDGER_SET_SCOPE=$(( HC__LEDGER_SET_SCOPE - 1 ))
  fi
  return 0
}

# ---------------------------------------------------------------------------
# hc__ledger_history_rewritten <session_id> [proj]
#
# UNCERTAINTY TRIPWIRE, not a fix. Returns 0 (rewrite detected) iff at least one
# sha in THIS SESSION'S ledger (baselines/<session_id>.own-commits) is either
# gone from the object store or no longer reachable from HEAD.
#
# WHY: the ledger keys on SHA identity, but rebase / amend / cherry-pick change
# the SHA while preserving the content. A mid-session `git pull --rebase`
# rewrites the agent's own commit A into A'; A' is in no ledger, so it reads as
# FOREIGN, the base advances past it, and REAL AGENT WORK SILENTLY SKIPS REVIEW.
# That is the one direction this harness must never fail in. So when our own
# ledgered shas have stopped being reachable, we refuse to attribute anything:
# the caller leaves HC_BASE at HC_BASE_ORIG, the full range stays in the
# changeset, and the gate engages. This does not RECOVER the attribution — it
# converts a silent skip into an over-block.
#
# SCOPE IS THIS SESSION'S LEDGER ONLY, deliberately — not the any-ledger set.
# Rewriting OUR OWN commits is the case we cannot attribute. Other sessions'
# ledgers routinely hold shas unreachable from our HEAD (they were on other
# branches, since deleted); tripping on those would block every session
# permanently for no reason.
#
# Absent or empty ledger has nothing to check → returns 1 (no-op). A session
# that observed no commit of its own cannot have had one rewritten, so the
# "nothing observed → advance to HEAD" path (a pure Q&A session Stopping
# cleanly) is untouched by this.
#
# COST IS O(1) IN PROCESS COUNT — exactly two git calls, whatever the ledger
# size. It used to be two forks PER LINE, which blew the Stop hook's 10s budget
# at a few hundred entries (measured: 120 lines 5.6s, 150 lines 6.0s) — and a
# single in-window `git pull` on a repo 150 commits behind produces a 150-line
# ledger in one go. Batched:
#   1. EXISTENCE — one `cat-file --batch-check` fed every ledger sha (peeled
#      `^{commit}`, preserving the old check's semantics: a non-commit object
#      must read as missing, not as a type). Any line reporting `missing` ⇒
#      rewritten.
#   2. REACHABILITY — one `rev-list --stdin ^HEAD` fed every ledger sha. Any
#      output at all means some ledger sha (or an ancestor of one) is not
#      reachable from HEAD ⇒ rewritten.
# ORDER IS LOAD-BEARING: existence first, because rev-list ERRORS OUT on a
# missing object instead of reporting it. `--ignore-missing` is deliberately
# NOT used as a substitute — it would silently swallow the destroyed-object case
# and turn it back into a skipped review.
#
# ponytail: THE REAL FIX is content identity — store `git patch-id` alongside
# each sha and match on either, which survives rebase/amend/cherry-pick and
# recovers the attribution instead of merely refusing to guess. That is a ledger
# FORMAT change with its own migration and tests, deliberately out of scope
# here. Until then this over-blocks, which is the safe direction.
hc__ledger_history_rewritten() {
  local session_id="$1"
  local proj="${2:-${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}}"
  [ -z "$session_id" ] && return 1
  [ -z "$HARNESS_DIR" ] && return 1
  local ledger="$HARNESS_DIR/baselines/${session_id}.own-commits"
  [ -s "$ledger" ] || return 1

  # Blank-stripped sha list. All-blank (a ledger of newlines) is the empty
  # ledger case → no-op, so case A keeps working.
  local shas
  shas=$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null)
  [ -z "$shas" ] && return 1

  # 1. EXISTENCE. batch-check exits 0 even for unknown objects, echoing the
  #    INPUT line followed by " missing" — so the exit status only tells us
  #    whether git ran at all.
  local check rc
  check=$(printf '%s\n' "$shas" | sed 's/$/^{commit}/' \
          | git -C "$proj" cat-file --batch-check 2>/dev/null)
  rc=$?
  # git itself failed, or produced nothing for a non-empty input: we cannot say
  # the ledger is intact, so report rewritten (over-block).
  [ "$rc" -ne 0 ] && return 0
  [ -z "$check" ] && return 0
  printf '%s\n' "$check" | grep -q ' missing$' && return 0

  # 2. REACHABILITY. `^HEAD` (per-rev negation) rather than `--not HEAD`, so the
  #    flag state of command-line args cannot leak onto the stdin revs.
  local unreachable
  unreachable=$(printf '%s\n' "$shas" | git -C "$proj" rev-list --stdin '^HEAD' 2>/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] && return 0
  [ -n "$unreachable" ] && return 0

  return 1
}

# Session-mode base: read the SessionStart baseline if present, else empty.
# Then ADVANCE past any LEADING run of commits NO agent tool call produced, so
# old/foreign history sitting under HEAD does not get dragged into a review
# demand.
#
# "Agent-produced" has exactly ONE source of truth: membership in a commit
# ledger under $HARNESS_DIR/baselines/*.own-commits (hc__commit_in_any_ledger).
# The ledger records HEAD movement observed INSIDE a Bash tool-call window
# (PreToolUse pins HEAD, PostToolUse sweeps the delta), across all sessions —
# so a concurrent agent session's commit still counts as agent work.
#
# There is NO email tier. It was deleted, not degraded away from: the human and
# Claude Code commit under the SAME git identity, so no commit is ever provably
# foreign by email, the base never advances, and a session that changed nothing
# still got a full /done demand because someone hand-committed in another
# terminal. That was the whole failure mode.
#
# CONSEQUENCE, DELIBERATE: ledger ABSENT or EMPTY ⇒ no commit in range is
# agent-authored ⇒ the loop advances HC_BASE all the way to HEAD ⇒ the gate's
# Step 3c sees an empty changeset and allows the Stop with no DoD run. Correct:
# no observed agent commit means no agent-committed work to review. Do NOT
# reintroduce a "safety" fallback here — it re-creates the block-forever bug.
# Uncommitted work is NOT covered by this and must not be: hc_tree_status gates
# it against the pinned tree baseline, ledger-independently.
#
# TWO UNCERTAINTY TRIPWIRES suppress the advance entirely (see the calls below):
# our own ledgered history having been rewritten under us
# (hc__ledger_history_rewritten), and a sweep the hook could not complete
# (baselines/<sid>.sweep-failed). Both mean attribution is unknowable, which is
# NOT the same statement as "nothing observed" — so they over-block rather than
# advance. Neither fires on the absent/empty-ledger path.
#
# Advance rule: walk orig_base..HEAD oldest→newest; while the leading commit is
# NOT in any ledger, set the new base to that commit; STOP at the FIRST commit
# that IS. HC_BASE becomes the new (advanced) base; HC_BASE_ORIG stays the
# original unadvanced baseline, so interior peer commits still fall out of the
# review SET rather than out of the range.
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

  # TRIPWIRE: if any commit THIS session recorded has become unreachable, our
  # own history was rewritten underneath us (a mid-session `git pull --rebase`
  # turns our A into an A' that is in no ledger and would read as foreign).
  # Attribution is then unknowable, so refuse to advance at all — the whole
  # range stays in the changeset and the gate engages. See
  # hc__ledger_history_rewritten. No-op on an absent/empty ledger.
  if hc__ledger_history_rewritten "$session_id" "$proj"; then
    return 0
  fi

  # SECOND TRIPWIRE, same over-block: commit-ledger.sh could not complete a
  # sweep (the pinned cursor object was destroyed — `git gc --prune=now` or a
  # `reflog expire` after an in-window amend — and the .sha-baseline retry
  # failed too), so it recorded baselines/<sid>.sweep-failed instead of
  # exiting quietly. A sweep we COULD NOT COMPLETE is UNKNOWN attribution, not
  # absence of work: the commits in that window may well be the agent's own and
  # simply never reached the ledger. Refuse to advance at all.
  if [ -f "$HARNESS_DIR/baselines/${session_id}.sweep-failed" ]; then
    return 0
  fi

  hc__ledger_set_open
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    if hc__commit_in_any_ledger "$c"; then
      # IN a ledger → an agent tool call produced it → STOP here; it and
      # everything after stay in the changeset and the gate engages.
      break
    fi
    # In NO ledger → never observed inside a tool-call window → foreign →
    # advance past it.
    HC_BASE="$c"
  done <<EOF
$revs
EOF
  hc__ledger_set_close
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
  # a path, so the message must not assert the session introduced it. Set BEFORE
  # the clean-tree early return so it is always defined for the caller.
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
# Minimal JSON-Schema (draft-07 keyword subset) validator, fail-closed, no
# external dependency beyond jq. Supports: type/required/properties/items/
# enum/const/additionalProperties/oneOf/not/minLength — deliberately not the
# full spec (no pattern/format/minItems/etc): the contracts this validates
# pin exact SHAPE and small enums, never regex-shaped strings, array-length
# floors, or const/enum/default values.
#
# Contract: prints "OK" and returns 0 when the instance is valid; prints
# "ERR: <path>: <what>" (the FIRST violation in document order) and returns 1
# on any invalidity or error. Fail-closed: jq missing, unreadable/unparseable
# schema or instance, or a jq runtime error → "ERR: ..." + return 1.
hc_validate() {
  local schema_file="$1" json_file="$2"

  # jq is mandatory — without it we cannot reason about JSON at all → reject.
  hc_has_jq || { printf 'ERR: jq unavailable\n'; return 1; }

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
