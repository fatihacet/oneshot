#!/usr/bin/env bash
# Builds a release zip and an updated Sparkle appcast in build/releases.
#
# Usage: scripts/release.sh
#   1. Bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist.
#   2. Run this script. It signs the zip with the Sparkle EdDSA key from your keychain
#      (created once with .build/artifacts/sparkle/Sparkle/bin/generate_keys).
#   3. Create a GitHub release tagged v<version> and attach the zip and appcast.xml.
#      SUFeedURL points at releases/latest/download/appcast.xml.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="${ONESHOT_GITHUB_REPO:-fatihacet/oneshot}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
RELEASES="$ROOT/build/releases"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

./scripts/build-app.sh
mkdir -p "$RELEASES"
ZIP="$RELEASES/OneShot-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/OneShot.app" "$ZIP"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  "$RELEASES"

echo
echo "Release files:"
echo "  $ZIP"
echo "  $RELEASES/appcast.xml"
echo "Next: gh release create v$VERSION \"$ZIP\" \"$RELEASES/appcast.xml\" --repo $REPO"
