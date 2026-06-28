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
# archive step: it feeds DEVELOPMENT_TEAM so the Swift package dependencies
# (swift-crypto, swift-secp256k1) resolve a team, or the archive fails with:
# 'Signing for "swift-crypto_Crypto" requires a development team.' The archive + export
# use AUTOMATIC signing (not Manual): the keychain-access-groups entitlement (added by the
# keychain-consolidation work) is profile-restricted, and under CODE_SIGN_STYLE=Manual
# Xcode refuses to mint a profile even with -allowProvisioningUpdates ("Huginn requires a
# provisioning profile"). Automatic + -allowProvisioningUpdates creates the Developer ID
# "Mac Team Direct" profile the entitlement needs; the export re-signs Developer ID.
: "${APPLE_ID:?set APPLE_ID (your Apple ID email)}"
: "${APP_PASSWORD:?set APP_PASSWORD (app-specific password from appleid.apple.com)}"
: "${TEAM_ID:?set TEAM_ID (your 10-char Apple Developer Team ID)}"

# Build with Xcode 27: the PCC symbols ELDR_PCC_SDK compiles
# (PrivateCloudComputeLanguageModel, ContextOptions) are ABSENT from the Xcode 26.x SDK,
# so archiving under the default toolchain fails with "cannot find type … in scope".
# Default DEVELOPER_DIR to the beta if it's installed and the caller didn't set one.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d "/Applications/Xcode-beta.app" ]; then
  export DEVELOPER_DIR="/Applications/Xcode-beta.app/Contents/Developer"
fi
echo "==> Toolchain: $(xcodebuild -version 2>/dev/null | head -1) (DEVELOPER_DIR=${DEVELOPER_DIR:-default})"

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
  CODE_SIGN_STYLE=Automatic \
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
    <string>automatic</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -allowProvisioningUpdates

APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: exported app not found at $APP" >&2; exit 1; }

echo "==> [2.25/7] Building + bundling the eldr-node headless daemon"
# The conduit installer (eldrctl) ships THIS binary to remote Macs. Bundle it inside
# Huginn.app so the signed/notarized DMG is the single source of the node binary;
# eldrctl extracts it from the installed app. Built release with the same beta toolchain.
ELDR_NODE_PKG="$(cd ../../Packages/EldrNode && pwd)"
swift build -c release --package-path "$ELDR_NODE_PKG" --product eldr-node
ELDR_NODE_SRC="$(swift build -c release --package-path "$ELDR_NODE_PKG" --show-bin-path)/eldr-node"
[ -f "$ELDR_NODE_SRC" ] || { echo "error: eldr-node not built at $ELDR_NODE_SRC" >&2; exit 1; }
cp "$ELDR_NODE_SRC" "$APP/Contents/Resources/eldr-node"

echo "==> [2.5/7] Signing the bundled eldr-acp + eldr-node CLIs + re-sealing the app"
# The "Build and bundle eldr-acp" Xcode phase copies the CLI in ad-hoc/linker-signed
# (Signature=adhoc, no team, no hardened runtime). Notarization rejects ANY nested
# Mach-O that isn't Developer-ID + hardened-runtime signed, so sign it, then re-seal
# the app around it (inside-out) preserving the unsandboxed entitlement. The verify
# fails the build loudly here rather than wasting a notarization round-trip.
ELDR_ACP_BIN="$APP/Contents/Resources/eldr-acp"
ELDR_NODE_BIN="$APP/Contents/Resources/eldr-node"
if [ -f "$ELDR_ACP_BIN" ]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$ELDR_ACP_BIN"
  # eldr-node carries its own keychain-access-groups entitlement so the headless node's
  # secrets use the data-protection keychain (shared team-scoped group with Huginn).
  # The raw .entitlements file holds the literal build variable $(AppIdentifierPrefix),
  # which xcodebuild expands but codesign does NOT — signing the node with the raw file
  # would bake the literal group "$(AppIdentifierPrefix)chat.eldr.shared" and break the
  # data-protection keychain (errSecMissingEntitlement -34018). Expand it to the team id
  # ($(AppIdentifierPrefix) -> "<TEAM_ID>.") into a temp entitlements file first. The file
  # is then run through plutil to STRIP the XML comment: codesign's entitlements parser
  # (AMFIUnserializeXML) is stricter than libxml and rejects comments with
  # "AMFIUnserializeXML: syntax error near line N"; plutil re-serializes canonically,
  # dropping comments while preserving the keychain-access-groups value.
  if [ -f "$ELDR_NODE_BIN" ]; then
    NODE_ENT="$BUILD_DIR/eldr-node.expanded.entitlements"
    sed "s/\$(AppIdentifierPrefix)/${TEAM_ID}./g" "eldr-node.entitlements" \
      | plutil -convert xml1 -o "$NODE_ENT" -
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
      --entitlements "$NODE_ENT" "$ELDR_NODE_BIN"
  fi
  # Re-seal the outer app around the freshly-signed nested CLIs. Re-apply the ALREADY
  # BAKED entitlements (extracted from the exported app) rather than the raw source file:
  # the export expanded $(AppIdentifierPrefix) AND injected com.apple.application-identifier
  # from the provisioning profile. Signing with the raw Huginn.entitlements would drop the
  # application-identifier and re-introduce the literal variable, breaking the keychain.
  APP_ENT="$BUILD_DIR/huginn.expanded.entitlements"
  codesign -d --entitlements "$APP_ENT" --xml "$APP"
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" \
    --entitlements "$APP_ENT" "$APP"
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

echo "==> [7/9] Signing the DMG"
codesign --sign "$DEVELOPER_ID" --timestamp "$FINAL_DMG"

echo "==> [8/9] Notarizing the DMG (submit + wait)"
# The .app inside is already notarized + stapled, but Gatekeeper also checks the DMG
# itself — an un-notarized DMG is REJECTED ("Unnotarized Developer ID") on a recipient's
# Mac. Notarize + staple the DMG so it opens cleanly, even offline (B3).
xcrun notarytool submit "$FINAL_DMG" \
  --apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$TEAM_ID" \
  --wait

echo "==> [9/9] Stapling + verifying the DMG"
xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl -a -t open --context context:primary-signature "$FINAL_DMG"

echo ""
echo "Done (notarized + stapled): $FINAL_DMG"
