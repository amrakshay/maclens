#!/bin/sh
# Commits a cask file to github.com/amrakshay/homebrew-tap (Casks/maclens.rb) and pushes it.
# Usage: TAP_TOKEN=... scripts/publish-cask.sh path/to/maclens.rb VERSION
# TAP_TOKEN: fine-grained PAT with Contents read/write on amrakshay/homebrew-tap (repo secret HOMEBREW_TAP_TOKEN).
set -eu
CASK=$1
VERSION=$2
DIR=$(mktemp -d)
git clone --depth 1 "https://x-access-token:${TAP_TOKEN}@github.com/amrakshay/homebrew-tap.git" "$DIR"
mkdir -p "$DIR/Casks"
cp "$CASK" "$DIR/Casks/maclens.rb"
cd "$DIR"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/maclens.rb
if git diff --cached --quiet; then echo "Cask already up to date"; exit 0; fi
git commit -m "maclens $VERSION"
git push
echo "Published maclens $VERSION to amrakshay/homebrew-tap"
