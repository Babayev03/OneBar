#!/bin/zsh
# Build OneBar, assemble OneBar.app (ad-hoc signed, stable bundle ID so the
# Accessibility/TCC grant survives rebuilds), and install it to /Applications.
set -e
cd "$(dirname "$0")"

swift build -c release

APP=dist/OneBar.app
BIN=.build/release/OneBar

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OneBar"
cp Bundle/Info.plist "$APP/Contents/Info.plist"
cp Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"

# Install: prefer /Applications, fall back to ~/Applications.
TARGET=/Applications/OneBar.app
if ! { rm -rf "$TARGET" 2>/dev/null && cp -R "$APP" "$TARGET" 2>/dev/null }; then
    mkdir -p "$HOME/Applications"
    TARGET="$HOME/Applications/OneBar.app"
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
fi

# Relaunch from the installed location.
pkill -x OneBar 2>/dev/null || true
sleep 0.3
open "$TARGET"
echo "OneBar installed and launched from $TARGET"
