#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST_DIR="$REPO_ROOT/dist"
APP_BUNDLE="$DIST_DIR/MacVoice.app"
DMG_FILE="$DIST_DIR/MacVoice.dmg"
STAGING_DIR="$DIST_DIR/dmg_staging"

# 1. Determine Code Signing Identity
# Only use an official Apple Developer ID for distribution builds.
# NEVER use local self-signed certificates (e.g. "MacVoice Local Development")
# for DMG distribution, because other Macs do not have the root cert and macOS
# will block the app with "The application MacVoice can't be opened."
APPLE_DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application:" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
SIGNING_IDENTITY=${MACVOICE_CODESIGN_IDENTITY:-$APPLE_DEV_ID}

echo "==> Packaging binary..."
# Use Universal binary (arm64 + x86_64) if available, otherwise build release
UNIVERSAL_BIN="$REPO_ROOT/.build/out/Products/Release/VoiceTypingApp"
if [ ! -f "$UNIVERSAL_BIN" ]; then
  echo "==> Building optimized Release binary..."
  cd "$REPO_ROOT"
  swift build -c release --product VoiceTypingApp
  BIN_PATH="$(swift build -c release --show-bin-path)/VoiceTypingApp"
else
  echo "==> Using prebuilt Universal binary (arm64 + x86_64)..."
  BIN_PATH="$UNIVERSAL_BIN"
fi

echo "==> Packaging MacVoice.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/VoiceTypingApp"
chmod +x "$APP_BUNDLE/Contents/MacOS/VoiceTypingApp"
cp "$REPO_ROOT/Resources/VoiceTypingApp-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/Brand/Exports/MacVoice.icns" "$APP_BUNDLE/Contents/Resources/MacVoice.icns"
cp "$REPO_ROOT/Brand/Exports/macvoice-icon-light-1024.png" "$APP_BUNDLE/Contents/Resources/MacVoiceAppIcon.png"
cp "$REPO_ROOT/Brand/Exports/macvoice-symbol-mono-black-1024.png" "$APP_BUNDLE/Contents/Resources/MacVoiceMenuBar.png"

# Strip all extended attributes and quarantine flags before signing
xattr -cr "$APP_BUNDLE"

echo "==> Signing MacVoice.app..."
if [ -n "$SIGNING_IDENTITY" ]; then
  echo "--> Signing with Apple Developer ID: $SIGNING_IDENTITY"
  codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
  echo "--> No Developer ID certificate found. Signing with clean ad-hoc signature for portable distribution..."
  codesign --force --deep --sign - "$APP_BUNDLE"
fi

echo "==> Assembling disk image staging..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

# Add clear instructions inside the DMG so users know not to launch inside the read-only disk image
cat << 'EOF' > "$STAGING_DIR/HOW_TO_INSTALL.txt"
====================================================================
               MACVOICE INSTALLATION INSTRUCTIONS
====================================================================

1. DRAG "MacVoice" to the "Applications" shortcut in this window.
   (IMPORTANT: Do NOT double-click MacVoice inside this disk image!
    macOS prevents running apps directly from a read-only disk image.)

2. Open your Applications folder and launch MacVoice from there.

3. FOR FIRST-TIME RUN (Gatekeeper Notice):
   Because MacVoice is an open-source indie app downloaded from the web:
   - If macOS shows "MacVoice can't be opened" or "Unidentified Developer":
     Open Terminal and run this one-time command:
     
     xattr -cr /Applications/MacVoice.app

   - Then launch MacVoice again. It will open instantly!

4. PERMISSIONS:
   MacVoice will ask for Accessibility & Microphone permissions:
   - Microphone: to hear your voice (100% on-device, never uploaded).
   - Accessibility: to type the transcribed text into your active app.

====================================================================
EOF

echo "==> Generating compressed DMG..."
rm -f "$DMG_FILE"
hdiutil create \
  -volname "MacVoice" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_FILE"

rm -rf "$STAGING_DIR"

if [ -n "$SIGNING_IDENTITY" ]; then
  echo "==> Signing DMG..."
  codesign --force --sign "$SIGNING_IDENTITY" "$DMG_FILE" || true

  # Check if notary credentials profile exists for automated notarization
  NOTARY_KEYCHAIN_PROFILE=${MACVOICE_NOTARY_PROFILE:-macvoice-notarize}
  if xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "==> Submitting DMG to Apple Notary Service..."
    xcrun notarytool submit "$DMG_FILE" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    echo "==> Stapling notarization ticket to DMG..."
    xcrun stapler staple "$DMG_FILE"
  fi
fi

echo ""
echo "=================================================="
echo "  MacVoice DMG Created Successfully!"
echo "  Path: $DMG_FILE"
echo "  Size: $(du -sh "$DMG_FILE" | awk '{print $1}')"
echo "=================================================="
