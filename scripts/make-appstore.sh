#!/bin/bash
# Builds the Mac App Store package at build/DBJoy-<version>.pkg, ready to upload with Transporter.
#
# One-time setup (see appstore/README.md):
#   - "Apple Distribution" and "Mac Installer Distribution" certificates in the login keychain
#   - a Mac App Store provisioning profile for app.dbjoy.DBJoy, saved as
#     appstore/DBJoy_Mac_App_Store.provisionprofile (or set DBJOY_PROVISIONING_PROFILE)
#
# Every upload needs a higher CFBundleVersion (scripts/build-app.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM_ID="${DBJOY_TEAM_ID:-4637X2WX3Q}"
BUNDLE_ID="app.dbjoy.DBJoy"
PROFILE="${DBJOY_PROVISIONING_PROFILE:-appstore/DBJoy_Mac_App_Store.provisionprofile}"
APP_IDENTITY="${DBJOY_APPSTORE_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Distribution|3rd Party Mac Developer Application)[^"]*"' | head -1 | tr -d '"' || true)}"
INSTALLER_IDENTITY="${DBJOY_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null \
  | grep -oE '"(3rd Party Mac Developer Installer|Mac Installer Distribution)[^"]*"' | head -1 | tr -d '"' || true)}"

missing=0
[ -n "$APP_IDENTITY" ] || { echo "error: no Apple Distribution certificate in the keychain" >&2; missing=1; }
[ -n "$INSTALLER_IDENTITY" ] || { echo "error: no Mac Installer Distribution certificate in the keychain" >&2; missing=1; }
[ -f "$PROFILE" ] || { echo "error: provisioning profile not found at $PROFILE" >&2; missing=1; }
[ "$missing" = 0 ] || { echo "See appstore/README.md for the one-time setup." >&2; exit 1; }

# The App Store build's entitlements carry the app and team identifiers from the profile.
ENTITLEMENTS="$(mktemp -t dbjoy-entitlements).plist"
trap 'rm -f "$ENTITLEMENTS"' EXIT
cp appstore/DBJoy.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM_ID.$BUNDLE_ID" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"

DBJOY_APPSTORE=1 DBJOY_RELEASE=1 DBJOY_SIGN_IDENTITY="$APP_IDENTITY" DBJOY_APP_ENTITLEMENTS="$ENTITLEMENTS" \
  DBJOY_PROVISIONING_PROFILE="$PROFILE" scripts/build-app.sh release
codesign --verify --deep --strict build/DBJoy.app

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/DBJoy.app/Contents/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' build/DBJoy.app/Contents/Info.plist)"
PKG="build/DBJoy-$VERSION.pkg"
rm -f "$PKG"
# Package a copy without extended attributes, which would otherwise end up as ._ files in the payload.
STAGING="$(mktemp -d)"
trap 'rm -f "$ENTITLEMENTS"; rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr --noqtn build/DBJoy.app "$STAGING/DBJoy.app"
COPYFILE_DISABLE=1 productbuild --component "$STAGING/DBJoy.app" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
if pkgutil --payload-files "$PKG" | grep -q '/\._'; then
  echo "warning: the package contains ._ (extended attribute) files; check it with Transporter before submitting" >&2
fi

echo "Created $PKG (version $VERSION, build $BUILD)"
echo "Upload it with Transporter, or: xcrun altool --upload-app -f \"$PKG\" -t macos --apiKey <key id> --apiIssuer <issuer id>"
