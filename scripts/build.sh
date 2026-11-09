#!/bin/bash
# Builds Butler.app and Butler.dmg into ./dist. Needs only the macOS command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=dist/Butler.app
# Change this if you publish your own build, so it does not share settings and permissions with someone else's.
BUNDLE_ID="${BUNDLE_ID:-com.oaksley.butler}"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build -c release
cp .build/release/Butler "$APP/Contents/MacOS/Butler"

# icon
ICONSET=dist/Butler.iconset
swift scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Butler.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Butler</string>
  <key>CFBundleDisplayName</key><string>Butler</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Butler</string>
  <key>CFBundleIconFile</key><string>Butler</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSRemindersFullAccessUsageDescription</key><string>Butler keeps your tasks in Apple Reminders, so they show on your iPhone and other devices, and reminders added there show in Butler.</string>
  <key>NSRemindersUsageDescription</key><string>Butler keeps your tasks in Apple Reminders, so they show on your iPhone and other devices.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Butler shows today's and tomorrow's events next to your tasks. It never changes your calendar.</string>
  <key>NSCalendarsUsageDescription</key><string>Butler shows today's and tomorrow's events next to your tasks.</string>
  <key>NSAppleEventsUsageDescription</key><string>Butler reads what is playing in Music, VLC or YouTube Music to show it at the notch, and asks Finder to empty the Trash when you choose Empty Trash.</string>
</dict></plist>
PLIST

# Sign with the local "Butler Local Signing" certificate when it is in the keychain. A stable identity means macOS
# remembers Butler's permissions (folders, Automation) across rebuilds. Falls back to ad-hoc signing without it.
IDENTITY="Butler Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "note: \"$IDENTITY\" not found, signing ad-hoc (permissions reset on every rebuild)"
  codesign --force --deep --sign - "$APP"
fi

# DMG with an Applications shortcut
STAGE=dist/dmg && mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Butler" -srcfolder "$STAGE" -ov -format UDZO dist/Butler.dmg >/dev/null
rm -rf "$STAGE"
echo "Built: $PWD/dist/Butler.dmg ($(du -h dist/Butler.dmg | cut -f1))"
