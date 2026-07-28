#!/bin/bash
#
# Run the completion-harness test suites.
#
# The suites live in the disposable `harness-trial/` fixture and exercise the
# INSTALLED copies of the scripts, so this runner first mirrors the current
# bundle into the fixture, then runs every suite. Each test-*.sh ends with
# `[ "$FAIL" -eq 0 ]`, so its exit code is meaningful; this script exits non-zero
# if any suite fails. Used directly (`bash run-tests.sh`) and by the pre-push hook.

set -u
cd "$(dirname "$0")" || exit 1

if ! bash completion-harness/install.sh harness-trial >/dev/null 2>&1; then
  echo "run-tests: install.sh into harness-trial FAILED" >&2
  exit 1
fi

fail=0
total=0

# Root-level suites (no fixture needed) plus the fixture suites.
for t in test-version.sh harness-trial/test-*.sh; do
  [ -f "$t" ] || continue
  total=$((total + 1))
  if bash "$t" >/dev/null 2>&1; then
    echo "PASS  $(basename "$t")"
  else
    echo "FAIL  $(basename "$t")"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo "run-tests: all $total suites passed"
else
  echo "run-tests: one or more suites FAILED" >&2
fi
exit $fail
