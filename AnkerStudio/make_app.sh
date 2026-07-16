#!/bin/bash
#
# make_app.sh -- build, bundle, sign, notarize, and package the app for distribution.
#
# Pipeline:  xcodebuild -> assemble .app -> dylibbundler -> codesign -> notarize -> DMG
#
# One-time prerequisites:
#   brew install dylibbundler openssl@3 xz zstd jansson      # build + bundle deps
#   Create a "Developer ID Application" cert in Xcode (Settings > Accounts > Manage Certs).
#   Save notarization creds once:
#     xcrun notarytool store-credentials "notary" \
#         --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Usage:
#   ./make_app.sh                       # full: Release build, sign, notarize, DMG
#   DEV_ID="" ./make_app.sh             # UNSIGNED bundle to test-run locally (no notarize/dmg auth)
#   DO_BUILD=0 ./make_app.sh            # bundle the existing build without rebuilding
#   CONFIG=Debug DO_NOTARIZE=0 DO_DMG=0 DEV_ID="" ./make_app.sh   # quick local bundle
#
set -euo pipefail

# ============================ EDIT THESE ============================
APP_NAME="AnkerMake M5 ARM Sender"
BUNDLE_ID="com.bobbyb.ankermake-m5-arm-sender"     # must NOT be com.anker.*
VERSION="0.1.0"

# Your "Developer ID Application" identity, e.g.:
#   DEV_ID="Developer ID Application: Jane Doe (AB12CD34EF)"
# Find it with:  security find-identity -v -p codesigning
# Leave EMPTY to produce an unsigned bundle (local testing only).
DEV_ID="${DEV_ID-Developer ID Application: YOUR NAME (TEAMID)}"

NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"   # xcrun notarytool keychain profile name
# ===================================================================

CONFIG="${CONFIG:-Release}"        # Release (ship) | Debug (quick test)
DO_BUILD="${DO_BUILD:-1}"          # 0 = skip xcodebuild, bundle existing build
DO_NOTARIZE="${DO_NOTARIZE:-1}"    # 0 = sign but don't notarize
DO_DMG="${DO_DMG:-1}"              # 0 = don't build a DMG

HERE="$(cd "$(dirname "$0")" && pwd)"
PROJ="$HERE/build_xcode/eufyStudio.xcodeproj"
BINDIR="$HERE/build_xcode/src/$CONFIG"
ENTITLEMENTS="$HERE/src/platform/osx/entitlements.plist"
ICON="$HERE/resources/icons/eufyStudio.icns"
DIST="$HERE/dist"
APP="$DIST/$APP_NAME.app"

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
signing=1; [[ -z "$DEV_ID" || "$DEV_ID" == *"YOUR NAME"* ]] && signing=0

command -v dylibbundler >/dev/null || { echo "missing: brew install dylibbundler"; exit 1; }

# ---------------------------------------------------------------- 1. build
if [ "$DO_BUILD" = 1 ]; then
    log "Building eufyStudio ($CONFIG)"
    xcodebuild -project "$PROJ" -target eufyStudio -configuration "$CONFIG" -jobs 8 \
        > /tmp/make_app_build.log 2>&1 || { tail -30 /tmp/make_app_build.log; exit 1; }
fi
BIN="$BINDIR/eufyStudio"
LIB="$BINDIR/libAnkerNet.dylib"
[ -f "$BIN" ] || { echo "missing binary: $BIN (build first)"; exit 1; }
[ -f "$LIB" ] || { echo "missing plugin: $LIB (build first)"; exit 1; }

# ---------------------------------------------------------------- 2. assemble
log "Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/eufyStudio"
cp "$LIB" "$APP/Contents/Frameworks/libAnkerNet.dylib"   # loader expects it in Frameworks/
log "Copying resources (~123 MB)"
ditto "$HERE/resources" "$APP/Contents/Resources"
cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>        <string>eufyStudio</string>
  <key>CFBundleName</key>              <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key>           <string>$VERSION</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key>    <string>11.0</string>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------- 3. bundle dylibs
log "Gathering dependent dylibs + fixing load paths (dylibbundler)"
dylibbundler -of -b \
    -x "$APP/Contents/MacOS/eufyStudio" \
    -x "$APP/Contents/Frameworks/libAnkerNet.dylib" \
    -d "$APP/Contents/Frameworks/" \
    -p "@executable_path/../Frameworks/"

# ---------------------------------------------------------------- 4. sign
if [ "$signing" = 1 ]; then
    log "Signing (Developer ID + hardened runtime)"
    # inside-out: every nested dylib first, then the app
    find "$APP/Contents/Frameworks" -name "*.dylib" -print0 | while IFS= read -r -d '' d; do
        codesign --force --timestamp --options runtime --sign "$DEV_ID" "$d"
    done
    codesign --force --timestamp --options runtime \
        --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    log "Gatekeeper assessment:"; spctl -a -vvv --type execute "$APP" 2>&1 | head -3 || true
else
    log "No DEV_ID set -> UNSIGNED bundle (run locally only; can't notarize/distribute)"
    DO_NOTARIZE=0
fi

# ---------------------------------------------------------------- 5. notarize + staple
if [ "$signing" = 1 ] && [ "$DO_NOTARIZE" = 1 ]; then
    log "Notarizing the app"
    ZIP="$DIST/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
fi

# ---------------------------------------------------------------- 6. DMG
if [ "$DO_DMG" = 1 ]; then
    log "Building DMG"
    STAGE="$DIST/dmg_stage"; DMG="$DIST/${APP_NAME// /_}-$VERSION.dmg"
    rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/$APP_NAME.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
    rm -rf "$STAGE"
    if [ "$signing" = 1 ]; then
        codesign --force --timestamp --sign "$DEV_ID" "$DMG"
        [ "$DO_NOTARIZE" = 1 ] && { xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; xcrun stapler staple "$DMG"; }
    fi
    log "DMG ready: $DMG"
fi

log "Done. Bundle: $APP"
