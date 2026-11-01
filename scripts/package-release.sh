#!/usr/bin/env bash
# Builds and packages a beta locally or in CI; never installs or launches it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
if [[ ! "$TAG" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-beta\.([1-9][0-9]*)$ ]]; then
  echo "Usage: $0 vMAJOR.MINOR.PATCH-beta.N (for example v0.1.0-beta.1)" >&2
  exit 1
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi
[ "$(uname -m)" = arm64 ] || { echo "Beta releases currently require an Apple-silicon Mac." >&2; exit 1; }
VERSION="${TAG#v}"
MARKETING_VERSION="${VERSION%-beta.*}"
# shellcheck source=ghostty-version.env
source "$ROOT/scripts/ghostty-version.env"

cd "$ROOT"
make project
# A development override or stale cache must not slip into a published beta.
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

xcodebuild -project Muxify.xcodeproj -scheme Muxify -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath build -clonedSourcePackagesDirPath build/SourcePackages \
  MARKETING_VERSION="$MARKETING_VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO \
  -quiet build

APP="$ROOT/build/Build/Products/Release/Muxify.app"
DIST="$ROOT/build/releases/$TAG"
ZIP="Muxify-$VERSION-arm64.zip"
mkdir -p "$DIST"

# Verify the complete app after resources have been bundled, before archiving.
codesign --verify --deep --strict "$APP"
# Consume all diagnostic output: grep -q can give codesign SIGPIPE under pipefail.
codesign -dv "$APP" 2>&1 | grep '^Signature=adhoc$' >/dev/null
[ "$(lipo -archs "$APP/Contents/MacOS/MuxifyApp")" = arm64 ]
for notice in Ghostty Yams libyaml; do
  [ -s "$APP/Contents/Resources/ThirdPartyNotices/$notice.txt" ] || {
    echo "Missing bundled license notices: $notice" >&2; exit 1;
  }
done

cat > "$DIST/RELEASE-NOTES.md" <<NOTES
# Muxify $VERSION — ad-hoc-signed beta

Requires **Apple silicon**, **macOS 14 or later**, and **tmux** (\`brew install tmux\`).
Ghostty is bundled; you do not need to install Ghostty, Zig, or Xcode.

## Install

1. Download \`$ZIP\`, unzip it, and move \`Muxify.app\` to \`/Applications\`.
2. Try opening Muxify. This beta is **not Developer ID signed or notarized**,
   so macOS may block it.
3. If blocked, open **System Settings → Privacy & Security → Open Anyway**
   for Muxify, then confirm. Only do this for a download you trust.

The **Muxify** menu can install the optional command-line tool and Agent Extensions.
Claude Code and Codex Extensions also need \`jq\`. The Codex installer needs
\`python3\` and \`codex\` on PATH.

## Verify the download

Download \`SHA256SUMS\` alongside the ZIP and run \`shasum -a 256 -c SHA256SUMS\`
in that directory. A checksum checks file integrity; it is not a trusted publisher signature.

Third-party license notices are inside
\`Muxify.app/Contents/Resources/ThirdPartyNotices\`.
NOTES

python3 - "$TAG" "$BUILD_NUMBER" "$GHOSTTY_COMMIT" <<'PY'
import json
import subprocess
import sys
from pathlib import Path
tag, build, ghostty = sys.argv[1:]
metadata = {
    "tag": tag,
    "build": build,
    "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "source_dirty": bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()),
    "ghostty_commit": ghostty,
    "xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "architecture": "arm64",
    "signing": "ad-hoc",
    "notarized": False,
}
Path("build/releases", tag, "build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY

# ditto preserves the app's symlinks, executable permissions, and signature.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/$ZIP"
(cd "$DIST" && shasum -a 256 "$ZIP" > SHA256SUMS)
echo "Beta package: $DIST/$ZIP"
