#!/bin/bash
# Build a signed, notarized release PKG installer.
# PKG is preferred over DMG for apps with system extensions because the
# installer places the app in /Applications directly, which is required
# for system extension approval.
#
# Required env vars:
#   ASC_KEY_P8_PATH  — path to App Store Connect .p8 key file
#   ASC_KEY_ID       — App Store Connect key ID
#   ASC_ISSUER_ID    — App Store Connect issuer ID
set -e

PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
APP_NAME="BaoLianDeng"
SCHEME="BaoLianDeng"
ARCHIVE_PATH="/tmp/${APP_NAME}.xcarchive"
EXPORT_PATH="/tmp/${APP_NAME}-export"
EXPORT_PLIST="/tmp/${APP_NAME}-ExportOptions.plist"
COMPONENT_PLIST="/tmp/${APP_NAME}-component.plist"
COMPONENT_PKG="/tmp/${APP_NAME}-component.pkg"

cd "$PROJECT_DIR"

: "${ASC_KEY_P8_PATH:?Set ASC_KEY_P8_PATH to your App Store Connect .p8 key file}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer ID}"

TEAM_ID=$(grep DEVELOPMENT_TEAM Local.xcconfig | head -1 | awk -F= '{gsub(/[ \t]/, "", $2); print $2}')
INSTALLER_CERT=$(security find-identity -v -p basic | grep "Developer ID Installer" | head -1 | awk -F'"' '{print $2}')

echo "=== Step 0: Bump Release build number ==="
# Touches only the Release XCBuildConfiguration blocks. Debug is left alone so
# dev iterations don't perturb the App Store version stream.
"$PROJECT_DIR/scripts/bump-build.sh" release

# Read Release-only build settings AFTER the bump so the banner and PKG_PATH
# reflect the version being shipped.
VERSION=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/MARKETING_VERSION/ { print $3; exit }')
BUILD=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/CURRENT_PROJECT_VERSION/ { print $3; exit }')
PKG_PATH="/tmp/${APP_NAME}-${VERSION}.pkg"

echo "=== Building ${APP_NAME} v${VERSION} (${BUILD}) PKG ==="

echo "=== Step 1: Build framework ==="
make framework

echo "=== Step 2: Archive ==="
# Developer ID distribution requires the -systemextension variant of the
# Network Extension entitlement (development and App Store profiles only
# carry the unsuffixed value).
xcodebuild archive \
  -project ${APP_NAME}.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  NE_PROVIDER_SUFFIX="-systemextension" \
  | tail -3

echo "=== Step 2b: Prune app extension (Developer ID ships the sysext) ==="
# Both provider packagings are embedded during the build. App extensions are
# App Store-only (TN3134), so Developer ID builds ship only the system
# extension. exportArchive re-signs the app, giving the pruned bundle a
# fresh seal.
APP_IN_ARCHIVE="${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app"
rm -rf "${APP_IN_ARCHIVE}/Contents/PlugIns/TransparentProxy.appex"
if [ ! -d "${APP_IN_ARCHIVE}/Contents/Library/SystemExtensions" ]; then
  echo "ERROR: system extension missing from archive"
  exit 1
fi

echo "=== Step 3: Export with Developer ID ==="
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>io.github.baoliandeng.macos</key>
        <string>BaoLianDeng macOS Developer ID</string>
        <key>io.github.baoliandeng.macos.TransparentProxy</key>
        <string>io.github.baoliandeng.macos.TransparentProxy</string>
    </dict>
</dict>
</plist>
PLIST

rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | tail -3

APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: ${APP_PATH} not found after export"
  exit 1
fi

codesign --verify --deep --strict "$APP_PATH"
echo "Signature OK"

echo "=== Step 4: Notarize app ==="
APP_ZIP="/tmp/${APP_NAME}-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

xcrun notarytool submit "$APP_ZIP" \
  --key "$ASC_KEY_P8_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait

echo "Stapling app..."
xcrun stapler staple "$APP_PATH"
rm -f "$APP_ZIP"

echo "=== Step 5: Build PKG ==="
# Generate component plist to customize install location
pkgbuild --analyze --root "$EXPORT_PATH" "$COMPONENT_PLIST"

# Patch component plist: install to /Applications, don't relocate
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

# Build component package (unsigned intermediate)
# --scripts points to scripts/ which contains a preinstall script
# that removes any existing installation before the new one is laid down.
SCRIPTS_DIR="${PROJECT_DIR}/scripts"
pkgbuild \
  --root "$EXPORT_PATH" \
  --component-plist "$COMPONENT_PLIST" \
  --install-location /Applications \
  --scripts "$SCRIPTS_DIR" \
  --identifier "io.github.baoliandeng.macos.pkg" \
  --version "$VERSION" \
  "$COMPONENT_PKG"

# Create Distribution.xml for productbuild
DIST_XML="/tmp/${APP_NAME}-Distribution.xml"
cat > "$DIST_XML" <<DIST
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${APP_NAME}</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="14.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="${APP_NAME}.pkg"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${APP_NAME}.pkg" visible="false">
        <pkg-ref id="io.github.baoliandeng.macos.pkg"/>
    </choice>
    <pkg-ref id="io.github.baoliandeng.macos.pkg" version="${VERSION}" onConclusion="none">${APP_NAME}-component.pkg</pkg-ref>
</installer-gui-script>
DIST

# Build signed product archive
rm -f "$PKG_PATH"
productbuild \
  --distribution "$DIST_XML" \
  --package-path "/tmp" \
  --resources "$PROJECT_DIR/scripts" \
  --sign "${INSTALLER_CERT}" \
  "$PKG_PATH"

rm -f "$COMPONENT_PKG" "$COMPONENT_PLIST" "$DIST_XML"

echo "=== Step 6: Notarize PKG ==="
xcrun notarytool submit "$PKG_PATH" \
  --key "$ASC_KEY_P8_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait

echo "Stapling PKG..."
xcrun stapler staple "$PKG_PATH"

PKG_SIZE=$(du -h "$PKG_PATH" | cut -f1)
echo ""
echo "=== Done ==="
echo "PKG: ${PKG_PATH} (${PKG_SIZE})"
echo "Version: ${VERSION} (${BUILD})"
