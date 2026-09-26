#!/usr/bin/env bash
# Builds a release zip and a signed Sparkle appcast in build/releases.
#
# Releases are normally published by .github/workflows/release.yml when a v<version> tag is
# pushed. Running this script locally produces the same files without publishing them.
#
# Environment:
#   ONESHOT_VERSION        Version to release (default: CFBundleShortVersionString in Info.plist).
#   ONESHOT_RELEASE_NOTES  Optional plain text notes; "- " lines become a list. Shown by Sparkle.
#   SPARKLE_PRIVATE_KEY    Private EdDSA key. Without it, generate_appcast reads the key from
#                          the keychain (created once with .build/artifacts/sparkle/Sparkle/bin/generate_keys).
#   ONESHOT_SIGN_IDENTITY  Code signing identity, see build-app.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="${ONESHOT_GITHUB_REPO:-fatihacet/oneshot}"
VERSION="${ONESHOT_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
RELEASES="$ROOT/build/releases"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"

ONESHOT_VERSION="$VERSION" ./scripts/build-app.sh
rm -rf "$RELEASES"
mkdir -p "$RELEASES"
ZIP="$RELEASES/OneShot-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$ROOT/build/OneShot.app" "$ZIP"

# generate_appcast embeds an HTML fragment named like the archive as the update's release notes.
if [[ -n "${ONESHOT_RELEASE_NOTES:-}" && -s "$ONESHOT_RELEASE_NOTES" ]]; then
  awk '
    function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
    /^[-*] / { if (!list) { print "<ul>"; list = 1 } print "<li>" esc(substr($0, 3)) "</li>"; next }
    list { print "</ul>"; list = 0 }
    NF { print "<p>" esc($0) "</p>" }
    END { if (list) print "</ul>" }
  ' "$ONESHOT_RELEASE_NOTES" > "$RELEASES/OneShot-$VERSION.html"
fi

APPCAST_ARGS=(
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/"
  --link "https://github.com/$REPO"
  --full-release-notes-url "https://github.com/$REPO/releases"
)
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_BIN/generate_appcast" --ed-key-file - "${APPCAST_ARGS[@]}" "$RELEASES"
else
  "$SPARKLE_BIN/generate_appcast" "${APPCAST_ARGS[@]}" "$RELEASES"
fi

echo
echo "Release files:"
echo "  $ZIP"
echo "  $RELEASES/appcast.xml"
