#!/bin/bash
#
# Run the completion-harness test suites.
#
# The suites are self-contained and tracked under completion-harness/tests/. Each
# one sources/execs the REAL bundle scripts (completion-harness/scripts/*), which
# resolve their sibling contracts/ via BASH_SOURCE — so no install step is needed.
# Install shipping itself is verified by completion-harness/tests/test-install.sh,
# which installs into a throwaway dir and asserts the shipped .claude/ layout.
# Each test-*.sh ends with `[ "$FAIL" -eq 0 ]`, so its exit code is meaningful;
# this script exits non-zero if any suite fails. Used directly (`bash
# run-tests.sh`) and by the pre-push hook.

set -u
cd "$(dirname "$0")" || exit 1

fail=0
total=0

# Root-level version suite plus every self-contained completion-harness suite.
for t in test-version.sh completion-harness/tests/test-*.sh; do
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
