#!/usr/bin/env bash
# Analyze a repo and generate .harness.json. Detects JS/TS, Python, Go, Rust toolchains.
# Run via: loop/loop.sh --init [--repo PATH]
set -euo pipefail
REPO="${REPO:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"; REPO="$(cd "$REPO" && pwd)"; cd "$REPO"
out="$REPO/.harness.json"

tc=""; ln=""; test=""; trel=""; fmt=""; lintfile=""; pc=""; mut=""; pm=""; exts="ts,tsx,js,jsx"; blocked='[]'; stack="unknown"

if [ -f package.json ]; then
  stack="node"
  if   [ -f bun.lockb ] || [ -f bun.lock ]; then pm=bun
  elif [ -f pnpm-lock.yaml ]; then pm=pnpm
  elif [ -f yarn.lock ]; then pm=yarn
  else pm=npm; fi
  case "$pm" in bun) run="bun run"; x="bunx";; npm) run="npm run"; x="npx";; pnpm) run="pnpm run"; x="pnpm exec";; yarn) run="yarn"; x="yarn";; esac
  has(){ jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1; }
  dep(){ jq -e --arg d "$1" '((.dependencies//{})+(.devDependencies//{}))[$d] // empty' package.json >/dev/null 2>&1; }
  if has typecheck; then tc="$run typecheck"; elif [ -f tsconfig.json ]; then tc="$x tsc --noEmit"; fi
  if has lint; then ln="$run lint"
  elif dep @biomejs/biome || [ -f biome.json ]; then ln="$x biome lint ."; lintfile="$x biome lint"
  elif ls .eslintrc* eslint.config.* >/dev/null 2>&1 || dep eslint; then ln="$x eslint ."; lintfile="$x eslint"; fi
  if has format; then fmt="$run format"
  elif dep @biomejs/biome || [ -f biome.json ]; then fmt="$x biome format --write"
  elif dep prettier || ls .prettierrc* prettier.config.* >/dev/null 2>&1; then fmt="$x prettier --write"; fi
  if dep vitest; then test="$x vitest run"; trel="$x vitest related --run"
  elif dep jest; then test="$x jest"
  elif has test; then test="$run test"; fi
  dep @stryker-mutator/core && mut="$x stryker run --incremental"
  dep react && exts="ts,tsx,js,jsx" || exts="ts,js"
  case "$pm" in
    bun)  blocked='["npm ","yarn ","pnpm ","npx "]';;
    npm)  blocked='["bun ","yarn ","pnpm "]';;
    pnpm) blocked='["npm ","yarn ","bun "]';;
    yarn) blocked='["npm ","pnpm ","bun "]';;
  esac
elif [ -f pyproject.toml ] || [ -f requirements.txt ] || ls ./*.py >/dev/null 2>&1; then
  stack="python"; exts="py"
  command -v mypy   >/dev/null 2>&1 && tc="mypy ."
  if   command -v ruff >/dev/null 2>&1; then ln="ruff check ."; fmt="ruff format"; lintfile="ruff check"
  elif command -v flake8 >/dev/null 2>&1; then ln="flake8"; fi
  [ -z "$fmt" ] && command -v black >/dev/null 2>&1 && fmt="black"
  command -v pytest >/dev/null 2>&1 && test="pytest"
elif [ -f go.mod ]; then
  stack="go"; exts="go"; tc="go vet ./..."; test="go test ./..."; fmt="gofmt -w ."
  command -v golangci-lint >/dev/null 2>&1 && ln="golangci-lint run"
elif [ -f Cargo.toml ]; then
  stack="rust"; exts="rs"; tc="cargo check"; ln="cargo clippy -- -D warnings"; test="cargo test"; fmt="cargo fmt"
fi

globs='[]'
for d in src app apps packages lib components services internal pkg cmd; do
  [ -d "$d" ] && globs=$(jq -nc --argjson g "$globs" --arg d "$d" '$g + [$d]')
done
[ "$globs" = "[]" ] && globs='["."]'

[ -e "$out" ] && { cp "$out" "$out.bak"; echo "backed up existing -> $out.bak"; }

jq -n \
  --arg tc "$tc" --arg ln "$ln" --arg test "$test" --arg trel "$trel" --arg fmt "$fmt" \
  --arg lf "$lintfile" --arg pc "$pc" --arg mut "$mut" --arg pm "$pm" --arg exts "$exts" \
  --argjson globs "$globs" --argjson blocked "$blocked" '
  { commands: ({typecheck:$tc, lint:$ln, test:$test, test_related:$trel, format:$fmt, lint_file:$lf, pattern_check:$pc, mutation:$mut}
               | with_entries(select(.value != ""))),
    source_globs: $globs,
    test_file_exts: ($exts|split(",")),
    package_manager: $pm,
    blocked_command_patterns: $blocked }' > "$out"

echo "Detected stack: $stack -> wrote $out"
echo "--------------------------------------------"
jq . "$out"
echo "--------------------------------------------"
echo "Review it. Empty/missing commands mean detection failed — fill them in by hand."
echo "Optional: add a \"code-review\" command to enable an LLM review step (see HARNESS.md)."
