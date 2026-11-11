#!/usr/bin/env bash
# Vendors the pinned Sparkle 2 tools into vendor/sparkle/<version>: the release archive's bin/sign_update,
# bin/generate_keys and Sparkle.framework, and sparkle.app, Sparkle's command-line updater, built from the
# release's source. Prints that directory. A second run only checks it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=sparkle-version.env
source "$ROOT/scripts/sparkle-version.env"
OUT="$ROOT/vendor/sparkle/$SPARKLE_VERSION"
STAMP="$OUT/.complete"

if [ "$(cat "$STAMP" 2>/dev/null)" != "$SPARKLE_SHA256 $SPARKLE_COMMIT" ]; then
  rm -rf "$OUT"
  mkdir -p "$OUT"
  archive="$(mktemp "$ROOT/vendor/sparkle/archive.XXXXXX")"
  trap 'rm -f "$archive"' EXIT
  curl --fail --silent --show-error --location --retry 3 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$archive" >&2
  printf '%s  %s\n' "$SPARKLE_SHA256" "$archive" | shasum -a 256 -c - >&2
  tar -xJf "$archive" -C "$OUT"

  SRC="$ROOT/vendor/sparkle-src/$SPARKLE_COMMIT"
  if [ ! -d "$SRC" ]; then
    mkdir -p "$(dirname "$SRC")"
    git init --quiet "$SRC"
    git -C "$SRC" remote add origin https://github.com/sparkle-project/Sparkle.git
    git -C "$SRC" fetch --quiet --depth=1 origin "$SPARKLE_COMMIT"
    git -C "$SRC" checkout --quiet --detach FETCH_HEAD
  fi
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$SPARKLE_COMMIT" ] || {
    echo "Pinned Sparkle checkout has an unexpected revision: $SRC" >&2; exit 1;
  }
  git -C "$SRC" diff --quiet HEAD -- || {
    echo "Pinned Sparkle checkout has local changes; refusing to build it." >&2; exit 1;
  }
  xcodebuild -project "$SRC/Sparkle.xcodeproj" -scheme sparkle-cli -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath "$SRC/build" -clonedSourcePackagesDirPath "$SRC/build/SourcePackages" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet build >&2
  cp -R "$SRC/build/Build/Products/Release/sparkle.app" "$OUT/sparkle.app"
  echo "$SPARKLE_SHA256 $SPARKLE_COMMIT" > "$STAMP"
fi

for tool in bin/sign_update bin/generate_keys sparkle.app/Contents/MacOS/sparkle; do
  [ -x "$OUT/$tool" ] || { echo "Missing Sparkle tool: $OUT/$tool" >&2; exit 1; }
done
echo "$OUT"
