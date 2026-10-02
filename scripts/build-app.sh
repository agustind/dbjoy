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

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DBJoy</string>
    <key>CFBundleDisplayName</key><string>DBJoy</string>
    <key>CFBundleIdentifier</key><string>app.dbjoy.DBJoy</string>
    <key>CFBundleExecutable</key><string>DBJoy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# Sign with a stable identity so Keychain "Always Allow" survives rebuilds; ad-hoc signatures
# change with every build and make macOS ask for the keychain password again.
# Override with DBJOY_SIGN_IDENTITY="Apple Development: ..." (or "-" for ad-hoc).
IDENTITY="${DBJOY_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep -oE '"(Apple Development|Developer ID Application)[^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != "-" ]; then
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP" >/dev/null 2>&1 || true
  echo "Signed ad-hoc (Keychain will ask again after each rebuild)"
fi
echo "Built $APP"
