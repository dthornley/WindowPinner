#!/bin/bash
# Builds, signs, and optionally notarizes/installs/packages WindowPinner.app.
#
#   ./build.sh              build + sign into ./dist
#   ./build.sh install      ... and copy to /Applications, then launch
#   ./build.sh notarize     ... and notarize + staple (needs one-time setup:
#                           xcrun notarytool store-credentials "WindowPinner")
#   ./build.sh dmg          ... notarize the app, then build, sign, notarize,
#                           and staple a drag-to-install DMG
#
# Signing: uses the "Developer ID Application" identity from the keychain if
# present (stable signature -> Accessibility permission survives rebuilds),
# otherwise falls back to ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.2"
BUILD="3"
NOTARY_PROFILE="WindowPinner"

echo "==> Building (release)..."
swift build -c release

APP=dist/WindowPinner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp .build/release/WindowPinner "$APP/Contents/MacOS/WindowPinner"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>WindowPinner</string>
    <key>CFBundleIdentifier</key>       <string>com.darnt.WindowPinner</string>
    <key>CFBundleName</key>             <string>WindowPinner</string>
    <key>CFBundleDisplayName</key>      <string>WindowPinner</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>          <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true

if [[ -n "${IDENTITY:-}" ]]; then
    echo "==> Signing with: $IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "==> No Developer ID identity found; ad-hoc signing"
    codesign --force --sign - "$APP"
fi

codesign --verify --strict "$APP"
echo "==> Built $APP"

notarize_file() { # <file>
    if ! xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait; then
        cat >&2 <<EOF

Notarization failed. If the profile is missing, set it up once with:
    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id <your-apple-id> --team-id EBV6EGPQJ9
(you'll be prompted for an app-specific password from appleid.apple.com)
EOF
        exit 1
    fi
}

notarize_app() {
    if [[ -z "${IDENTITY:-}" ]]; then
        echo "ERROR: notarization requires a Developer ID signature." >&2
        exit 1
    fi
    ZIP=dist/WindowPinner.zip
    echo "==> Submitting app for notarization (profile: $NOTARY_PROFILE)..."
    ditto -c -k --keepParent "$APP" "$ZIP"
    notarize_file "$ZIP"
    echo "==> Stapling app..."
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip with ticket for distribution
    echo "==> Notarized. Distributable zip: $ZIP"
}

case "${1:-}" in
notarize)
    notarize_app
    ;;
dmg)
    notarize_app
    DMG="dist/WindowPinner-${VERSION}.dmg"
    STAGING=dist/dmg-staging
    echo "==> Building DMG..."
    rm -rf "$STAGING" "$DMG"
    mkdir -p "$STAGING"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "WindowPinner" -srcfolder "$STAGING" \
        -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGING"
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    echo "==> Submitting DMG for notarization..."
    notarize_file "$DMG"
    xcrun stapler staple "$DMG"
    echo "==> Notarized DMG: $DMG"
    ;;
install)
    echo "==> Installing to /Applications..."
    osascript -e 'quit app "WindowPinner"' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/WindowPinner.app
    cp -R "$APP" /Applications/
    open /Applications/WindowPinner.app
    echo "==> Launched. Grant Accessibility permission when prompted."
    ;;
esac
