#!/bin/bash
#
# Completion Harness — provision a task worktree.
#
#   new-worktree.sh <branch-name> [worktree-path]
#
# Creates a branch + worktree from origin/<trunk>, carries the gitignored local
# config a fresh checkout cannot have, installs dependencies, and reports
# everything it did NOT do.
#
# WHY THIS EXISTS. On trunk the harness runs in SESSION mode, where the
# changeset anchor is keyed on session id — a runtime accident that vanishes
# when a hook does not fire, on resume, or when the state dir is deleted. On a
# branch it runs in TASK mode, where the anchor is branch-keyed and pinned once.
# Cheap worktrees make task mode the default, which removes that whole class of
# false block at the source instead of reporting it better.
#
# FROM origin/<trunk>, NOT the local branch. A local trunk may carry unpushed
# commits or be weeks stale; either would silently seed the task with state the
# reviewer never sees. Refusing when origin/<trunk> is unresolvable is the point
# — there is no safe guess.
#
# Fails loudly and EARLY (before touching anything), but never rolls back a
# worktree it already created: a failed install is something to debug in place.

set -u

BRANCH="${1:-}"
WT_PATH_ARG="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared helpers early (before the first die() call below) so hc_die
# is available. Sourcing has no dependency on anything checked in this
# script — it only sets HC_CONTRACTS_DIR and a few path constants.
# shellcheck source=harness-common.sh
if [ -f "$SCRIPT_DIR/harness-common.sh" ]; then
  . "$SCRIPT_DIR/harness-common.sh" 2>/dev/null
fi

HC_DIE_PREFIX="new-worktree"
die() { hc_die "$1"; }
say() { printf '%s\n' "$1"; }

[ -n "$BRANCH" ] || die "usage: new-worktree.sh <branch-name> [worktree-path]"

# --- source checkout --------------------------------------------------------
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
TOPLEVEL=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null)
[ -n "$TOPLEVEL" ] || die "not a git repository: $PROJECT_DIR"
PROJECT_DIR="$TOPLEVEL"

command -v jq >/dev/null 2>&1 || die "jq is required"
# If sourcing failed above, die() itself is unusable (it delegates to
# hc_die), so this one check stays a literal.
type hc__detect_trunk >/dev/null 2>&1 \
  || { printf 'new-worktree: harness-common.sh could not be sourced (needed for trunk resolution)\n' >&2; exit 1; }

# --- trunk: the harness's own resolution, not a second one ------------------
# hc__detect_trunk reads .claude/done-config.json's `trunk` override first, then
# probes refs/heads/main and refs/heads/master, and emits NOTHING when
# unconfident. Empty is a refusal, never a guess — substituting "main" here is
# exactly how a task gets branched off the wrong history.
TRUNK=$(hc__detect_trunk)
[ -n "$TRUNK" ] || die "cannot determine trunk confidently; set .trunk in .claude/done-config.json"

# --- refuse early -----------------------------------------------------------
if git -C "$PROJECT_DIR" show-ref --verify -q "refs/heads/$BRANCH" 2>/dev/null; then
  die "branch '$BRANCH' already exists — pick another name or delete it first"
fi

if [ -n "$WT_PATH_ARG" ]; then
  WT_PATH="$WT_PATH_ARG"
else
  WT_ROOT="${HC_WORKTREE_ROOT:-$PROJECT_DIR/.worktrees}"
  WT_PATH="$WT_ROOT/$(hc__sanitize "$BRANCH")"
