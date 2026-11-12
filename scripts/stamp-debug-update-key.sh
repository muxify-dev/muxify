#!/usr/bin/env bash
# Xcode build phase: a Debug build carries the test EdDSA public key as SUPublicEDKey, because Sparkle's updater
# does not start on an http feed without one. The updater exists only with MUXIFY_UPDATE_FEED_URL, as in a verify
# suite. A Release build gets no key here; packaging stamps the release key into its copy.
set -euo pipefail

[ "${CONFIGURATION:?}" = Debug ] || exit 0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle-debug-public-key.env
source "$ROOT/scripts/sparkle-debug-public-key.env"
[[ "${SPARKLE_DEBUG_PUBLIC_ED_KEY:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  echo "error: scripts/sparkle-debug-public-key.env holds no base64 Ed25519 public key" >&2
  exit 1
}
plutil -replace SUPublicEDKey -string "$SPARKLE_DEBUG_PUBLIC_ED_KEY" "${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
