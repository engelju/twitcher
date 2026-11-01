#!/bin/bash
# Builds a release binary, assembles Twitcher.app with icon, and installs it
# to /Applications (so Spotlight and Launchpad find it).
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

# Moved rather than copied, so Spotlight doesn't index two Twitchers. Only
# replaces an existing app if it's ours.
INSTALLED=/Applications/Twitcher.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' scripts/Info.plist)
if [ -e "$INSTALLED" ]; then
  EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)
  if [ "$EXISTING_ID" != "$BUNDLE_ID" ]; then
    echo "$INSTALLED exists but isn't Twitcher ($EXISTING_ID); leaving it alone. Built $APP" >&2
    exit 1
  fi
  rm -rf "$INSTALLED"
fi
mv "$APP" "$INSTALLED"

echo "Installed $INSTALLED"
if pgrep -xq Twitcher; then
  echo "Twitcher is running — quit and relaunch it to use the new build."
fi
