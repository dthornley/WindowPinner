#!/bin/bash
# Builds, signs, and optionally notarizes/installs/packages WindowPinner.app.
#
#   ./build.sh              build + sign into ./dist
#   ./build.sh install      ... and copy to /Applications, then launch
#   ./build.sh notarize     ... and notarize + staple (needs one-time setup:
#                           xcrun notarytool store-credentials "WindowPinner")
#   ./build.sh dmg          ... notarize the app, then build, sign, notarize,
#                           and staple a drag-to-install DMG
#   ./build.sh release      ... all of the above, then sign the update zip,
#                           write the Sparkle appcast, tag, and publish the
#                           GitHub release the in-app updater reads
#
# Updates: the app embeds Sparkle and reads SUFeedURL (the appcast attached to
# the latest GitHub release). Archives are signed with the EdDSA key that
# `generate_keys` stored in the login keychain; the matching public key is
# SPARKLE_PUBLIC_KEY below. Back that private key up (`generate_keys -x file`):
# without it no future release can be installed by the updater. Sparkle
# compares CFBundleVersion, so BUILD must increase with every release.
#
# Signing: uses the "Developer ID Application" identity from the keychain if
# present (stable signature -> Accessibility permission survives rebuilds),
# otherwise falls back to ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-}"

VERSION="1.8"
BUILD="9"
NOTARY_PROFILE="WindowPinner"
REPO="dthornley/WindowPinner"
SPARKLE_PUBLIC_KEY="jxIITcWdGi/64U0fgeBT8QsAcKT66gGXkvZBS8mfQ/M="
SPARKLE_FEED_URL="https://github.com/${REPO}/releases/latest/download/appcast.xml"
TAG="v${VERSION}"

# Cheap preconditions first, so a release does not fail after minutes of
# building and notarizing.
if [[ "$MODE" == release ]]; then
    gh auth status >/dev/null 2>&1 || { echo "gh is not logged in" >&2; exit 1; }
    if [[ -n "$(git status --porcelain)" ]]; then echo "working tree is not clean; commit first" >&2; exit 1; fi
    git fetch -q origin
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
       || [[ -n "$(git ls-remote --tags origin "refs/tags/$TAG")" ]]; then
        echo "tag $TAG already exists" >&2; exit 1
    fi
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [[ -n "$(git rev-list "HEAD..origin/$BRANCH" 2>/dev/null)" ]]; then
        echo "$BRANCH is behind origin/$BRANCH; pull first" >&2; exit 1
    fi
fi

echo "==> Building (release)..."
swift build -c release

APP=dist/WindowPinner.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/WindowPinner "$APP/Contents/MacOS/WindowPinner"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Embed Sparkle (SwiftPM links the xcframework but does not copy it).
SPARKLE_DIR=.build/artifacts/sparkle/Sparkle
SPARKLE_FW=$(find "$SPARKLE_DIR/Sparkle.xcframework" -maxdepth 2 -name Sparkle.framework -path "*macos*" | head -1)
[[ -d "$SPARKLE_FW" ]] || { echo "Sparkle.framework not found under $SPARKLE_DIR" >&2; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_FW" "$APP/Contents/Frameworks/"
if ! otool -l "$APP/Contents/MacOS/WindowPinner" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/WindowPinner"
fi

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
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>          <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>SUFeedURL</key>                <string>${SPARKLE_FEED_URL}</string>
    <key>SUPublicEDKey</key>            <string>${SPARKLE_PUBLIC_KEY}</string>
    <key>SUEnableAutomaticChecks</key>  <true/>
    <key>SUScheduledCheckInterval</key> <integer>86400</integer>
</dict>
</plist>
PLIST

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"') || true

# Sparkle's helpers must be signed inside-out before the framework and the app
# (--deep is discouraged); the XPC services keep their own entitlements.
sign_sparkle() { # <codesign flags...>
    local fw="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    local part
    for part in "$fw"/XPCServices/*.xpc "$fw/Autoupdate" "$fw/Updater.app"; do
        [[ -e "$part" ]] || continue
        codesign --force --preserve-metadata=entitlements "$@" "$part"
    done
    codesign --force "$@" "$APP/Contents/Frameworks/Sparkle.framework"
}

if [[ -n "${IDENTITY:-}" ]]; then
    echo "==> Signing with: $IDENTITY"
    sign_sparkle --options runtime --timestamp --sign "$IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    echo "==> No Developer ID identity found; ad-hoc signing"
    sign_sparkle --sign -
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

build_dmg() {
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
}

case "$MODE" in
notarize)
    notarize_app
    ;;
dmg)
    notarize_app
    build_dmg
    ;;
release)
    notarize_app
    build_dmg

    # Sparkle reads one archive per version from a directory and writes the
    # appcast beside it; the zip gets a versioned name so releases never clash.
    OUT=dist/release
    rm -rf "$OUT"; mkdir -p "$OUT"
    UPDATE_ZIP="$OUT/WindowPinner-${VERSION}.zip"
    cp dist/WindowPinner.zip "$UPDATE_ZIP"
    echo "==> Signing the update archive and writing the appcast..."
    "$SPARKLE_DIR/bin/generate_appcast" \
        --download-url-prefix "https://github.com/${REPO}/releases/download/${TAG}/" \
        --link "https://github.com/${REPO}/releases" \
        -o "$OUT/appcast.xml" "$OUT"
    grep -q "sparkle:edSignature" "$OUT/appcast.xml" || { echo "appcast has no EdDSA signature" >&2; exit 1; }

    if [[ -f RELEASE_NOTES.md ]]; then
        NOTES=$(cat RELEASE_NOTES.md)
    else
        # Commit subjects here read "v1.8: what changed"; keep the text, drop
        # the version prefix.
        LAST=$(git describe --tags --abbrev=0 2>/dev/null || true)
        NOTES=$(git log --pretty='- %s' ${LAST:+$LAST..}HEAD | sed -E 's/^- v[0-9][0-9.]*: */- /')
    fi
    [[ -n "$NOTES" ]] || { echo "no release notes: write RELEASE_NOTES.md or commit since $LAST" >&2; exit 1; }

    echo "==> Pushing $BRANCH and tagging $TAG..."
    git push -q origin HEAD
    git tag -a "$TAG" -m "$TAG"
    git push -q origin "$TAG"
    echo "==> Creating GitHub release $TAG..."
    if ! gh release create "$TAG" "$DMG" "$UPDATE_ZIP" "$OUT/appcast.xml" \
        --repo "$REPO" --title "WindowPinner ${VERSION}" --notes "$NOTES"; then
        echo "release creation failed; removing tag $TAG so the run can be repeated" >&2
        git push -q origin ":refs/tags/$TAG" || true
        git tag -d "$TAG" >/dev/null || true
        exit 1
    fi
    echo "==> Done: $(gh release view "$TAG" --repo "$REPO" --json url --jq .url)"
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
