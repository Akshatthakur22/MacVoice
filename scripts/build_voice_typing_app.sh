#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_BUNDLE="$REPO_ROOT/dist/VoiceTyping.app"

cd "$REPO_ROOT"
swift build --product VoiceTypingApp
BIN_DIR=$(swift build --show-bin-path)
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BIN_DIR/VoiceTypingApp" "$APP_BUNDLE/Contents/MacOS/VoiceTypingApp"
cp "$REPO_ROOT/Resources/VoiceTypingApp-Info.plist" "$APP_BUNDLE/Contents/Info.plist"
codesign --force --deep --sign - "$APP_BUNDLE"
printf 'Built %s\n' "$APP_BUNDLE"
