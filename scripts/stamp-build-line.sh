#!/usr/bin/env bash
# Xcode build phase: stamps the build line, `muxify <short-sha> <commit-unix-time>` as `muxify --version` prints it,
# into every app's Info.plist as MuxifyBuild, Debug included. The Mac's hello to a Host Server carries it, and
# Diagnostics names it; nothing compares it (docs/adr/0086-the-mac-app-and-the-host-server-agree-on-a-protocol-and-capabilities-never-on-a-build.md).
# A Debug build also carries its source root as MuxifySourceRoot: on connect it serves a Host from its own
# build/host-cli/ there when that build's version names the same sha (ADR 0086, "Which binary serves").
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sha=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null) || sha=dev
time=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null) || time=0
plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
plutil -replace MuxifyBuild -string "muxify $sha $time" "$plist"
if [ "${CONFIGURATION:-}" = Debug ]; then
  plutil -replace MuxifySourceRoot -string "$ROOT" "$plist"
else
  plutil -remove MuxifySourceRoot "$plist" 2>/dev/null || :
fi
