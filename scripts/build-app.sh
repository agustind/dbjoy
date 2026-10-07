#!/bin/bash
# Builds DBJoy.app into ./build. Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DBJoy"

APP="build/DBJoy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DBJoy"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleShortVersionString</key><string>0.2.7</string>
    <key>CFBundleVersion</key><string>9</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
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
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/DBJoy" 2>/dev/null || true
for lib in "$FRAMEWORKS"/*.dylib; do
  install_name_tool -add_rpath "@loader_path" "$lib" 2>/dev/null || true
done
if otool -L "$APP/Contents/MacOS/DBJoy" "$FRAMEWORKS"/*.dylib | grep -qE "^\s+(/opt/homebrew|/usr/local)/"; then
  echo "error: unbundled Homebrew library references remain" >&2
  exit 1
fi

# Sign with a stable identity so Keychain "Always Allow" survives rebuilds; ad-hoc signatures
# change with every build and make macOS ask for the keychain password again.
# Override with DBJOY_SIGN_IDENTITY="Apple Development: ..." (or "-" for ad-hoc).
# DBJOY_RELEASE=1 adds a secure timestamp (needed for notarization).
IDENTITY="${DBJOY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  TIMESTAMP="--timestamp=none"
  [ -n "${DBJOY_RELEASE:-}" ] && TIMESTAMP="--timestamp"
  for lib in "$FRAMEWORKS"/*.dylib; do
    codesign --force $TIMESTAMP --options runtime --sign "$IDENTITY" "$lib"
  done
  codesign --force $TIMESTAMP --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
  echo "Signed ad-hoc (Keychain will ask again after each rebuild)"
fi
echo "Built $APP"
