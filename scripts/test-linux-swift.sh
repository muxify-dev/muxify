#!/usr/bin/env bash
# Runs swift test for Packages/MuxifyCore and for the root package (the muxify CLI), in make test-linux's container as
# its test user (scripts/test-linux.sh), with each package's build folder under /cache/build.
#
# STRESS=1 is the stress mode (docs/testing.md): STRESS_ITERATIONS (default 5) runs of the packages that stop at the
# first failure, with no retries. STRESS_FILTER passes swift test's --filter, and STRESS_PACKAGE (core, cli or both,
# the default) chooses the packages. scripts/test-linux.sh sets the time scale 3 and runs it under the CPU hog.
#
# MUXIFY_TEST_RETRIES (unset or 0: none; CI sets 2) runs each package through scripts/swift-test-retries.py, which
# reruns, that many times at most, only the classes that failed, or the whole package after a crash or a timeout. It
# keeps each attempt's output and its record in build/test-linux, for scripts/report-flaky-tests.py --linux. A stress
# run never retries. "test-linux-swift.sh attempt <package> [swift test options]" runs one swift test call, the
# wrapper's attempt.
set -uo pipefail

build="/cache/build/$(uname -m)"
filter=()
[ -n "${STRESS_FILTER:-}" ] && filter=(--filter "$STRESS_FILTER")

# Each swift test call runs under timeout, 20 minutes unless SWIFT_TEST_TIMEOUT names other seconds, so a hung test
# fails its package instead of using up the CI job. A timeout fails that package and names it; the next one still runs.
# timeout signals the whole process group, the test process too, and kills it a minute after a TERM it ignores.
time_limit="${SWIFT_TEST_TIMEOUT:-1200}"

swift_test() {
  local package="$1" status=0
  shift
  local start=$SECONDS
  case "$package" in
    core) timeout --kill-after=1m "${time_limit}s" \
      swift test --package-path Packages/MuxifyCore --scratch-path "$build/core" ${filter[@]+"${filter[@]}"} "$@" \
      || status=$? ;;
    cli) timeout --kill-after=1m "${time_limit}s" \
      swift test --scratch-path "$build/cli" ${filter[@]+"${filter[@]}"} "$@" || status=$? ;;
  esac
  # 124 is timeout's own status; 137 is the KILL that follows a TERM the test ignored.
  if [ "$status" -eq 124 ] || { [ "$status" -eq 137 ] && [ $((SECONDS - start)) -ge "$time_limit" ]; }; then
    echo "make test-linux: swift test for $package timed out after $time_limit s" >&2
  fi
  return "$status"
}

if [ "${1:-}" = attempt ]; then
  shift
  swift_test "$@"
  exit
fi

if [ -z "${STRESS:-}" ]; then
  retries="${MUXIFY_TEST_RETRIES:-0}"
  case "$retries" in
    '' | *[!0-9]*) echo "MUXIFY_TEST_RETRIES is a number of retries, not $retries" >&2; exit 2 ;;
  esac
  record=build/test-linux
  rm -rf "$record"
  status=0
  for package in core cli; do
    if [ "$retries" -gt 0 ]; then
      python3 scripts/swift-test-retries.py --name "$package" --retries "$retries" --record "$record" \
        -- "$0" attempt "$package" || status=1
    else
      swift_test "$package" || status=1
    fi
  done
  exit $status
fi

case "${STRESS_PACKAGE:-both}" in
  core) packages=(core) ;;
  cli) packages=(cli) ;;
  both) packages=(core cli) ;;
  *) echo "STRESS_PACKAGE is core, cli or both, not $STRESS_PACKAGE" >&2; exit 2 ;;
esac
iterations="${STRESS_ITERATIONS:-5}"
for ((iteration = 1; iteration <= iterations; iteration++)); do
  for package in "${packages[@]}"; do
    echo "==> stress iteration $iteration of $iterations: $package"
    swift_test "$package" || { echo "make test-linux: $package failed in stress iteration $iteration of $iterations" >&2; exit 1; }
  done
done
echo "==> $iterations stress iterations passed"
