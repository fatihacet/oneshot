#!/usr/bin/env bash
# Builds OneShot.app into ./build.
#
# Signing identity, in order of preference:
#   1. $ONESHOT_SIGN_IDENTITY
#   2. "OneShot Release Signing", the identity published releases are signed with, if it is in the
#      keychain. macOS ties privacy permissions (Screen Recording, Microphone, Camera) to the signing
#      certificate, so signing local builds the same way lets them share one grant with releases.
#   3. "OneShot Local Signing" (created by scripts/create-dev-cert.sh)
#   4. ad-hoc ("-"); macOS will ask for Screen Recording permission again after each rebuild.
#
# Version: $ONESHOT_VERSION, set from the tag by the release workflow. Other builds describe
# themselves relative to the latest release tag, e.g. 0.2.0-3-g54b1d52 for three commits after
# v0.2.0 (with -dirty for uncommitted changes), falling back to Resources/Info.plist without tags.
# The build number is the commit count, so a build is never older than the releases before it
# and Sparkle does not offer a local build an older release as an update.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/OneShot.app"
VERSION="${ONESHOT_VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(git -C "$ROOT" describe --tags --match 'v[0-9]*' --dirty 2>/dev/null | sed 's/^v//')" || true
fi
BUILD_NUMBER="${ONESHOT_BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

cd "$ROOT"
swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/OneShot" "$APP/Contents/MacOS/OneShot"
# Sparkle is a binary framework; ditto keeps its symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/oneshot" "$APP/Contents/Resources/oneshot"
chmod +x "$APP/Contents/Resources/oneshot"
# Compile the Icon Composer icon into Assets.car, plus an AppIcon.icns for macOS versions before 26.
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/build/AppIcon-info.plist" --errors --warnings >/dev/null

IDENTITY="${ONESHOT_SIGN_IDENTITY:-}"
for candidate in "OneShot Release Signing" "OneShot Local Signing"; do
  if [[ -z "$IDENTITY" ]] && security find-certificate -c "$candidate" >/dev/null 2>&1; then
    IDENTITY="$candidate"
  fi
done
IDENTITY="${IDENTITY:--}"

# Sign nested code inside-out (no --deep), as recommended by Sparkle.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$@"; }
for xpc in "$SPARKLE"/Versions/B/XPCServices/*.xpc; do
  [[ -e "$xpc" ]] && sign --preserve-metadata=entitlements "$xpc"
done
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements "$ROOT/Resources/OneShot.entitlements" "$APP"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "Built $APP $SHORT_VERSION ($BUILD_NUMBER) (signed with: $IDENTITY)"
