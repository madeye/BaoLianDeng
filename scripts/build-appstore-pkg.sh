#!/bin/bash
# Build a Mac App Store PKG for upload to App Store Connect.
#
# Differences from the Developer ID build (build-release-pkg.sh):
#   - Network Extension entitlement uses the App Store variant
#     ("app-proxy-provider", no "-systemextension" suffix) via
#     NE_PROVIDER_SUFFIX="" override.
#   - Signs with Apple Distribution + Mac App Store provisioning profiles
#     (cloud signing via the App Store Connect API key, automatic style).
#   - Exports with the app-store-connect method, which produces an installer
#     PKG signed for App Store submission. No notarization needed.
#
# Auth: ASC_API_KEY_PATH must point to an App Store Connect API key config
# (JSON with key_id, issuer_id, key — same format fastlane uses). Defaults to
# the value in the gitignored fastlane/.env.
#
# Optional env vars:
#   APPSTORE_TEAM_ID — overrides DEVELOPMENT_TEAM from Local.xcconfig
#   SKIP_BUMP=1      — don't bump the Release build number
set -e

PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
APP_NAME="BaoLianDeng"
SCHEME="BaoLianDeng"
ARCHIVE_PATH="/tmp/${APP_NAME}-appstore.xcarchive"
EXPORT_PATH="/tmp/${APP_NAME}-appstore-export"
EXPORT_PLIST="/tmp/${APP_NAME}-appstore-ExportOptions.plist"

cd "$PROJECT_DIR"

if [ -z "${ASC_API_KEY_PATH:-}" ] && [ -f fastlane/.env ]; then
  # shellcheck disable=SC1091
  source fastlane/.env
fi
: "${ASC_API_KEY_PATH:?Set ASC_API_KEY_PATH to your App Store Connect API key JSON (key_id, issuer_id, key)}"

ASC_KEY_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['key_id'])" "$ASC_API_KEY_PATH")
ASC_ISSUER_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['issuer_id'])" "$ASC_API_KEY_PATH")
ASC_KEY_P8_PATH=$(mktemp /tmp/AuthKey_${ASC_KEY_ID}.XXXXXX.p8)
trap 'rm -f "$ASC_KEY_P8_PATH"' EXIT
python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['key'])" "$ASC_API_KEY_PATH" > "$ASC_KEY_P8_PATH"

TEAM_ID="${APPSTORE_TEAM_ID:-$(grep DEVELOPMENT_TEAM Local.xcconfig | head -1 | awk -F= '{gsub(/[ \t]/, "", $2); print $2}')}"

if [ -z "${SKIP_BUMP:-}" ]; then
  echo "=== Step 0: Bump Release build number ==="
  "$PROJECT_DIR/scripts/bump-build.sh" release
fi

VERSION=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/MARKETING_VERSION/ { print $3; exit }')
BUILD=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/CURRENT_PROJECT_VERSION/ { print $3; exit }')
PKG_PATH="${EXPORT_PATH}/${APP_NAME}.pkg"

echo "=== Building ${APP_NAME} v${VERSION} (${BUILD}) for the Mac App Store (team ${TEAM_ID}) ==="

echo "=== Step 1: Build framework ==="
make framework

echo "=== Step 2: Archive (App Store signing) ==="
xcodebuild archive \
  -project ${APP_NAME}.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_P8_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  NE_PROVIDER_SUFFIX="" \
  | tail -3

echo "=== Step 3: Export App Store PKG ==="
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>destination</key>
    <string>export</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>automatic</string>
</dict>
</plist>
PLIST

rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_P8_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  | tail -3

if [ ! -f "$PKG_PATH" ]; then
  echo "ERROR: ${PKG_PATH} not found after export"
  exit 1
fi

echo "=== Step 4: Verify entitlements ==="
# The App Store build must NOT carry the -systemextension suffix.
APP_IN_ARCHIVE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
if codesign -d --entitlements - "$APP_IN_ARCHIVE" 2>/dev/null | grep -q "app-proxy-provider-systemextension"; then
  echo "ERROR: archive still has the -systemextension entitlement variant"
  exit 1
fi
echo "Entitlements OK (app-proxy-provider, App Store variant)"

echo "=== Step 5: Validate with App Store Connect ==="
# altool needs the .p8 in ~/.private_keys.
mkdir -p ~/.private_keys
cp "$ASC_KEY_P8_PATH" ~/.private_keys/AuthKey_${ASC_KEY_ID}.p8
xcrun altool --validate-app -f "$PKG_PATH" -t macos \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

PKG_SIZE=$(du -h "$PKG_PATH" | cut -f1)
echo ""
echo "=== Done ==="
echo "PKG: ${PKG_PATH} (${PKG_SIZE})"
echo "Version: ${VERSION} (${BUILD})"
echo ""
echo "Upload with:"
echo "  xcrun altool --upload-app -f \"$PKG_PATH\" -t macos --apiKey \"$ASC_KEY_ID\" --apiIssuer \"$ASC_ISSUER_ID\""
