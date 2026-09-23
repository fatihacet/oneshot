#!/usr/bin/env bash
# Builds OneShot.app into ./build.
#
# Signing identity, in order of preference:
#   1. $ONESHOT_SIGN_IDENTITY
#   2. "OneShot Local Signing" (created by scripts/create-dev-cert.sh)
#   3. ad-hoc ("-"); macOS will ask for Screen Recording permission again after each rebuild.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP="$ROOT/build/OneShot.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/OneShot" "$APP/Contents/MacOS/OneShot"
# Sparkle is a binary framework; ditto keeps its symlinks intact.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/oneshot" "$APP/Contents/Resources/oneshot"
chmod +x "$APP/Contents/Resources/oneshot"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

IDENTITY="${ONESHOT_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "OneShot Local Signing" >/dev/null 2>&1; then
  IDENTITY="OneShot Local Signing"
fi
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
echo "Built $APP (signed with: $IDENTITY)"
