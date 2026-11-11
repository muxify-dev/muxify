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
# mirrors that apt needs.
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

docker run --rm ${options[@]+"${options[@]}"} \
  -v "$ROOT:/src" -v "$CACHE_VOLUME:/cache" -w /src \
  -e TMUX_VERSION="$TMUX_VERSION" -e TMUX_SHA256="$TMUX_SHA256" \
  -e OWNER_UID="$(id -u)" -e OWNER_GID="$(id -g)" \
  "$HOST_CLI_SWIFT_IMAGE" bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends git ca-certificates curl make bison pkg-config \
      libevent-dev libncurses-dev >/dev/null

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

    runuser -u tester -- env HOME=/cache/home MUXIFY_REQUIRE_TMUX=1 bash -uo pipefail -c "
      build=/cache/build/\$(uname -m)
      status=0
      swift test --package-path Packages/MuxifyCore --scratch-path \$build/core || status=1
      swift test --scratch-path \$build/cli || status=1
      exit \$status
    "
  '
