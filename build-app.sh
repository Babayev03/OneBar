#!/bin/zsh
# Build OneBar, assemble OneBar.app, sign it with a designated requirement that
# survives rebuilds, and install it to /Applications.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=dist/OneBar.app
BIN=.build/release/OneBar
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Bundle/Info.plist)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OneBar"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
cp Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc, but with the designated requirement spelled out. Left to itself
# codesign pins the cdhash, which every rebuild changes, and TCC then fails the
# Accessibility check while System Settings still draws the toggle as on — the
# app looks authorised and is silently denied. Naming the bundle ID instead
# keeps the requirement byte-identical across builds, so the grant sticks.
codesign --force --sign - --identifier "$BUNDLE_ID" \
    -r="designated => identifier \"$BUNDLE_ID\"" "$APP"

# Quit the running copy *before* replacing the bundle under it, and wait for the
# process to actually go: `open` on an app that is still alive just reactivates
# the old instance, so the new build never runs.
pkill -x OneBar 2>/dev/null || true
for _ in {1..50}; do
    pgrep -x OneBar >/dev/null || break
    sleep 0.1
done
pkill -9 -x OneBar 2>/dev/null || true

# Install: prefer /Applications, fall back to ~/Applications.
TARGET=/Applications/OneBar.app
if ! { rm -rf "$TARGET" 2>/dev/null && cp -R "$APP" "$TARGET" 2>/dev/null }; then
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/OneBar.app"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
fi

open "$TARGET"
echo "OneBar installed and launched from $TARGET"
