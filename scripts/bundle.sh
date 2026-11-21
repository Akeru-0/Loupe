#!/bin/sh
# Builds Loupe and assembles build/Loupe.app (ad-hoc signed). No Xcode needed.
# Usage: scripts/bundle.sh [debug|release]
set -e
cd "$(dirname "$0")/.."
CONF="${1:-debug}"
swift build --build-system native -c "$CONF" --product Loupe
BIN="$(swift build --build-system native -c "$CONF" --show-bin-path)/Loupe"
APP=build/Loupe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loupe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # drawn by scripts/make-icon.swift
codesign --force --sign - "$APP"
echo "Built $APP ($CONF)"
