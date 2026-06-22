#!/bin/zsh
# build-dmg.sh — archive, sign, notarize, and package Huginn as a DMG.
#
# PREREQUISITES (NOT part of CI — requires a paid Apple Developer account):
#   • A "Developer ID Application" signing certificate in your login keychain.
#   • Xcode command-line tools (xcodebuild, xcrun, hdiutil, codesign, notarytool).
#   • These environment variables for notarization:
#       APPLE_ID    — your Apple ID email
#       APP_PASSWORD— an app-specific password (appleid.apple.com ▸ Sign-In & Security)
#       TEAM_ID     — your 10-char Apple Developer Team ID
#   • DEVELOPER_ID  — optional; the signing identity name. Defaults to
#                     "Developer ID Application" (matched against your keychain).
#
# Output: dist/Huginn-<version>.dmg  (signed, notarized, stapled)
#
# This step is intentionally separate from the normal build: the app itself builds
# and runs from Xcode with no certificates. Only distribution needs the above.

set -euo pipefail

cd "$(dirname "$0")"
PROJECT="Huginn.xcodeproj"
SCHEME="Huginn"
APP_NAME="Huginn"
CONFIG="Release"

BUILD_DIR="$(pwd)/.dmgbuild"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST_DIR="$(pwd)/dist"
STAGE="$BUILD_DIR/stage"

DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application}"

# Signing + notarization inputs, validated up front. TEAM_ID is needed as early as the
# archive step: with manual Developer ID signing, the Swift package dependencies
# (swift-crypto, swift-secp256k1) must resolve a development team, or the archive fails
# with: 'Signing for "swift-crypto_Crypto" requires a development team.'
: "${APPLE_ID:?set APPLE_ID (your Apple ID email)}"
: "${APP_PASSWORD:?set APP_PASSWORD (app-specific password from appleid.apple.com)}"
: "${TEAM_ID:?set TEAM_ID (your 10-char Apple Developer Team ID)}"

echo "==> Reading version"
VERSION="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ MARKETING_VERSION / {print $2; exit}')"
VERSION="${VERSION:-0.1.0}"
echo "    version $VERSION"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "==> [1/7] Archiving (Release, Developer ID)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -archivePath "$ARCHIVE" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  -allowProvisioningUpdates

echo "==> [2/7] Exporting the .app"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist"

APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: exported app not found at $APP" >&2; exit 1; }

echo "==> [2.5/7] Signing the bundled eldr-acp CLI + re-sealing the app"
# The "Build and bundle eldr-acp" Xcode phase copies the CLI in ad-hoc/linker-signed
# (Signature=adhoc, no team, no hardened runtime). Notarization rejects ANY nested
# Mach-O that isn't Developer-ID + hardened-runtime signed, so sign it, then re-seal
# the app around it (inside-out) preserving the unsandboxed entitlement. The verify
# fails the build loudly here rather than wasting a notarization round-trip.
ELDR_ACP_BIN="$APP/Contents/Resources/eldr-acp"
if [ -f "$ELDR_ACP_BIN" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$ELDR_ACP_BIN"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
    --entitlements "Huginn.entitlements" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "==> [3/7] Notarizing (submit + wait)"
NOTARY_ZIP="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
  --apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$TEAM_ID" \
  --wait

echo "==> [4/7] Stapling the ticket"
xcrun stapler staple "$APP"

echo "==> [5/7] Building a read/write DMG and staging contents"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
RW_DMG="$BUILD_DIR/$APP_NAME-rw.dmg"
hdiutil create -srcfolder "$STAGE" -volname "$APP_NAME" -fs HFS+ \
  -format UDRW -ov "$RW_DMG"

echo "==> [6/7] Converting to a compressed DMG"
FINAL_DMG="$DIST_DIR/Huginn-$VERSION.dmg"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -ov -o "$FINAL_DMG"

echo "==> [7/7] Signing the DMG"
codesign --sign "$DEVELOPER_ID" --timestamp "$FINAL_DMG"

echo ""
echo "Done: $FINAL_DMG"
