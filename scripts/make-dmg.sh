#!/bin/bash
# Builds a release DMG at build/DBJoy-<version>.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

DBJOY_RELEASE=1 scripts/build-app.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/DBJoy.app/Contents/Info.plist)"
DMG="build/DBJoy-$VERSION.dmg"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R build/DBJoy.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "DBJoy $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

IDENTITY="${DBJOY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

# Notarize with a notarytool keychain profile (default "dondo"; set DBJOY_NOTARY_PROFILE= to skip).
# Create one with: xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team> --password <app-specific>
NOTARY_PROFILE="${DBJOY_NOTARY_PROFILE-dondo}"
if [ -n "$NOTARY_PROFILE" ]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "Created $DMG"
