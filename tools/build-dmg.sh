#!/usr/bin/env bash
# Packages a built contextGIST.app into a distributable .dmg.
#
# Adapted from GIST's tools/build-dmg.sh (reader commit b20908d). Like that
# script, it deliberately does NOT sign or notarise anything — it only
# arranges files on disk and calls `hdiutil create`, so it works against an
# ad-hoc/unsigned build with no Developer ID identity present (contextGIST
# has none yet — see docs/DEVELOPMENT_PLAN.md). Signing/notarisation, when it
# exists, must happen to the .app *before* this script runs.
#
# Unlike GIST's version, it also copies the app's bundled
# ThirdPartyNotices.txt to the DMG root, so the licence notices are visible
# without opening the bundle (contextGIST has no About/Settings screen to
# show them from — see docs/THIRD-PARTY.md).
#
# Release builds are universal (arm64 + x86_64). A Debug .app is host-arch
# only, so package Release builds. For a signed build, use
# tools/release-sign.sh, which signs first and then calls this script.
#
# Usage: tools/build-dmg.sh <path-to.app> <output.dmg>
set -euo pipefail

APP_PATH="${1:?Usage: build-dmg.sh <path-to.app> <output.dmg>}"
DMG_PATH="${2:?Usage: build-dmg.sh <path-to.app> <output.dmg>}"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: '$APP_PATH' does not exist or is not a directory (expected a .app bundle)" >&2
    exit 1
fi

if [[ "$APP_PATH" != *.app ]]; then
    echo "ERROR: '$APP_PATH' does not look like a .app bundle (must end in .app)" >&2
    exit 1
fi

NOTICES="$APP_PATH/Contents/Resources/ThirdPartyNotices.txt"
if [ ! -f "$NOTICES" ]; then
    echo "ERROR: $NOTICES is missing — rebuild after 'xcodegen generate' so the Resources phase picks it up" >&2
    exit 1
fi

VOLUME_NAME="$(basename "$APP_PATH" .app)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/contextgist-dmg-staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

echo "→ Staging DMG contents in $STAGING_DIR..."
# ditto (not cp -R) preserves the .app bundle's extended attributes/resource
# forks/symlinks exactly, which matters for a Mach-O bundle.
ditto "$APP_PATH" "$STAGING_DIR/$(basename "$APP_PATH")"

# Standard "drag to Applications" affordance.
ln -s /Applications "$STAGING_DIR/Applications"

cp "$NOTICES" "$STAGING_DIR/Third-Party Notices.txt"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

echo "→ Creating $DMG_PATH..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG_PATH"

echo "✓ DMG written to $DMG_PATH"
