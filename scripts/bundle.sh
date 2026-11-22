#!/bin/sh
# Builds Loupe and assembles build/Loupe.app (with Sparkle embedded) and signs it. No Xcode needed.
# Usage: scripts/bundle.sh [debug|release]
# Env:   VERSION=1.2.0 BUILD=57   stamp the version (else Resources/Info.plist's)
#        SWIFT_FLAGS="-Xswiftc -DLOUPE_BENCH"  extra flags for swift build (here: the scroll benchmark in a release build)
#        SIGN_IDENTITY="…"        code signing identity (default: the "Loupe" self-signed certificate if it's in
#                                 the keychain, else ad hoc). The same identity every release keeps macOS
#                                 permissions such as Full Disk Access across updates.
set -e
cd "$(dirname "$0")/.."
CONF="${1:-debug}"
swift build --build-system native -c "$CONF" $SWIFT_FLAGS --product Loupe
BIN_DIR="$(swift build --build-system native -c "$CONF" $SWIFT_FLAGS --show-bin-path)"
APP=build/Loupe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Loupe" "$APP/Contents/MacOS/Loupe"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # drawn by scripts/make-icon.swift
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Loupe"

if [ -n "$VERSION" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"; fi
if [ -n "$BUILD" ]; then /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"; fi

if [ -z "$SIGN_IDENTITY" ]; then
  # A self-signed certificate is listed as not trusted; codesign signs with it all the same (by its fingerprint).
  SIGN_IDENTITY=$(security find-identity -p codesigning | awk '/"Loupe"/ { print $2; exit }')
  [ -n "$SIGN_IDENTITY" ] || SIGN_IDENTITY="-"
fi
if [ "$SIGN_IDENTITY" = "-" ]; then
  echo "warning: signing ad hoc; create the \"Loupe\" certificate (see scripts/release.sh) so updates keep permissions" >&2
fi
codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONF, signed by $SIGN_IDENTITY)"
