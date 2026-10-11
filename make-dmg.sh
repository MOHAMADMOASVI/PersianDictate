#!/usr/bin/env bash
# Builds PersianDictate.app and wraps it in build/PersianDictate.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PersianDictate"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

./build.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> packaging ${DMG}"
rm -f "$DMG"
hdiutil create -volname "${APP_NAME} ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov -quiet "$DMG"
hdiutil verify -quiet "$DMG"

echo "Done: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
