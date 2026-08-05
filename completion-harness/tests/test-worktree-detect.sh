#!/bin/bash
#
# Tests for worktree-detect.sh — the worktree provisioning probe and, above all,
# the gitignored-config FILTER. The filter is the part that goes badly wrong if
# it goes wrong at all: `git ls-files --others --ignored` in a real monorepo
# returns a quarter of a million paths, and linking the wrong ones corrupts
# builds. Every filter rule has its own case here.
#
# Throwaway git repos via mktemp -d, same style as test-detect.sh /
# test-tree-status.sh. Nothing reads the developer's own checkout: the
# "real-world" assertion is a SYNTHETIC fixture reproducing a monorepo's shape
# (see the monorepo section), so the suite is hermetic on any machine.

SCRIPTS="$(cd "$(dirname "$0")/../scripts" && pwd)"
DETECT="$SCRIPTS/worktree-detect.sh"

# shellcheck source=./test-helpers.sh
. "$(cd "$(dirname "$0")" && pwd)/test-helpers.sh"

CLEANUP=()
trap 'for d in "${CLEANUP[@]}"; do rm -rf "$d" 2>/dev/null; done' EXIT

# new_repo → a fresh git repo on main with one commit. Echoes the path.
new_repo() {
  local r; r=$(mktemp -d); CLEANUP+=("$r")
  git -C "$r" init -q -b main 2>/dev/null || {
    git init "$r" >/dev/null 2>&1; ( cd "$r" && git branch -M main >/dev/null 2>&1 )
  }
  git -C "$r" config user.email t@t >/dev/null 2>&1
  git -C "$r" config user.name  t   >/dev/null 2>&1
  printf 'seed\n' > "$r/README.md"
  git -C "$r" add -A >/dev/null 2>&1
  git -C "$r" commit -qm seed >/dev/null 2>&1
  printf '%s' "$r"
}

# detect <repo> [env assignments...] → effective config JSON on stdout.
detect() {
  local r="$1"; shift
  CLAUDE_PROJECT_DIR="$r" env "$@" bash "$DETECT" 2>/dev/null
}

# has <json> <jq filter> → 0 when the filter is truthy.
has() { printf '%s' "$1" | jq -e "$2" >/dev/null 2>&1; }

echo "== test-worktree-detect =="

# ===========================================================================
# 1. install_cmd detection across stacks — probe files, never guess.
# ===========================================================================
echo "-- install_cmd across stacks --"

# stack_is <label> <expected install_cmd> <file>...
stack_is() {
  local label="$1" want="$2"; shift 2
  local r; r=$(new_repo)
  local f
  for f in "$@"; do
    mkdir -p "$(dirname "$r/$f")" 2>/dev/null
    printf '{}\n' > "$r/$f"
  done
  local out; out=$(detect "$r")
  if has "$out" ".install_cmd == \"$want\""; then
    ok "$label → $want"
  else
    bad "$label → got $(printf '%s' "$out" | jq -c '.install_cmd' 2>/dev/null) (want \"$want\")"
  fi
}

stack_is "node + pnpm"       "pnpm install --prefer-offline" package.json pnpm-lock.yaml
stack_is "node + npm (lock)" "npm ci"                        package.json package-lock.json
stack_is "node, no lockfile" "npm install"                   package.json
stack_is "node + yarn classic" "yarn install --frozen-lockfile" package.json yarn.lock
stack_is "node + yarn berry"   "yarn install --immutable"      package.json yarn.lock .yarnrc.yml
stack_is "cargo (locked)"    "cargo fetch --locked"          Cargo.toml Cargo.lock
stack_is "cargo (no lock)"   "cargo fetch"                   Cargo.toml
stack_is "go"                "go mod download"               go.mod go.sum
stack_is "python + uv"       "uv sync --frozen"              pyproject.toml uv.lock
stack_is "python + poetry"   "poetry install --no-interaction" pyproject.toml poetry.lock
stack_is "python + pip"      "pip install -r requirements.txt" requirements.txt
stack_is "ruby"              "bundle install --local"        Gemfile Gemfile.lock
stack_is "php"               "composer install --no-interaction" composer.json composer.lock

