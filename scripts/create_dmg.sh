#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/MacVoice.app"
DMG_FILE="$DIST_DIR/MacVoice.dmg"
STAGING_DIR="$DIST_DIR/dmg_staging"
SIGNING_IDENTITY=${MACVOICE_CODESIGN_IDENTITY:-MacVoice Local Development}

echo "==> Building optimized Release binary..."
cd "$REPO_ROOT"
swift build -c release --product VoiceTypingApp
BIN_DIR=$(swift build -c release --show-bin-path)

echo "==> Packaging MacVoice.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/VoiceTypingApp" "$APP_BUNDLE/Contents/MacOS/VoiceTypingApp"
cp "$REPO_ROOT/Resources/VoiceTypingApp-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/Brand/Exports/MacVoice.icns" "$APP_BUNDLE/Contents/Resources/MacVoice.icns"
cp "$REPO_ROOT/Brand/Exports/macvoice-icon-light-1024.png" "$APP_BUNDLE/Contents/Resources/MacVoiceAppIcon.png"
cp "$REPO_ROOT/Brand/Exports/macvoice-symbol-mono-black-1024.png" "$APP_BUNDLE/Contents/Resources/MacVoiceMenuBar.png"

echo "==> Signing MacVoice.app..."
if security find-certificate -c "$SIGNING_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Assembling disk image staging..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Generating compressed DMG..."
rm -f "$DMG_FILE"
hdiutil create \
  -volname "MacVoice" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_FILE"

rm -rf "$STAGING_DIR"

if security find-certificate -c "$SIGNING_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign --force --sign "$SIGNING_IDENTITY" "$DMG_FILE" || true
fi

echo ""
echo "=================================================="
echo "  MacVoice DMG Created Successfully!"
echo "  Path: $DMG_FILE"
echo "  Size: $(du -sh "$DMG_FILE" | awk '{print $1}')"
echo "=================================================="

