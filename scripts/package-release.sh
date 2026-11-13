#!/usr/bin/env bash
# Packages a Tip Build (`tip`) or a Release (`vX.Y.Z` or `vX.Y.Z-beta.N`) for the updater, locally or in CI.
# It signs with MUXIFY_RELEASE_IDENTITY from MUXIFY_RELEASE_KEYCHAIN and stamps the feed base URL and the
# release public key into the packaged copy only, so a Debug or make install build never updates itself.
# It never installs or launches the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"
FEED_BASE_URL="https://github.com/muxify-dev/muxify/releases/download/appcast/"
if [ "$TAG" = tip ]; then
  KIND=tip
elif [[ "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-beta\.([1-9][0-9]*))?$ ]]; then
  KIND=release
else
  echo "Usage: $0 tip | vMAJOR.MINOR.PATCH | vMAJOR.MINOR.PATCH-beta.N (for example v0.1.0 or v0.1.0-beta.1)" >&2
  exit 1
fi
[ "$(uname -m)" = arm64 ] || { echo "Releases currently require an Apple-silicon Mac." >&2; exit 1; }

IDENTITY_NAME="${MUXIFY_RELEASE_IDENTITY:-}"
KEYCHAIN="${MUXIFY_RELEASE_KEYCHAIN:-}"
[ -n "$IDENTITY_NAME" ] || {
  echo "MUXIFY_RELEASE_IDENTITY is not set: name the signing identity, such as \"Muxify Release Signing\"." >&2
  exit 1
}
[ -n "$KEYCHAIN" ] || {
  echo "MUXIFY_RELEASE_KEYCHAIN is not set: give the keychain that holds \"$IDENTITY_NAME\"." >&2
  exit 1
}
[ -f "$KEYCHAIN" ] || { echo "MUXIFY_RELEASE_KEYCHAIN $KEYCHAIN does not exist." >&2; exit 1; }
# Matches the quoted name exactly, as sign-local.sh does, and signs by hash, so a second
# certificate with a longer name cannot make the choice ambiguous.
IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" |
  awk -v name="\"$IDENTITY_NAME\"" 'index($0, name) { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "$KEYCHAIN holds no \"$IDENTITY_NAME\" signing identity." >&2; exit 1; }

cd "$ROOT"
# A shallow clone counts only the commits it fetched, so its build number would go back in time.
[ "$(git rev-parse --is-shallow-repository)" = false ] || {
  echo "Packaging needs a full-depth checkout: the build number is the commit count of HEAD." >&2
  exit 1
}
BUILD_NUMBER="$(git rev-list --count HEAD)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "The commit count of HEAD is not a build number: $BUILD_NUMBER" >&2; exit 1; }
COMMIT="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short=7 HEAD)"
if [ "$KIND" = tip ]; then
  VERSION="$SHORT_SHA"
  # GitHub lists a release's assets by name, so the zero-padded build number lists Tip Builds in build order.
  ZIP="$(printf 'Muxify-tip-%05d-%s-arm64.zip' "$BUILD_NUMBER" "$SHORT_SHA")"
else
  VERSION="${TAG#v}"
  ZIP="Muxify-$VERSION-arm64.zip"
fi

# shellcheck source=sparkle-public-key.env
source "$ROOT/scripts/sparkle-public-key.env"
if [ -z "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  echo "scripts/sparkle-public-key.env holds no SPARKLE_PUBLIC_ED_KEY: run the release secrets script first." >&2
  exit 1
fi
[[ "$SPARKLE_PUBLIC_ED_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
  echo "SPARKLE_PUBLIC_ED_KEY in scripts/sparkle-public-key.env is not a base64 Ed25519 public key." >&2
  exit 1
}
# shellcheck source=ghostty-version.env
source "$ROOT/scripts/ghostty-version.env"

make project
# A development override or stale cache must not slip into a published build.
python3 - "$GHOSTTY_COMMIT" "$GHOSTTY_ZIG_VERSION" <<'PY'
import json
import sys
from pathlib import Path
expected = {"commit": sys.argv[1], "zig": sys.argv[2], "arch": "arm64", "dirty": False}
actual = json.loads(Path("vendor/ghostty/build-info.json").read_text())
if actual != expected:
    sys.exit("Release requires the pinned Ghostty build; run ./scripts/setup-ghostty.sh without development overrides.")
if not Path("vendor/ghostty/notices/Ghostty.txt").is_file():
    sys.exit("Ghostty dependency notices are missing; rerun ./scripts/setup-ghostty.sh.")
PY

# More settings for xcodebuild, split on spaces and empty unless the caller names some. CI turns on Xcode's
# compilation cache with it.
read -r -a EXTRA_SETTINGS <<< "${XCODEBUILD_EXTRA_SETTINGS:-}"
xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  diagnostic_message_length=0 \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO \
  ${EXTRA_SETTINGS[@]+"${EXTRA_SETTINGS[@]}"} \
  -quiet build

BUILT_APP="$ROOT/build/Build/Products/Release/Muxify.app"
DIST="$ROOT/build/releases/$TAG"
STAGE="$ROOT/build/package"
APP="$STAGE/Muxify.app"
rm -rf "$DIST" "$STAGE"
mkdir -p "$DIST" "$STAGE"

# The stamps go into a copy, so the Release product that make install also builds stays without them.
ditto "$BUILT_APP" "$APP"
plutil -replace MuxifyUpdateFeedBaseURL -string "$FEED_BASE_URL" "$APP/Contents/Info.plist"
plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
# Signing after the stamps seals them. Every build signed with the same certificate keeps one
# designated requirement, so macOS grants and Sparkle's signature check survive updates.
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --preserve-metadata=entitlements "$APP"

# Verify the complete app after resources have been bundled, before archiving.
codesign --verify --deep --strict "$APP"
# Consume all diagnostic output: grep -q can give codesign SIGPIPE under pipefail.
codesign -dvv "$APP" 2>&1 | grep -Fx "Authority=$IDENTITY_NAME" >/dev/null || {
  echo "Muxify.app is not signed by \"$IDENTITY_NAME\"." >&2; exit 1;
}
[ "$(lipo -archs "$APP/Contents/MacOS/MuxifyApp")" = arm64 ]
for notice in Ghostty Yams libyaml Sparkle; do
  [ -s "$APP/Contents/Resources/ThirdPartyNotices/$notice.txt" ] || {
    echo "Missing bundled license notices: $notice" >&2; exit 1;
  }
done

if [ "$KIND" = tip ]; then
  TITLE="Muxify tip build $SHORT_SHA"
else
  TITLE="Muxify $VERSION"
fi
cat > "$DIST/RELEASE-NOTES.md" <<NOTES
# $TITLE

Requires **Apple silicon**, **macOS 14 or later**, and **tmux** (\`brew install tmux\`).
Ghostty is bundled; you do not need to install Ghostty, Zig, or Xcode.

## Install

Muxify updates itself: once installed, it offers each newer build in its header.

1. Download \`$ZIP\` and unzip it.
2. Move \`Muxify.app\` to \`/Applications\` before you open it. A copy opened
   from Downloads cannot update itself.
3. Open Muxify. Until Muxify has a Developer ID, macOS blocks the first
   install: open **System Settings → Privacy & Security → Open Anyway** for
   Muxify, then confirm. Only the first install needs this; updates open
   without it. Only do this for a download you trust.

The **Muxify** menu can install the optional command-line tool and Agent Extensions.
Claude Code and Codex Extensions also need \`jq\`. The Codex installer needs
\`python3\` and \`codex\` on PATH.

## Verify the download

Download \`SHA256SUMS\` alongside the ZIP and run \`shasum -a 256 -c SHA256SUMS\`
in that directory. A checksum checks file integrity; it is not a trusted publisher signature.

Third-party license notices are inside
\`Muxify.app/Contents/Resources/ThirdPartyNotices\`.
NOTES

python3 - "$DIST/build-info.json" "$TAG" "$KIND" "$BUILD_NUMBER" "$VERSION" "$ZIP" "$IDENTITY_NAME" "$COMMIT" "$GHOSTTY_COMMIT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
path, tag, kind, build, version, zip_name, signing, commit, ghostty = sys.argv[1:]
metadata = {
    "tag": tag,
    "kind": kind,
    "build": build,
    "short_version": version,
    "zip": zip_name,
    "commit": commit,
    "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
    "ghostty_commit": ghostty,
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "architecture": "arm64",
    "signing": signing,
    "notarized": False,
}
Path(path).write_text(json.dumps(metadata, indent=2) + "\n")
PY

# ditto preserves the app's symlinks, executable permissions, and signature.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP"
(cd "$DIST" && shasum -a 256 "$ZIP" > SHA256SUMS)
echo "Package: $DIST/$ZIP"
