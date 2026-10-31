#!/usr/bin/env bash
# Wraps the release executable in InkBridge.app with Info.plist and an
# ad-hoc signature. Developer ID signing and notarization are Phase 5.
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/InkBridge/macos-build}"
swift build --scratch-path "$BUILD_DIR" -c release --product InkBridge
APP="$BUILD_DIR/InkBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/release/InkBridge" "$APP/Contents/MacOS/InkBridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "built $APP"
