#!/bin/zsh
# Builds build/PenOverlay.app (menu-bar only, no Dock icon). Run with: open build/PenOverlay.app
# `./build.sh install` also copies it to ~/Applications (or $PENOVERLAY_INSTALL_DIR) so it opens from
# Spotlight and can be added to Login Items. A copy that is already running is left alone.
set -e
cd "$(dirname "$0")"
APP=build/PenOverlay.app
rm -rf build
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 PenOverlay.swift -o "$APP/Contents/MacOS/PenOverlay"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.parker.penoverlay</string>
  <key>CFBundleName</key><string>PenOverlay</string>
  <key>CFBundleExecutable</key><string>PenOverlay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "built $APP"

if [[ "$1" == install ]]; then
  DEST="${PENOVERLAY_INSTALL_DIR:-$HOME/Applications}"
  mkdir -p "$DEST"
  rm -rf "$DEST/PenOverlay.app"
  ditto "$APP" "$DEST/PenOverlay.app"
  echo "installed $DEST/PenOverlay.app"
  if pgrep -x PenOverlay >/dev/null; then
    echo "PenOverlay is running; quit it and reopen it to get this build"
  fi
fi
