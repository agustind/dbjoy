#!/bin/bash
# Builds DBJoy.app into ./build. Usage: scripts/build-app.sh [debug|release]
#   DBJOY_SANDBOX=1   sign with the App Sandbox entitlements (to try the App Store build locally)
#   DBJOY_APPSTORE=1  Mac App Store build; use scripts/make-appstore.sh, which sets everything up
set -euo pipefail
cd "$(dirname "$0")/.."
[ -n "${DBJOY_APPSTORE:-}" ] && DBJOY_SANDBOX=1

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DBJoy"

APP="build/DBJoy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/DBJoy"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Helpers: the SSH askpass, and pg_dump for backups (so they don't need Homebrew).
cp "$(dirname "$BIN")/dbjoy-askpass" "$APP/Contents/Helpers/dbjoy-askpass"
LIBPQ_PREFIX="${LIBPQ_PREFIX:-/opt/homebrew/opt/libpq}"
cp "$(realpath "$LIBPQ_PREFIX/bin/pg_dump")" "$APP/Contents/Helpers/pg_dump"
chmod u+w "$APP/Contents/Helpers/pg_dump"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DBJoy</string>
    <key>CFBundleDisplayName</key><string>DBJoy</string>
    <key>CFBundleIdentifier</key><string>app.dbjoy.DBJoy</string>
    <key>CFBundleExecutable</key><string>DBJoy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.9</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Agu Dondo. MIT License.</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict>
</plist>
PLIST

# Bundle Homebrew libraries (libpq, OpenSSL, Kerberos, …) so the app runs on Macs without them.
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
is_external() { [[ "$1" == /opt/homebrew/* || "$1" == /usr/local/* ]]; }
bundle_deps() {
  local file="$1"
  otool -L "$file" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    is_external "$dep" || continue
    local name; name="$(basename "$dep")"
    if [ ! -f "$FRAMEWORKS/$name" ]; then
      cp "$(realpath "$dep")" "$FRAMEWORKS/$name"
      chmod u+w "$FRAMEWORKS/$name"
      install_name_tool -id "@rpath/$name" "$FRAMEWORKS/$name" 2>/dev/null
      bundle_deps "$FRAMEWORKS/$name"
    fi
    install_name_tool -change "$dep" "@rpath/$name" "$file" 2>/dev/null
  done
}
bundle_deps "$APP/Contents/MacOS/DBJoy"
bundle_deps "$APP/Contents/Helpers/pg_dump"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DBJoy" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/Helpers/pg_dump" 2>/dev/null || true
for lib in "$FRAMEWORKS"/*.dylib; do
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
if otool -L "$APP/Contents/MacOS/DBJoy" "$APP/Contents/Helpers/pg_dump" "$FRAMEWORKS"/*.dylib | grep -qE "^\s+(/opt/homebrew|/usr/local)/"; then
  echo "error: unbundled Homebrew library references remain" >&2
  exit 1
fi

# Sign with a stable identity so Keychain "Always Allow" survives rebuilds; ad-hoc signatures
# change with every build and make macOS ask for the keychain password again.
# Override with DBJOY_SIGN_IDENTITY="Apple Development: ..." (or "-" for ad-hoc).
# DBJOY_RELEASE=1 adds a secure timestamp (needed for notarization).
IDENTITY="${DBJOY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')}"
# Sandboxed builds sign the helpers so they inherit the app's sandbox, and the app with its entitlements.
HELPER_ENTITLEMENTS=()
APP_ENTITLEMENTS=()
if [ -n "${DBJOY_SANDBOX:-}" ]; then
  HELPER_ENTITLEMENTS=(--entitlements appstore/Helper.entitlements)
  APP_ENTITLEMENTS=(--entitlements "${DBJOY_APP_ENTITLEMENTS:-appstore/DBJoy.entitlements}")
fi
if [ -n "${DBJOY_PROVISIONING_PROFILE:-}" ]; then
  cp "$DBJOY_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
fi
# Extended attributes would end up as ._ files in the App Store package.
xattr -cr "$APP"
# No identity: sign ad-hoc ("-").
IDENTITY="${IDENTITY:--}"
SIGN_FLAGS=(--force --options runtime --timestamp=none)
[ -n "${DBJOY_RELEASE:-}" ] && SIGN_FLAGS=(--force --options runtime --timestamp)
[ "$IDENTITY" = "-" ] && SIGN_FLAGS=(--force)
for lib in "$FRAMEWORKS"/*.dylib; do
  codesign "${SIGN_FLAGS[@]}" --sign "$IDENTITY" "$lib"
done
for helper in "$APP/Contents/Helpers"/*; do
  codesign "${SIGN_FLAGS[@]}" ${HELPER_ENTITLEMENTS[@]+"${HELPER_ENTITLEMENTS[@]}"} --sign "$IDENTITY" "$helper"
done
codesign "${SIGN_FLAGS[@]}" ${APP_ENTITLEMENTS[@]+"${APP_ENTITLEMENTS[@]}"} --sign "$IDENTITY" "$APP"
if [ "$IDENTITY" = "-" ]; then
  echo "Signed ad-hoc (Keychain will ask again after each rebuild)"
else
  echo "Signed with: $IDENTITY${DBJOY_SANDBOX:+ (sandboxed)}"
fi
echo "Built $APP"
