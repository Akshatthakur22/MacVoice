#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_BUNDLE="$REPO_ROOT/dist/MacVoice.app"
SIGNING_IDENTITY=${MACVOICE_CODESIGN_IDENTITY:-MacVoice Local Development}
ALLOW_ADHOC_SIGNING=${MACVOICE_ALLOW_ADHOC_SIGNING:-0}

if ! security find-certificate -c "$SIGNING_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  if [ "$ALLOW_ADHOC_SIGNING" != "1" ]; then
    echo "Stable signing identity '$SIGNING_IDENTITY' was not found." >&2
    echo "Set up a stable local code-signing identity, or explicitly opt into a temporary ad-hoc build with MACVOICE_ALLOW_ADHOC_SIGNING=1." >&2
    exit 1
  fi
fi

cd "$REPO_ROOT"
swift build --product VoiceTypingApp
BIN_DIR=$(swift build --show-bin-path)
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/VoiceTypingApp" "$APP_BUNDLE/Contents/MacOS/VoiceTypingApp"
cp "$REPO_ROOT/Resources/VoiceTypingApp-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/Resources/mlx_worker.py" "$APP_BUNDLE/Contents/Resources/mlx_worker.py"
cp "$REPO_ROOT/scripts/install_local_polisher.sh" "$APP_BUNDLE/Contents/Resources/install_local_polisher.sh"
cp "$REPO_ROOT/Brand/Exports/MacVoice.icns" "$APP_BUNDLE/Contents/Resources/MacVoice.icns"
cp "$REPO_ROOT/Brand/Exports/macvoice-icon-light-1024.png" "$APP_BUNDLE/Contents/Resources/MacVoiceAppIcon.png"
cp "$REPO_ROOT/Brand/Exports/macvoice-symbol-mono-black-1024.png" "$APP_BUNDLE/Contents/Resources/MacVoiceMenuBar.png"
if security find-certificate -c "$SIGNING_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
else
  codesign --force --deep --sign - "$APP_BUNDLE"
  echo "Warning: this ad-hoc build has a per-build identity; macOS privacy permissions may need to be granted again after rebuilding." >&2
fi
printf 'Built %s\n' "$APP_BUNDLE"
