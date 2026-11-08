#!/bin/sh
# Builds build/Coolant.app. Pass --install to copy it to /Applications.
set -eu
cd "$(dirname "$0")/.."
swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Coolant.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Coolant" "$BIN/coolantd" "$BIN/coolantctl" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/install-helper.sh Resources/uninstall-helper.sh "$APP/Contents/Resources/"
codesign --force --sign - "$APP/Contents/MacOS/coolantd" "$APP/Contents/MacOS/coolantctl"
codesign --force --sign - "$APP"
if [ "${1:-}" = "--install" ]; then
    rm -rf /Applications/Coolant.app
    cp -R "$APP" /Applications/
    echo "Installed /Applications/Coolant.app"
else
    echo "Built $APP"
fi
