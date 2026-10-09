#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_BUNDLE="$REPO_ROOT/dist/VoiceTyping.app"

cd "$REPO_ROOT"
swift build --product VoiceTypingApp
BIN_DIR=$(swift build --show-bin-path)
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/VoiceTypingApp" "$APP_BUNDLE/Contents/MacOS/VoiceTypingApp"
cp "$REPO_ROOT/Resources/VoiceTypingApp-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$REPO_ROOT/Resources/mlx_worker.py" "$APP_BUNDLE/Contents/Resources/mlx_worker.py"
cp "$REPO_ROOT/scripts/install_local_polisher.sh" "$APP_BUNDLE/Contents/Resources/install_local_polisher.sh"
codesign --force --deep --sign - "$APP_BUNDLE"
printf 'Built %s\n' "$APP_BUNDLE"
