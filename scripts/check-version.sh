#!/bin/sh
# Fails if the version in dist/ (app Info.plist, zip name, cask) doesn't match version.txt — and, when a tag is
# given, the release tag. Usage: scripts/check-version.sh [vX.Y.Z]   (run after build-app.sh + package-release.sh)
set -eu
cd "$(dirname "$0")/.."
WANT=$(tr -d '[:space:]' < version.txt)
fail() { echo "::error::$1"; exit 1; }
echo "$WANT" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || fail "version.txt ($WANT) is not X.Y.Z"
if [ "${1:-}" != "" ]; then [ "${1#v}" = "$WANT" ] || fail "tag $1 does not match version.txt $WANT"; fi
PLIST=dist/MacLens.app/Contents/Info.plist
APPV=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")
[ "$APPV" = "$WANT" ] || fail "app CFBundleShortVersionString $APPV != $WANT"
echo "$BUILD" | grep -Eq '^[1-9][0-9]*$' || fail "CFBundleVersion '$BUILD' is not a positive integer"
/usr/libexec/PlistBuddy -c "Print NSHumanReadableCopyright" "$PLIST" >/dev/null 2>&1 || fail "Info.plist has no NSHumanReadableCopyright (About panel)"
[ -f "dist/MacLens-$WANT.zip" ] || fail "dist/MacLens-$WANT.zip missing"
grep -q "version \"$WANT\"" dist/maclens.rb || fail "cask version != $WANT"
echo "Version check OK: $WANT (build $BUILD)${1:+, tag $1}"
