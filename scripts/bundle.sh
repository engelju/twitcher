#!/bin/bash
# Builds a release binary and assembles build/Twitcher.app with icon.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ scripts/make-icon.swift -nt build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build
fi

APP=build/Twitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Twitcher "$APP/Contents/MacOS/Twitcher"
cp scripts/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so Gatekeeper/TCC treat the bundle as a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP"
