#!/usr/bin/env bash
# Runs swift test for Packages/MuxifyCore and for the root package (the muxify CLI), in make test-linux's container as
# its test user (scripts/test-linux.sh), with each package's build folder under /cache/build.
#
# STRESS=1 is the stress mode (docs/testing.md): STRESS_ITERATIONS (default 5) runs of the packages that stop at the
# first failure, with no retries. STRESS_FILTER passes swift test's --filter, and STRESS_PACKAGE (core, cli or both,
# the default) chooses the packages. scripts/test-linux.sh sets the time scale 3 and runs it under the CPU hog.
set -uo pipefail

build="/cache/build/$(uname -m)"
filter=()
[ -n "${STRESS_FILTER:-}" ] && filter=(--filter "$STRESS_FILTER")

swift_test() {
  case "$1" in
    core) swift test --package-path Packages/MuxifyCore --scratch-path "$build/core" ${filter[@]+"${filter[@]}"} ;;
    cli) swift test --scratch-path "$build/cli" ${filter[@]+"${filter[@]}"} ;;
  esac
}

if [ -z "${STRESS:-}" ]; then
  status=0
  swift_test core || status=1
  swift_test cli || status=1
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
