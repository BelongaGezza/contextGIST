#!/usr/bin/env bash
# Regenerates contextGIST's app icon (apps/macos/AppIcon.icon) from GIST's
# macOS icon artwork.
#
#   apps/macos/IconSource/gist-macos-app-icon.png   source (committed copy)
#   → tools/gen-app-icon.swift                      full-bleed 1024 layer
#   → apps/macos/AppIcon.icon                       Icon Composer icon
#
# AppIcon.icon covers every supported macOS: macOS 26+ renders it with the
# system mask, and Xcode also generates the flat AppIcon.icns that macOS
# 13–15 use from it. A separate asset-catalog AppIcon would be ignored
# (verified 2026-09-30: actool output is byte-identical with or without
# one), so there isn't one.
#
# The source is GIST's assets/a-macos-app-icon.png (same author), kept as a
# committed copy here so the icon builds offline. To pick up a new version of
# the artwork, run with --refresh-source, which downloads it from GIST's
# main branch on GitHub first. See docs/ARCHITECTURE.md "App icon".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE="$REPO_ROOT/apps/macos/IconSource/gist-macos-app-icon.png"
UPSTREAM="https://raw.githubusercontent.com/BelongaGezza/gist/main/assets/a-macos-app-icon.png"
ICON_BUNDLE="$REPO_ROOT/apps/macos/AppIcon.icon"

if [ "${1:-}" = "--refresh-source" ]; then
    mkdir -p "$(dirname "$SOURCE")"
    curl -fsSL "$UPSTREAM" -o "$SOURCE.tmp" || { rm -f "$SOURCE.tmp"; echo "error: could not download $UPSTREAM" >&2; exit 1; }
    mv "$SOURCE.tmp" "$SOURCE"
    echo "→ Downloaded source from $UPSTREAM"
fi
[ -f "$SOURCE" ] || { echo "error: $SOURCE missing (run with --refresh-source)" >&2; exit 1; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/contextgist-icon.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
FULLBLEED="$TMP_DIR/artwork.png"

echo "→ Building full-bleed artwork..."
swift "$SCRIPT_DIR/gen-app-icon.swift" "$SOURCE" "$FULLBLEED" | tee "$TMP_DIR/log.txt"
BODY_RGB="$(sed -n 's/^body colour: //p' "$TMP_DIR/log.txt")"

echo "→ Writing $ICON_BUNDLE..."
rm -rf "$ICON_BUNDLE"
mkdir -p "$ICON_BUNDLE/Assets"
cp "$FULLBLEED" "$ICON_BUNDLE/Assets/artwork.png"
# One opaque full-bleed layer on a solid fill of the same body colour, so
# the corners show body colour whatever the system mask does.
read -r R G B <<<"$BODY_RGB"
FILL="$(awk -v r="$R" -v g="$G" -v b="$B" 'BEGIN { printf "srgb:%.5f,%.5f,%.5f,1.00000", r/255, g/255, b/255 }')"
cat > "$ICON_BUNDLE/icon.json" <<JSON
{
  "fill" : {
    "solid" : "$FILL"
  },
  "groups" : [
    {
      "layers" : [
        {
          "image-name" : "artwork.png",
          "name" : "artwork"
        }
      ]
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}
JSON

echo "✓ Wrote $ICON_BUNDLE"
