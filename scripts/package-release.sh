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

cat > dist/maclens.rb <<CASK
cask "maclens" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/amrakshay/maclens/releases/download/v#{version}/MacLens-#{version}.zip"
  name "MacLens"
  desc "Developer-focused Mac monitor: heat, battery drain, ports and build-artifact cleanup"
  homepage "https://github.com/amrakshay/maclens"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MacLens.app"

  zap trash: [
    "~/Library/Caches/dev.maclens",
    "~/Library/Preferences/dev.maclens.MacLens.plist",
  ]

  caveats <<~EOS
    MacLens release builds are not yet notarized by Apple. On first launch macOS will block it:
      1. Open MacLens once (it will be blocked).
      2. System Settings → Privacy & Security → "MacLens was blocked…" → Open Anyway.
  EOS
end
CASK
echo "Packaged $ZIP"
echo "sha256 $SHA"
