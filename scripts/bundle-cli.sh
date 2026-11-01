#!/bin/sh
set -eu
# MuxifyCLITool built the CLI into the same products folder as the app.
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin"
mkdir -p "$destination"
# Replace the inode so macOS cannot reuse a cached signature for an older build.
cp "$BUILT_PRODUCTS_DIR/muxify-app-cli" "$destination/muxify.new"
codesign --force --sign - "$destination/muxify.new"
mv -f "$destination/muxify.new" "$destination/muxify"
