#!/usr/bin/env bash
# Builds a Release (universal) contextGIST.app and packages it into
# dist/macos/: contextGIST.app, contextGIST.dmg (unsigned; includes install
# instructions) and a copy of INSTALL.txt. Output is gitignored.
#
# For a signed/notarized DMG use tools/release-sign.sh on dist/macos/contextGIST.app.
#
# Usage: tools/package-macos.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$REPO_ROOT/dist/macos"
BUILD="$REPO_ROOT/target/xcode-release"

cd "$REPO_ROOT"
"$SCRIPT_DIR/gen-third-party.sh"
(cd apps/macos && xcodegen generate)
CONFIGURATION=Release "$SCRIPT_DIR/gen-bindings.sh"
xcodebuild -project apps/macos/contextGIST.xcodeproj -scheme contextGIST \
    -configuration Release -derivedDataPath "$BUILD" build

mkdir -p "$OUT"
rm -rf "$OUT/contextGIST.app"
ditto "$BUILD/Build/Products/Release/contextGIST.app" "$OUT/contextGIST.app"
"$SCRIPT_DIR/build-dmg.sh" "$OUT/contextGIST.app" "$OUT/contextGIST.dmg"
cp "$SCRIPT_DIR/dmg/INSTALL.txt" "$OUT/INSTALL.txt"
echo "✓ dist/macos ready:"; ls -lh "$OUT"