# Unknown stack: degrades to a null install_cmd and exit 0 — a legitimate
# answer, not an error. new-worktree.sh still links and reports.
R=$(new_repo)
printf 'x\n' > "$R/main.cbl"
OUT=$(CLAUDE_PROJECT_DIR="$R" bash "$DETECT" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && has "$OUT" '.install_cmd == null'; then
  ok "unknown stack → install_cmd null, exit 0 (degrades, never errors)"
else
  bad "unknown stack → rc=$RC out=$OUT"
fi

# ===========================================================================
# 2. setup_cmd is NEVER auto-detected into a runnable value.
# ===========================================================================
echo "-- setup_cmd stays null; candidates are reported only --"
R=$(new_repo)
cat > "$R/package.json" <<'JSON'
{ "name": "x", "scripts": { "setup": "./scripts/drop-and-seed-db.sh", "prepare": "husky" } }
JSON
printf 'setup:\n\techo hi\n' > "$R/Makefile"
printf 'setup:\n  echo hi\n' > "$R/justfile"
OUT=$(detect "$R")
if has "$OUT" '.setup_cmd == null'; then
  ok "setup_cmd is null even with a package.json 'setup' script present"
else
  bad "setup_cmd was auto-detected: $(printf '%s' "$OUT" | jq -c .setup_cmd)"
fi
for want in "npm run setup" "npm run prepare" "make setup" "just setup"; do
  if has "$OUT" "(.setup_candidates | index(\"$want\")) != null"; then
    ok "reports setup candidate '$want'"
  else
    bad "missing setup candidate '$want' in $(printf '%s' "$OUT" | jq -c .setup_candidates)"
  fi
done

# ===========================================================================
# 3. THE FILTER.
# ===========================================================================
echo "-- filter: directories and anything nested inside them --"
R=$(new_repo)
cat > "$R/.gitignore" <<'GI'
node_modules/
dist/
.env
GI
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
mkdir -p "$R/node_modules/somepkg" "$R/dist"
printf 'SECRET=1\n' > "$R/.env"
printf 'X=1\n'      > "$R/node_modules/.env"
printf 'X=1\n'      > "$R/node_modules/somepkg/.env"
printf 'built\n'    > "$R/dist/bundle.js"
OUT=$(detect "$R")
if has "$OUT" '.link == [".env"]'; then
  ok "links the top-level .env only"
else
  bad "link should be exactly [\".env\"]; got $(printf '%s' "$OUT" | jq -c .link)"
fi
if has "$OUT" '[.link[], .link_candidates[]] | map(select(test("node_modules|dist"))) | length == 0'; then
  ok "nothing under an ignored directory reaches link or candidates"
else
  bad "ignored-directory content leaked: $(printf '%s' "$OUT" | jq -c '[.link[], .link_candidates[]]')"
fi
if has "$OUT" '.skipped.nested_in_ignored_dir >= 0'; then
  ok "reports a nested-skip count rather than dropping silently"
else
  bad "no skipped.nested_in_ignored_dir counter"
fi

echo "-- filter: a .env nested at depth is still included --"
R=$(new_repo)
printf 'projects/*/.env\n' > "$R/.gitignore"
mkdir -p "$R/projects/svc"
printf 'code\n' > "$R/projects/svc/main.go"          # tracked → dir not collapsed
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
printf 'A=1\n' > "$R/projects/svc/.env"
OUT=$(detect "$R")
if has "$OUT" '.link == ["projects/svc/.env"]'; then
  ok "a .env two levels deep is linked"
else
  bad "nested .env not linked; got $(printf '%s' "$OUT" | jq -c .link)"
fi

echo "-- filter: a WHOLLY-untracked directory is collapsed, so its .env is out --"
# Consequence of --directory, asserted deliberately rather than discovered
# later: when git tracks NOTHING in a directory, it reports the directory (one
# entry, trailing slash) instead of its contents. The directory will not exist
# in a fresh worktree at all, so there is nothing to link a config INTO — the
# nested-skip rule and the provisioning reality agree. Observed live in the
# motivating monorepo (projects/mcp-server/ was entirely local).
R=$(new_repo)
printf 'projects/*/.env\n' > "$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
mkdir -p "$R/projects/local-only"
printf 'A=1\n' > "$R/projects/local-only/.env"
OUT=$(detect "$R")
if has "$OUT" '.link == [] and .link_candidates == []'; then
  ok "a config inside a fully-untracked directory is not a candidate"
else
  bad "collapsed-directory content leaked: $(printf '%s' "$OUT" | jq -c '[.link, .link_candidates]')"
fi

echo "-- filter: depth cap --"
R=$(new_repo)
printf '.env.*\n' > "$R/.gitignore"
mkdir -p "$R/a/b/c/d/e"
printf 'keep\n' > "$R/a/b/c/d/e/keep.txt"            # tracked at the leaf → no
git -C "$R" add -A >/dev/null 2>&1                   # ancestor gets collapsed
git -C "$R" commit -qm gi >/dev/null 2>&1
printf 'A=1\n' > "$R/a/.env.shallow"                 # depth 2
printf 'A=1\n' > "$R/a/b/c/d/e/.env.deep"            # depth 6
OUT=$(detect "$R" HC_WT_MAX_DEPTH=3)
if has "$OUT" '(.link | index("a/.env.shallow")) != null and (.link | index("a/b/c/d/e/.env.deep")) == null'; then
  ok "depth cap keeps the shallow file and drops the deep one"
else
  bad "depth cap wrong; link=$(printf '%s' "$OUT" | jq -c .link)"
fi
if has "$OUT" '.skipped.over_depth == 1'; then
  ok "the over-depth file is COUNTED, not silently vanished"
else
  bad "skipped.over_depth=$(printf '%s' "$OUT" | jq -c .skipped.over_depth) (want 1)"
fi

echo "-- filter: size ceiling --"
R=$(new_repo)
printf '.env.*\n' > "$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
printf 'A=1\n' > "$R/.env.small"
# 4 KiB of 'x' — comfortably over a 100-byte ceiling.
awk 'BEGIN{for(i=0;i<4096;i++)printf "x"}' > "$R/.env.big"
OUT=$(detect "$R" HC_WT_MAX_BYTES=100)
if has "$OUT" '.link == [".env.small"] and .skipped.over_size == 1'; then
  ok "size ceiling drops the oversized file and counts it"
else
  bad "size ceiling wrong; link=$(printf '%s' "$OUT" | jq -c .link) skipped=$(printf '%s' "$OUT" | jq -c .skipped)"
fi

echo "-- filter: non-allowlisted ignored file is a CANDIDATE, never linked --"
R=$(new_repo)
cat > "$R/.gitignore" <<'GI'
.env
secrets.txt
config.private.toml
GI
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
printf 'A=1\n' > "$R/.env"
printf 'hunter2\n' > "$R/secrets.txt"
printf 'k=v\n' > "$R/config.private.toml"
OUT=$(detect "$R")
if has "$OUT" '.link == [".env"]'; then
  ok "only the allowlisted .env is linked"
else
  bad "link=$(printf '%s' "$OUT" | jq -c .link) (want [\".env\"])"
fi
if has "$OUT" '(.link_candidates | index("secrets.txt")) != null and (.link_candidates | index("config.private.toml")) != null'; then
  ok "non-allowlisted ignored files are REPORTED as candidates"
else
  bad "candidates=$(printf '%s' "$OUT" | jq -c .link_candidates)"
fi

echo "-- filter: the whole allowlist --"
R=$(new_repo)
cat > "$R/.gitignore" <<'GI'
.env
.env.development
.envrc
*.local.json
*.local.yaml
*.local.yml
appsettings.Development.json
local.settings.json
GI
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
for f in .env .env.development .envrc settings.local.json a.local.yaml b.local.yml \
         appsettings.Development.json local.settings.json; do
  printf 'x\n' > "$R/$f"
done
OUT=$(detect "$R")
if has "$OUT" '.link | length == 8'; then
  ok "all 8 allowlist shapes are linked"
else
  bad "allowlist incomplete: $(printf '%s' "$OUT" | jq -c .link)"
fi
if has "$OUT" '.link_candidates == []'; then
  ok "nothing allowlisted was demoted to a candidate"
else
  bad "unexpected candidates: $(printf '%s' "$OUT" | jq -c .link_candidates)"
fi

echo "-- filter: total-count cap REPORTS the overflow --"
R=$(new_repo)
printf '.env.*\n' > "$R/.gitignore"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm gi >/dev/null 2>&1
for i in 1 2 3 4 5; do printf 'x\n' > "$R/.env.f$i"; done
OUT=$(detect "$R" HC_WT_MAX_LINK=2)
if has "$OUT" '(.link | length) == 2 and (.link_overflow | length) == 3'; then
  ok "cap of 2 → 2 linked, 3 reported in link_overflow"
else
  bad "cap wrong; link=$(printf '%s' "$OUT" | jq -c .link) overflow=$(printf '%s' "$OUT" | jq -c .link_overflow)"
fi
if has "$OUT" '([.link[], .link_overflow[]] | sort) == ([".env.f1",".env.f2",".env.f3",".env.f4",".env.f5"])'; then
  ok "no silent truncation — link ∪ link_overflow is the whole matched set"
else
  bad "files went missing at the cap: $(printf '%s' "$OUT" | jq -c '[.link[], .link_overflow[]]')"
fi

# ===========================================================================
# 4. Monorepo-shaped fixture (hermetic reproduction of the real repo's shape).
# ===========================================================================
echo "-- monorepo fixture: exactly the local config, nothing else --"
R=$(new_repo)
cat > "$R/.gitignore" <<'GI'
node_modules/
dist/
.env
.claude/settings.local.json
*.tsbuildinfo
.DS_Store
GI
mkdir -p "$R/projects/frontend/src" "$R/projects/service" "$R/projects/analytics-service" \
         "$R/.claude" "$R/node_modules/pkg"
printf 'export {}\n' > "$R/projects/frontend/src/index.ts"
printf 'export {}\n' > "$R/projects/service/index.ts"
printf 'export {}\n' > "$R/projects/analytics-service/index.ts"
printf '{}\n'        > "$R/.claude/done-config-placeholder.json"
git -C "$R" add -A >/dev/null 2>&1; git -C "$R" commit -qm layout >/dev/null 2>&1
printf 'direnv\n' > "$R/.envrc"                                   # not ignored yet
printf '.envrc\n' >> "$R/.gitignore"
git -C "$R" add .gitignore >/dev/null 2>&1; git -C "$R" commit -qm gi2 >/dev/null 2>&1
printf 'A=1\n' > "$R/projects/frontend/.env"
printf 'A=1\n' > "$R/projects/service/.env"
printf 'A=1\n' > "$R/projects/analytics-service/.env"
printf '{}\n'  > "$R/.claude/settings.local.json"
# the noise a real checkout carries
printf 'junk\n' > "$R/.DS_Store"
printf 'junk\n' > "$R/projects/frontend/.DS_Store"
awk 'BEGIN{for(i=0;i<200000;i++)printf "x"}' > "$R/tsconfig.tsbuildinfo"
printf 'A=1\n' > "$R/node_modules/pkg/.env"
printf 'built\n' > "$R/projects/frontend/dist-placeholder" 2>/dev/null
mkdir -p "$R/dist"; printf 'b\n' > "$R/dist/out.js"
OUT=$(detect "$R")
EXPECT='[".claude/settings.local.json",".envrc","projects/analytics-service/.env","projects/frontend/.env","projects/service/.env"]'
if has "$OUT" "(.link | sort) == $EXPECT"; then
  ok "links exactly the 5 local-config files"
else
  bad "monorepo link set wrong: $(printf '%s' "$OUT" | jq -c '.link | sort')"
fi
if has "$OUT" '[.link[], .link_candidates[]] | map(select(test("node_modules|/dist/|tsbuildinfo"))) | length == 0'; then
  ok "node_modules/, dist/ and the multi-MB tsbuildinfo are all out"
else
  bad "build artefacts leaked: $(printf '%s' "$OUT" | jq -c '[.link[], .link_candidates[]]')"
fi
if has "$OUT" '(.link_candidates | index(".DS_Store")) != null'; then
  ok ".DS_Store is reported as a candidate (visible, not linked)"
else
  bad ".DS_Store not reported: $(printf '%s' "$OUT" | jq -c .link_candidates)"
fi

# ===========================================================================
# 5. Config-file behaviour: namespacing, stickiness, idempotence.
# ===========================================================================
echo "-- config: namespaced under .worktree, top-level block untouched --"
R=$(new_repo)
printf '{}\n' > "$R/package.json"
printf 'x\n'  > "$R/pnpm-lock.yaml"
mkdir -p "$R/.claude"
detect "$R" >/dev/null
CFG="$R/.claude/done-config.json"
if jq -e '.worktree.detected.install_cmd == "pnpm install --prefer-offline"' "$CFG" >/dev/null 2>&1; then
  ok "writes worktree.detected into the existing done-config.json"
else
  bad "worktree block not written: $(jq -c '.worktree' "$CFG" 2>/dev/null)"
fi
if jq -e 'has("contract_version") and has("detected") and has("overrides")' "$CFG" >/dev/null 2>&1; then
  ok "the top-level done-config shape is intact (no separate file invented)"
else
  bad "top-level config damaged: $(cat "$CFG")"
fi
if jq -e '.worktree.detected.setup_cmd == null' "$CFG" >/dev/null 2>&1; then
  ok "persisted setup_cmd is null"
else
  bad "persisted setup_cmd is not null"
fi

echo "-- config: overrides survive re-detection (the sticky-field property) --"
TMPC=$(mktemp)
jq '.worktree.overrides = {"install_cmd":"make deps","setup_cmd":"make setup","link":["custom/.env"]}' "$CFG" > "$TMPC" && mv "$TMPC" "$CFG"
# change the source so a refresh is forced
printf 'y\n' > "$R/extra-lock-change.txt"
printf 'extra-lock-change.txt\n' > "$R/.gitignore"
OUT=$(detect "$R")
if jq -e '.worktree.overrides.install_cmd == "make deps" and .worktree.overrides.setup_cmd == "make setup"' "$CFG" >/dev/null 2>&1; then
  ok "overrides survive a forced re-detection"
else
  bad "overrides lost: $(jq -c '.worktree.overrides' "$CFG")"
fi
if has "$OUT" '.install_cmd == "make deps" and .setup_cmd == "make setup" and .link == ["custom/.env"]'; then
  ok "stdout emits the EFFECTIVE config (overrides beat detected)"
else
  bad "effective config wrong: $OUT"
fi
if jq -e '.worktree.detected.install_cmd == "pnpm install --prefer-offline"' "$CFG" >/dev/null 2>&1; then
  ok "detected is still the probed truth, unpolluted by overrides"
else
  bad "detected was overwritten by overrides"
fi

echo "-- config: unchanged source → byte-identical file (idempotent) --"
BEFORE=$(cat "$CFG")
detect "$R" >/dev/null
AFTER=$(cat "$CFG")
if [ "$BEFORE" = "$AFTER" ]; then
  ok "a second run with unchanged source rewrites nothing"
else
  bad "config churned on an unchanged source"
fi

echo "-- config: a new gitignored config file moves the fingerprint --"
FP1=$(jq -r '.worktree.source_fingerprint' "$CFG")
printf '.env\n' >> "$R/.gitignore"
printf 'A=1\n' > "$R/.env"
detect "$R" >/dev/null
FP2=$(jq -r '.worktree.source_fingerprint' "$CFG")
if [ "$FP1" != "$FP2" ] && jq -e '(.worktree.detected.link | index(".env")) != null' "$CFG" >/dev/null 2>&1; then
  ok "a newly-gitignored .env changes the fingerprint and enters detected.link"
else
  bad "fingerprint did not track the link set (fp1=$FP1 fp2=$FP2)"
fi

echo "-- config: seeds a done-config.json when none exists --"
R=$(new_repo)
printf '{}\n' > "$R/package.json"
detect "$R" >/dev/null
if [ -f "$R/.claude/done-config.json" ] \
   && jq -e '.contract_version == 1 and (.worktree.detected | type) == "object"' "$R/.claude/done-config.json" >/dev/null 2>&1; then
  ok "delegates seeding to done-detect.sh, then merges its own block in"
else
  bad "did not seed a valid config"
fi

echo "-- degrades outside a git repo --"
NOGIT=$(mktemp -d); CLEANUP+=("$NOGIT")
mkdir -p "$NOGIT/.claude"
OUT=$(CLAUDE_PROJECT_DIR="$NOGIT" bash "$DETECT" 2>/dev/null); RC=$?
if [ "$RC" -eq 0 ] && has "$OUT" '.link == []'; then
  ok "not a git repo → empty link set, exit 0"
else
  bad "non-git degrade wrong: rc=$RC out=$OUT"
fi

echo
echo "test-worktree-detect: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
