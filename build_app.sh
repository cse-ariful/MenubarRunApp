#!/usr/bin/env bash
# Builds RunXcodeApp.app into ./build
#   ./build_app.sh            build only
#   ./build_app.sh --run      build and launch
#   ./build_app.sh --install  build, copy to /Applications and launch
#   ./build_app.sh --zip      build and create build/RunXcodeApp-<version>.zip
#   ./build_app.sh --dmg      build and create build/RunXcodeApp-<version>.dmg (drag-to-Applications disk image)
#
# Environment:
#   UNIVERSAL=1        build for both Apple Silicon and Intel
#   VERSION=1.2.0      stamp CFBundleShortVersionString
#   BUILD_NUMBER=42    stamp CFBundleVersion (defaults to VERSION)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="RunXcodeApp"
CONFIG="${CONFIG:-release}"
APP="build/${APP_NAME}.app"

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "→ swift build (${CONFIG}${UNIVERSAL:+, universal})"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "→ Assembling ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ -n "${VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
fi
VERSION_STRING="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"

echo "→ Ad-hoc signing"
codesign --force --deep --sign - "$APP"

echo "✓ Built $(pwd)/$APP (version $VERSION_STRING)"

case "${1:-}" in
  --run)
    pkill -x "$APP_NAME" 2>/dev/null || true
    open "$APP"
    ;;
  --install)
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP" /Applications/
    open "/Applications/${APP_NAME}.app"
    echo "✓ Installed to /Applications/${APP_NAME}.app"
    ;;
  --dmg)
    DMG="build/${APP_NAME}-${VERSION_STRING}.dmg"
    STAGE="build/dmg-staging"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"   # so users can drag the app into Applications
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✓ $DMG"
    shasum -a 256 "$DMG"
    ;;
  --zip)
    ZIP="build/${APP_NAME}-${VERSION_STRING}.zip"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    echo "✓ $ZIP"
    shasum -a 256 "$ZIP"
    ;;
esac
