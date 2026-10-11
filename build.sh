#!/usr/bin/env bash
# Builds PersianDictate.app into ./build and signs it.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PersianDictate"
CONFIG="${CONFIG:-release}"
APP="build/${APP_NAME}.app"

echo "==> swift build (${CONFIG})"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> packaging ${APP}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# A real identity keeps the Accessibility grant across rebuilds; ad-hoc signing loses it every time.
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
echo "==> codesign (${SIGN_ID:-ad-hoc})"
codesign --force --deep --sign "${SIGN_ID:--}" "$APP"
codesign --verify --verbose=1 "$APP"

echo "Done: $APP"
echo "Install:  cp -R \"$APP\" /Applications/"
