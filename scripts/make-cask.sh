#!/bin/sh
# Prints the Homebrew cask for a MacLens release. Usage: scripts/make-cask.sh VERSION SHA256
# Used by package-release.sh (local/CI builds) and the "Publish Homebrew cask" workflow (existing releases).
set -eu
VERSION=$1
SHA=$2
cat <<CASK
cask "maclens" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/amrakshay/maclens/releases/download/v#{version}/MacLens-#{version}.zip"
  name "MacLens"
  desc "Developer-focused monitor for heat, battery drain, ports and build artifacts"
  homepage "https://github.com/amrakshay/maclens"

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "MacLens.app"

  zap trash: [
    "~/Library/Caches/dev.maclens",
    "~/Library/Preferences/dev.maclens.MacLens.plist",
  ]

  caveats <<~EOS
    MacLens is free and not notarized by Apple, so macOS blocks the first launch:
      1. Open MacLens once (it will be blocked).
      2. System Settings → Privacy & Security → "MacLens was blocked…" → Open Anyway.
  EOS
end
CASK
