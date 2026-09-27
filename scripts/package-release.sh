#!/bin/sh
# Zips dist/MacLens.app for a release and writes its SHA-256 and a Homebrew cask.
#   Output: dist/MacLens-<version>.zip, dist/MacLens-<version>.zip.sha256, dist/maclens.rb
# Run ./scripts/build-app.sh first. Safe to run locally; it only writes into dist/.
set -eu
cd "$(dirname "$0")/.."
VERSION=$(tr -d '[:space:]' < version.txt)
ZIP="dist/MacLens-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent dist/MacLens.app "$ZIP"   # ditto keeps the code signature intact
SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
echo "$SHA  MacLens-$VERSION.zip" > "$ZIP.sha256"

./scripts/make-cask.sh "$VERSION" "$SHA" > dist/maclens.rb
echo "Packaged $ZIP"
echo "sha256 $SHA"
