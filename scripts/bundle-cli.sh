#!/bin/sh
set -eu
source="$BUILT_PRODUCTS_DIR/muxify-app-cli"
if [ "$CONFIGURATION" = Release ]; then
    scratch="$PROJECT_DIR/build/universal-cli"
    swift build --package-path "$PROJECT_DIR" --scratch-path "$scratch" -c release --arch arm64 --arch x86_64 --product muxify
    products=$(swift build --package-path "$PROJECT_DIR" --scratch-path "$scratch" -c release --arch arm64 --arch x86_64 --show-bin-path)
    source="$products/muxify"
    lipo "$source" -verify_arch arm64 x86_64
fi
destination="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin"
mkdir -p "$destination"
# Replace the inode so macOS cannot reuse a cached signature for an older build.
cp "$source" "$destination/muxify.new"
codesign --force --sign - "$destination/muxify.new"
mv -f "$destination/muxify.new" "$destination/muxify"