fi
case "$WT_PATH" in /*) ;; *) WT_PATH="$PWD/$WT_PATH" ;; esac
[ -e "$WT_PATH" ] && die "worktree path already exists: $WT_PATH"

# --- fetch, then resolve origin/<trunk> -------------------------------------
say "Fetching origin…"
if ! git -C "$PROJECT_DIR" fetch --quiet origin 2>/dev/null; then
  die "git fetch origin failed — a worktree cut from stale local state is exactly what this script exists to prevent"
fi

START_REF="origin/$TRUNK"
START_SHA=$(git -C "$PROJECT_DIR" rev-parse -q --verify "refs/remotes/origin/$TRUNK" 2>/dev/null)
[ -n "$START_SHA" ] || die "$START_REF does not resolve after fetch — is the trunk '$TRUNK' pushed?"

# --- detect provisioning config ---------------------------------------------
# The probe is the single source of truth for install_cmd / link / setup_cmd.
# Its stderr is NOT swallowed: the one thing it complains about is a done-config
# that fails the contract, which means the detection cannot be persisted. The
# run still works (the probe falls back to this run's fresh detection), but the
# user needs to know why nothing was remembered.
WT_CONFIG=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$SCRIPT_DIR/worktree-detect.sh")
printf '%s' "$WT_CONFIG" | jq empty >/dev/null 2>&1 || WT_CONFIG='{}'

INSTALL_CMD=$(printf '%s' "$WT_CONFIG" | jq -r '.install_cmd // ""')
SETUP_CMD=$(printf '%s' "$WT_CONFIG"   | jq -r '.setup_cmd // ""')
LINKS=$(printf '%s' "$WT_CONFIG"       | jq -r '.link[]? // empty')
LINK_OVERFLOW=$(printf '%s' "$WT_CONFIG" | jq -r '.link_overflow[]? // empty')
CANDIDATES=$(printf '%s' "$WT_CONFIG"  | jq -r '.link_candidates[]? // empty')
CAND_OVERFLOW=$(printf '%s' "$WT_CONFIG" | jq -r '.link_candidates_overflow[]? // empty')
SETUP_CANDIDATES=$(printf '%s' "$WT_CONFIG" | jq -r '.setup_candidates[]? // empty')

# setup_cmd is honoured ONLY when a human put it in overrides. worktree-detect
# never writes a non-null detected.setup_cmd, but this script re-checks the
# provenance rather than trusting the merged effective value — the effective
# view cannot distinguish "detected" from "promoted", and running a heuristic
# setup target is the failure mode the whole design avoids.
SETUP_FROM_OVERRIDE=$(jq -r '.worktree.overrides.setup_cmd // ""' \
  "$PROJECT_DIR/.claude/done-config.json" 2>/dev/null)
if [ -z "$SETUP_FROM_OVERRIDE" ]; then
  SETUP_CMD=""
fi

# --- create the worktree ----------------------------------------------------
mkdir -p "$(dirname "$WT_PATH")" 2>/dev/null
say "Creating worktree at $WT_PATH from $START_REF ($(printf '%.12s' "$START_SHA"))…"
if ! git -C "$PROJECT_DIR" worktree add -b "$BRANCH" "$WT_PATH" "$START_REF" >/dev/null 2>&1; then
  die "git worktree add failed for '$BRANCH' at $WT_PATH"
fi

# --- carry the gitignored local config --------------------------------------
# ABSOLUTE symlinks back into the source checkout. These worktrees are
# short-lived, so an absolute link is the simplest thing that survives being
# read from any depth; a relative one would have to be recomputed per file.
# NEVER overwrite: if a path already exists in the new worktree it is either
# tracked content or something the user put there, and clobbering it would
# destroy work with no undo.
LINKED=""
SKIPPED_EXISTS=""
SKIPPED_MISSING=""
while IFS= read -r rel; do
  [ -z "$rel" ] && continue
  src="$PROJECT_DIR/$rel"
  dst="$WT_PATH/$rel"
  if [ ! -e "$src" ]; then
    SKIPPED_MISSING="${SKIPPED_MISSING}${SKIPPED_MISSING:+
}$rel"
    continue
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    SKIPPED_EXISTS="${SKIPPED_EXISTS}${SKIPPED_EXISTS:+
}$rel"
    continue
  fi
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  if ln -s "$src" "$dst" 2>/dev/null; then
    LINKED="${LINKED}${LINKED:+
}$rel"
  else
    SKIPPED_MISSING="${SKIPPED_MISSING}${SKIPPED_MISSING:+
}$rel (ln failed)"
  fi
done <<EOF
$LINKS
EOF

# --- install ----------------------------------------------------------------
INSTALL_RESULT="skipped (no install command detected)"
if [ -n "$INSTALL_CMD" ]; then
  say ""
  say "Installing: $INSTALL_CMD"
  if ( cd "$WT_PATH" && eval "$INSTALL_CMD" ); then
    INSTALL_RESULT="ok ($INSTALL_CMD)"
  else
    INSTALL_RESULT="FAILED ($INSTALL_CMD)"
  fi
fi

# --- setup (only when explicitly promoted) ----------------------------------
SETUP_RESULT="skipped (no overrides.setup_cmd set)"
if [ -n "$SETUP_CMD" ]; then
  say ""
  say "Running setup from overrides: $SETUP_CMD"
  if ( cd "$WT_PATH" && eval "$SETUP_CMD" ); then
    SETUP_RESULT="ok ($SETUP_CMD)"
  else
    SETUP_RESULT="FAILED ($SETUP_CMD)"
  fi
fi

# --- report -----------------------------------------------------------------
# Everything the filter saw is named. A candidate silently dropped is a config
# the user will spend an hour rediscovering when the app will not boot.
list_or_none() {
  if [ -z "$1" ]; then printf '    (none)\n'; else printf '%s\n' "$1" | sed 's/^/    /'; fi
}

say ""
say "Worktree ready."
say "  path:    $WT_PATH"
say "  branch:  $BRANCH  (from $START_REF)"
say "  install: $INSTALL_RESULT"
say "  setup:   $SETUP_RESULT"
say ""
say "  linked:"
list_or_none "$LINKED"
if [ -n "$SKIPPED_EXISTS" ]; then
  say "  NOT linked — a file already existed at the destination (never overwritten):"
  list_or_none "$SKIPPED_EXISTS"
fi
if [ -n "$SKIPPED_MISSING" ]; then
  say "  NOT linked — source file was gone by the time we linked:"
  list_or_none "$SKIPPED_MISSING"
fi
if [ -n "$LINK_OVERFLOW" ]; then
  say "  NOT linked — beyond the total-count cap (raise HC_WT_MAX_LINK or link by hand):"
  list_or_none "$LINK_OVERFLOW"
fi
if [ -n "$CANDIDATES$CAND_OVERFLOW" ]; then
  say "  NOT linked — gitignored but outside the allowlist. Promote any you need"
  say "  into .worktree.overrides.link in .claude/done-config.json:"
  list_or_none "$CANDIDATES
$CAND_OVERFLOW"
fi
if [ -n "$SETUP_CANDIDATES" ]; then
  say "  NOT run — setup candidates found. Promote one into"
  say "  .worktree.overrides.setup_cmd only if you know what it does:"
  list_or_none "$SETUP_CANDIDATES"
fi
say ""
say "  cd $WT_PATH"

case "$INSTALL_RESULT$SETUP_RESULT" in
  *FAILED*) exit 1 ;;
esac
exit 0
