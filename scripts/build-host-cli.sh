#!/usr/bin/env bash
# Builds the muxify CLI as static (musl) Linux binaries for aarch64 and x86_64,
# in Docker with the Swift Static Linux SDK: build/host-cli/muxify-linux-<arch>.
# One container cross-compiles both architectures. The SDK, the package cache
# and the Linux build folder stay in a Docker volume, apart from the Mac's .build,
# so a second run only rebuilds what changed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=host-cli-version.env
source "$ROOT/scripts/host-cli-version.env"
CACHE_VOLUME="${HOST_CLI_CACHE_VOLUME:-muxify-host-cli-cache}"
OUT=build/host-cli

command -v docker >/dev/null || { echo "make host-cli needs Docker (OrbStack on a Mac)" >&2; exit 1; }
mkdir -p "$ROOT/$OUT"

docker run --rm \
  -v "$ROOT:/src" -v "$CACHE_VOLUME:/cache" -w /src \
  -e HOME=/cache/home \
  -e SDK_URL="$HOST_CLI_SDK_URL" -e SDK_SHA256="$HOST_CLI_SDK_SHA256" \
  -e OUT="$OUT" -e OWNER="$(id -u):$(id -g)" \
  "$HOST_CLI_SWIFT_IMAGE" bash -euo pipefail -c '
    sdks=/cache/swift-sdks
    mkdir -p "$HOME" "$sdks"
    if ! swift sdk list --swift-sdks-path "$sdks" 2>/dev/null | grep -q static-linux; then
      swift sdk install "$SDK_URL" --checksum "$SDK_SHA256" --swift-sdks-path "$sdks"
    fi
    for arch in aarch64 x86_64; do
      scratch="/cache/build/$arch"
      swift build -c release --product muxify --swift-sdks-path "$sdks" \
        --swift-sdk "$arch-swift-linux-musl" --scratch-path "$scratch" \
        -Xlinker -s
      install -m 0755 "$scratch/release/muxify" "$OUT/muxify-linux-$arch"
      chown "$OWNER" "$OUT/muxify-linux-$arch"
    done
  '
ls -l "$ROOT/$OUT"/muxify-linux-*
