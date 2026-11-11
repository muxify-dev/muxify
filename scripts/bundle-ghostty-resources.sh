#!/usr/bin/env bash
# Xcode build phase: copies Ghostty's runtime resources (terminfo, themes,
# shell integration) into Muxify.app so libghostty can find them. libghostty
# locates them by looking for Contents/Resources/terminfo/78/xterm-ghostty
# next to the running executable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/vendor/ghostty/resources"
DST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

for resource in terminfo/78/xterm-ghostty ghostty/themes ghostty/shell-integration/zsh/ghostty-integration; do
  [ -e "$SRC/$resource" ] || {
    echo "error: Ghostty resources missing at $SRC; run ./scripts/setup-ghostty.sh" >&2
    exit 1
  }
done

mkdir -p "$DST"
rsync -a --delete "$SRC/terminfo/" "$DST/terminfo/"
rsync -a --delete --exclude doc "$SRC/ghostty/" "$DST/ghostty/"
if [ -f "$ROOT/vendor/ghostty/notices/Ghostty.txt" ]; then
  mkdir -p "$DST/ThirdPartyNotices"
  cp "$ROOT/vendor/ghostty/notices/Ghostty.txt" "$DST/ThirdPartyNotices/Ghostty.txt"
fi
# The Makefile and release script use this same SwiftPM checkout location.
python3 "$ROOT/scripts/collect-notices.py" "$DST/ThirdPartyNotices/Yams.txt" \
  Yams "$ROOT/build/SourcePackages/checkouts/Yams"
# Sparkle's checkout holds its license and those of the code it vendors; the app embeds its framework.
python3 "$ROOT/scripts/collect-notices.py" "$DST/ThirdPartyNotices/Sparkle.txt" \
  Sparkle "$ROOT/build/SourcePackages/checkouts/Sparkle"
