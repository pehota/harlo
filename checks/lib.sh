#!/usr/bin/env bash
# Resolves the two roots and reads .harness.json.
#   HARNESS_HOME = where the harness scripts live (this file's parent's parent).
#   REPO         = the target project (env REPO wins; else git toplevel; else cwd).
HARNESS_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
CFG="$REPO/.harness.json"
# hcfg <jq-path> [default] -> value or default
hcfg(){ local v=""; [ -f "$CFG" ] && v=$(jq -r "$1 // empty" "$CFG" 2>/dev/null || true); echo "${v:-${2:-}}"; }
