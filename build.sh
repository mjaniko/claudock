#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Claudock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Claudock "$APP/Contents/MacOS/Claudock"
mkdir -p "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/BurstMask.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
