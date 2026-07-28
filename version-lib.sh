#!/bin/bash
#
# version-lib.sh — sourceable, side-effect-free semantic-version helpers.
#
# Source it (`. version-lib.sh`) to get the vlib_* functions; running it
# directly does nothing. All functions validate their inputs and fail loudly
# (nonzero return + stderr message) on malformed data — they never silently
# pass a bad version through.
#
# Version convention (SoT: completion-harness/.claude-plugin/plugin.json):
#   While MAJOR == 0 (0.x, "pre-1.0"): the API is unstable, so we damp bumps —
#     breaking → bump MINOR   (0.1.0 → 0.2.0)
#     feat     → bump PATCH   (0.1.0 → 0.1.1)
#     fix/perf → bump PATCH   (0.1.0 → 0.1.1)
#     none     → unchanged
#   For MAJOR >= 1 (standard semver):
#     breaking → bump MAJOR   (1.2.3 → 2.0.0)
#     feat     → bump MINOR   (1.2.3 → 1.3.0)
#     fix/perf → bump PATCH   (1.2.3 → 1.2.4)
#     none     → unchanged

# --- internal: validate an X.Y.Z version string -----------------------------
# Prints nothing; returns 0 if valid, 1 (with stderr) otherwise.
vlib__is_valid_version() {
  local v="${1-}"
  if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  echo "version-lib: malformed version '$v' (expected X.Y.Z)" >&2
  return 1
}

# --- vlib_level_from_subjects ------------------------------------------------
# Reads conventional-commit records on stdin and prints the HIGHEST release
# level implied by them: one of  breaking | feat | fix | none.
#
# Input format (documented, unambiguous): a stream of commit records, each
# record being  <subject>\n<body...>  terminated by a NUL byte (\0). This is
# exactly what `git log --format='%s%n%b%x00'` emits, so callers can pipe git
# straight in. A record's subject is its first line; every remaining line is
# body (used only to detect a `BREAKING CHANGE` footer).
#
# Per-commit level:
#   breaking  if subject matches ^<type>(<scope>)?!:   OR any body line starts
#             with `BREAKING CHANGE`
#   feat      if subject matches ^feat(<scope>)?:
#   fix|perf  if subject matches ^(fix|perf)(<scope>)?:
#   none      otherwise
# The result is the max over all records (breaking > feat > fix > none).
vlib_level_from_subjects() {
  local level="none"
  local record subject rest first_line line

  # NUL-delimited records; last record may lack a trailing NUL.
  while IFS= read -r -d '' record || [ -n "$record" ]; do
    # `git log` prints a newline BETWEEN entries, so every record after the
    # first arrives with a leading newline. Strip one leading newline so the
    # subject is truly the first content line.
    record="${record#$'\n'}"

    # Ignore an empty trailing record (stream may end with a NUL + newline).
    [ -n "$record" ] || continue

    # Split record into first line (subject) and the rest (body).
    first_line="${record%%$'\n'*}"
    subject="$first_line"

    local this="none"

    # Breaking via `!` before the colon: ^type(scope)?!:
    if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: ]]; then
      this="breaking"
    elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
      this="feat"
    elif [[ "$subject" =~ ^(fix|perf)(\([^\)]*\))?: ]]; then
      this="fix"
    fi

    # Breaking via `BREAKING CHANGE` body footer (overrides toward breaking).
    if [ "$this" != "breaking" ]; then
      rest="${record#*$'\n'}"
      if [ "$rest" != "$record" ]; then
        while IFS= read -r line; do
          if [[ "$line" == BREAKING\ CHANGE* ]]; then
            this="breaking"
            break
          fi
        done <<< "$rest"
      fi
    fi

    # Fold into running max.
    case "$this" in
      breaking) level="breaking" ;;
      feat)     [ "$level" = "breaking" ] || level="feat" ;;
      fix)      [ "$level" = "none" ] && level="fix" ;;
    esac
  done

  printf '%s\n' "$level"
}

# --- vlib_bump ---------------------------------------------------------------
# vlib_bump <current_version> <level>
# Prints the new version per the 0.x / standard rules. `none` prints the
# current version unchanged. Fails (nonzero) on a malformed version or an
# unknown level.
vlib_bump() {
  local cur="${1-}" level="${2-}"
  vlib__is_valid_version "$cur" || return 1

  local major minor patch
  IFS='.' read -r major minor patch <<< "$cur"

  case "$level" in
    none)
      printf '%s\n' "$cur"
      return 0
      ;;
    fix|feat|breaking) ;;
    *)
      echo "version-lib: unknown level '$level' (expected breaking|feat|fix|none)" >&2
      return 1
      ;;
  esac

  if [ "$major" -eq 0 ]; then
    # 0.x convention: damp everything one notch.
    case "$level" in
      breaking) minor=$((minor + 1)); patch=0 ;;
      feat|fix) patch=$((patch + 1)) ;;
    esac
  else
    # Standard semver.
    case "$level" in
      breaking) major=$((major + 1)); minor=0; patch=0 ;;
      feat)     minor=$((minor + 1)); patch=0 ;;
      fix)      patch=$((patch + 1)) ;;
    esac
  fi

  printf '%d.%d.%d\n' "$major" "$minor" "$patch"
}

# --- vlib_ge -----------------------------------------------------------------
# vlib_ge <a> <b>  → returns 0 if semver a >= b, else 1. Fails (nonzero, with
# a distinct stderr message) if either arg is malformed. NOTE: callers must
# distinguish "a < b" (return 1) from "bad input" (also nonzero) via stderr /
# by pre-validating; this helper is used only on versions already validated.
vlib_ge() {
  local a="${1-}" b="${2-}"
  vlib__is_valid_version "$a" || return 2
  vlib__is_valid_version "$b" || return 2

  local a1 a2 a3 b1 b2 b3
  IFS='.' read -r a1 a2 a3 <<< "$a"
  IFS='.' read -r b1 b2 b3 <<< "$b"

  if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
  if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
  if [ "$a3" -ne "$b3" ]; then [ "$a3" -gt "$b3" ]; return; fi
  return 0  # equal
}
