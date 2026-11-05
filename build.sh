#!/bin/bash
# Builds build/Switchmypanes.app from the command line.
#   ./build.sh            build + sign
#   ./build.sh run        build, sign, and launch
#   ./build.sh install    build, sign, copy to ~/Applications (Spotlight finds it there) and relaunch
#   SIGN_IDENTITY="Some Identity" ./build.sh    use a different signing identity
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Switchmypanes"
BUNDLE_ID="com.praneelcore.switchmypanes"
IDENTITY="${SIGN_IDENTITY:-Switchmypanes Local Dev}"
APP="build/$APP_NAME.app"

echo "▸ Compiling (release)…"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"     # redraw it any time with: swift tools/make-app-icon.swift Resources

# Why this matters: macOS ties the Accessibility / Input Monitoring / Screen Recording permissions
# to the app's code signature. An ad-hoc signature ("-") changes on EVERY build, so you would have to
# re-grant everything each time. A stable self-made identity keeps the permissions across rebuilds.
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "▸ Signing with identity: $IDENTITY"
    codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    echo "⚠️  Signing identity \"$IDENTITY\" not found: using an ad-hoc signature."
    echo "   Permissions will RESET after every rebuild. Fix: run ./tools/create-signing-identity.sh once."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/   /'
echo "✓ Built $APP"

if [[ "${1:-}" == "run" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    open "$APP"
fi

if [[ "${1:-}" == "install" ]]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    sleep 0.5
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$APP_NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "✓ Installed to ~/Applications/$APP_NAME.app"
    open "$HOME/Applications/$APP_NAME.app"
fi
