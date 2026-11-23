#!/usr/bin/env bash
# Runs swift test for the root package (the muxify CLI) and for Packages/MuxifyCore
# on Linux, in Docker with the Swift image that builds the Host CLI
# (scripts/host-cli-version.env), with tmux and git installed and
# MUXIFY_REQUIRE_TMUX=1. It runs on the Mac through OrbStack's Docker and
# unchanged on a Linux CI runner.
#
# The tests run as the caller's uid, not root: root may write a read-only folder,
# and the tests of a refused write would pass for the wrong reason.
# tmux is the release that Homebrew gives the Mac, built from source, because
# Ubuntu's tmux 3.4 does not report search_count. The package cache, the build
# folders and the built tmux stay in a Docker volume, apart from the Mac's .build,
# so a second run only rebuilds what changed.
#
# It uses the host's architecture; TEST_LINUX_PLATFORM=linux/amd64 (or
# linux/arm64) picks another. TEST_LINUX_DOCKER_ARGS adds options to docker run,
# such as --dns 1.1.1.1 when the host's resolver does not answer for the Ubuntu
# mirrors that apt needs. MUXIFY_TEST_TIME_SCALE, which stretches the tests'
# waits (docs/testing.md), reaches the tests as it is set here.
#
# STRESS=1 is the stress mode (docs/testing.md): the time scale 3, a CPU hog on
# every core of the container (scripts/with-cpu-hog.sh), and STRESS_ITERATIONS
# (default 5) runs of swift test that stop at the first failure, with no retries.
# STRESS_FILTER passes swift test's --filter; STRESS_PACKAGE (core, cli or both,
# the default) chooses MuxifyCore, the CLI or both. scripts/test-linux-swift.sh
# runs the swift test calls.
#
# MUXIFY_TEST_RETRIES (unset or 0: none; CI sets 2) retries the classes that failed, as scripts/test-linux-swift.sh
# says, and then scripts/report-flaky-tests.py names each test that failed and then passed as FLAKY. A stress run
# never retries.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host-cli-version.env
source "$ROOT/scripts/host-cli-version.env"
CACHE_VOLUME="${TEST_LINUX_CACHE_VOLUME:-muxify-test-linux-cache}"
TMUX_VERSION=3.8
TMUX_SHA256=e79c699c7e949dccd0a4a125e17b8d1261e311b16979dbc8eb34542f3966d82e

command -v docker >/dev/null || { echo "make test-linux needs Docker (OrbStack on a Mac)" >&2; exit 1; }

options=()
if [ -n "${TEST_LINUX_PLATFORM:-}" ]; then
  options+=(--platform "$TEST_LINUX_PLATFORM")
fi
# shellcheck disable=SC2206 # the extra options split on spaces
options+=(${TEST_LINUX_DOCKER_ARGS:-})

stress="${STRESS:-}"
time_scale="${MUXIFY_TEST_TIME_SCALE:-}"
retries="${MUXIFY_TEST_RETRIES:-0}"
if [ -n "$stress" ]; then
  time_scale=3
  retries=0
fi

# The docker client neither stops nor stops its container on a signal, so docker runs in the background, and an
# interrupted run removes the container, the CPU hog of a stress run with it.
container="muxify-test-linux-$$"
cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker run --rm --name "$container" ${options[@]+"${options[@]}"} \
  -v "$ROOT:/src" -v "$CACHE_VOLUME:/cache" -w /src \
  -e TMUX_VERSION="$TMUX_VERSION" -e TMUX_SHA256="$TMUX_SHA256" \
  -e OWNER_UID="$(id -u)" -e OWNER_GID="$(id -g)" \
  -e MUXIFY_TEST_TIME_SCALE="$time_scale" -e MUXIFY_TEST_RETRIES="$retries" -e STRESS="$stress" -e STRESS_ITERATIONS="${STRESS_ITERATIONS:-5}" \
  -e STRESS_FILTER="${STRESS_FILTER:-}" -e STRESS_PACKAGE="${STRESS_PACKAGE:-both}" \
  "$HOST_CLI_SWIFT_IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends git ca-certificates curl make bison pkg-config \
      libevent-dev libncurses-dev python3 >/dev/null

    tmux_dir="/cache/tmux-$TMUX_VERSION-$(uname -m)"
    if [ ! -x "$tmux_dir/bin/tmux" ]; then
      work="$(mktemp -d)"
      curl -fsSL -o "$work/tmux.tar.gz" "https://github.com/tmux/tmux/releases/download/$TMUX_VERSION/tmux-$TMUX_VERSION.tar.gz"
      echo "$TMUX_SHA256  $work/tmux.tar.gz" | sha256sum -c --quiet
      tar -xzf "$work/tmux.tar.gz" -C "$work"
      (cd "$work/tmux-$TMUX_VERSION" && CC=clang ./configure --prefix="$tmux_dir" >/dev/null && make -s -j"$(nproc)" install >/dev/null)
      rm -rf "$work"
    fi
    install -m 0755 "$tmux_dir/bin/tmux" /usr/local/bin/tmux

    groupadd -o -g "$OWNER_GID" tester
    useradd -o -u "$OWNER_UID" -g "$OWNER_GID" -M -d /cache/home tester
    mkdir -p /cache/home /cache/build
    chown "$OWNER_UID:$OWNER_GID" /cache/home /cache/build

    hog=()
    if [ -n "$STRESS" ]; then
      hog=(scripts/with-cpu-hog.sh)
    fi
    runuser -u tester -- env HOME=/cache/home MUXIFY_REQUIRE_TMUX=1 MUXIFY_TEST_TIME_SCALE="$MUXIFY_TEST_TIME_SCALE" \
      MUXIFY_TEST_RETRIES="$MUXIFY_TEST_RETRIES" STRESS="$STRESS" STRESS_ITERATIONS="$STRESS_ITERATIONS" STRESS_FILTER="$STRESS_FILTER" STRESS_PACKAGE="$STRESS_PACKAGE" \
      ${hog[@]+"${hog[@]}"} scripts/test-linux-swift.sh
  ' &
status=0
wait $! || status=$?
if [ "$retries" != 0 ]; then
  "$ROOT/scripts/report-flaky-tests.py" --linux "$ROOT/build/test-linux"
fi
exit "$status"
