#!/bin/sh
# Builds dist/MacLens.app (release) and signs it.
#   Version:  CFBundleShortVersionString from version.txt (managed by release-please);
#             CFBundleVersion from $MACLENS_BUILD_NUMBER, else the git commit count.
#   Signing:  ad-hoc by default (releases are free and not notarized). Set $MACLENS_SIGN_IDENTITY to a local
#             self-signed code-signing identity to keep Full Disk Access across your own rebuilds.
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product MacLens
VERSION=$(tr -d '[:space:]' < version.txt)
BUILD=${MACLENS_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
APP=dist/MacLens.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MacLens "$APP/Contents/MacOS/MacLens"
# App icon (generated once, then reused).
if [ ! -f Resources/AppIcon.icns ]; then
  ICONSET=.build/AppIcon.iconset
  rm -rf "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET"
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.maclens.MacLens</string>
  <key>CFBundleName</key><string>MacLens</string>
  <key>CFBundleDisplayName</key><string>MacLens</string>
  <key>CFBundleExecutable</key><string>MacLens</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Akshay Rahatwal · MIT License</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
IDENTITY="${MACLENS_SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP $VERSION ($BUILD), signed with: $IDENTITY"
ls -lh "$APP/Contents/MacOS/MacLens" | awk '{print "binary size:", $5}'
