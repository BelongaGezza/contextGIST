#!/usr/bin/env bash
# Signs a Release contextGIST.app with Hardened Runtime, packages it as a
# DMG, and (when Apple credentials are present) notarizes and staples it.
# docs/SECURITY_REVIEW.md finding #3; docs/DEVELOPMENT_PLAN.md Phase 0.
#
# Usage: tools/release-sign.sh <path/to/contextGIST.app> <out.dmg>
#
# Environment:
#   SIGN_IDENTITY   codesign identity. A real release needs
#                   "Developer ID Application: <Name> (<TEAMID>)"; the
#                   default "-" signs ad-hoc, which exercises every step
#                   except notarization (for testing this script).
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
#                   notarytool credentials. If any is unset, notarization
#                   and stapling are skipped with a warning.
#
# Status: the ad-hoc path is tested (2026-09-30). The Developer ID +
# notarization path has NOT been run yet: no Developer ID identity exists
# on the dev machine. Treat the first real run as the test.
#
# Adapted from GIST's tools/notarize.sh and release-macos.yml
# (reader b20908d), which this repo can't use directly (no CI or remote).
set -euo pipefail

APP_PATH="${1:?Usage: release-sign.sh <path/to/contextGIST.app> <out.dmg>}"
DMG_PATH="${2:?Usage: release-sign.sh <path/to/contextGIST.app> <out.dmg>}"
IDENTITY="${SIGN_IDENTITY:--}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/apps/macos/contextGIST.entitlements"

# A release must be universal: gen-bindings.sh + project.yml make Release
# builds arm64 + x86_64, so anything else means a Debug or stale build.
ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/contextGIST")"
for arch in arm64 x86_64; do
    if [[ " $ARCHS " != *" $arch "* ]]; then
        echo "error: $APP_PATH is missing the $arch slice (has: $ARCHS). Build with -configuration Release." >&2
        exit 1
    fi
done

# Don't ship on top of upstream GIST changes nobody has reviewed: they're
# compiled in (shared crates) or may need porting (see
# tools/upstream-review.sh). ALLOW_UNREVIEWED_UPSTREAM=1 overrides, loudly.
if ! "$SCRIPT_DIR/upstream-review.sh" --check --strict; then
    if [ "${ALLOW_UNREVIEWED_UPSTREAM:-0}" = 1 ]; then
        echo "warning: releasing with unreviewed upstream changes (ALLOW_UNREVIEWED_UPSTREAM=1)" >&2
    else
        echo "error: review upstream first (tools/upstream-review.sh), or set ALLOW_UNREVIEWED_UPSTREAM=1" >&2
        exit 1
    fi
fi

if [ "$IDENTITY" = "-" ]; then
    echo "warning: SIGN_IDENTITY not set — signing ad-hoc. The result will NOT pass Gatekeeper on other Macs." >&2
    TIMESTAMP="--timestamp=none"
else
    # Notarization requires a secure timestamp.
    TIMESTAMP="--timestamp"
fi

echo "→ Signing $APP_PATH (identity: $IDENTITY, Hardened Runtime)..."
# The app has no nested frameworks or helpers (the Rust core is a
# staticlib linked into the main binary), so signing the bundle itself is
# enough. No --deep: it's deprecated for signing and would hide a nested
# code problem if one were ever added.
codesign --force --options runtime $TIMESTAMP \
    --entitlements "$ENTITLEMENTS" \
    --sign "$IDENTITY" \
    "$APP_PATH"

echo "→ Verifying signature..."
codesign --verify --strict --verbose=2 "$APP_PATH"
FLAGS="$(codesign -dv "$APP_PATH" 2>&1 | grep -o 'flags=[^ ]*')"
if [[ "$FLAGS" != *runtime* ]]; then
    echo "error: Hardened Runtime is not set on the signed app ($FLAGS)" >&2
    exit 1
fi
if ! codesign -d --entitlements - "$APP_PATH" 2>/dev/null | grep -q 'com.apple.security.app-sandbox'; then
    echo "error: App Sandbox entitlement missing from the signed app" >&2
    exit 1
fi
echo "   $FLAGS, App Sandbox entitlement present"

"$SCRIPT_DIR/build-dmg.sh" "$APP_PATH" "$DMG_PATH"

echo "→ Signing $DMG_PATH..."
codesign --force $TIMESTAMP --sign "$IDENTITY" "$DMG_PATH"

if [ "$IDENTITY" = "-" ] || [ -z "${APPLE_ID:-}" ] || [ -z "${APPLE_TEAM_ID:-}" ] || [ -z "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]; then
    echo "warning: skipping notarization (needs a Developer ID identity plus APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD)." >&2
    echo "✓ Signed (not notarized): $DMG_PATH"
    exit 0
fi

echo "→ Submitting for notarization (can take several minutes)..."
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait \
    --timeout 30m

echo "→ Stapling..."
xcrun stapler staple "$DMG_PATH"

echo "→ Gatekeeper assessment..."
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

echo "✓ Signed, notarized and stapled: $DMG_PATH"
