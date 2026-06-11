#!/bin/bash
# Build a signed, notarized release DMG with /Applications shortcut.
# Uses xcodebuild -exportArchive for proper Developer ID signing.
#
# Required env vars:
#   ASC_KEY_P8_PATH  — path to App Store Connect .p8 key file
#   ASC_KEY_ID       — App Store Connect key ID
#   ASC_ISSUER_ID    — App Store Connect issuer ID
set -e

PROJECT_DIR="/Volumes/DATA/workspace/BaoLianDeng"
APP_NAME="BaoLianDeng"
SCHEME="BaoLianDeng"
DMG_DIR="/tmp/${APP_NAME}-dmg"
ARCHIVE_PATH="/tmp/${APP_NAME}.xcarchive"
EXPORT_PATH="/tmp/${APP_NAME}-export"
EXPORT_PLIST="/tmp/${APP_NAME}-ExportOptions.plist"

cd "$PROJECT_DIR"

: "${ASC_KEY_P8_PATH:?Set ASC_KEY_P8_PATH to your App Store Connect .p8 key file}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID to your App Store Connect key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to your App Store Connect issuer ID}"

TEAM_ID=$(grep DEVELOPMENT_TEAM Local.xcconfig | head -1 | awk -F= '{gsub(/[ \t]/, "", $2); print $2}')

echo "=== Step 0: Bump Release build number ==="
# Touches only the Release XCBuildConfiguration blocks. Debug is left alone so
# dev iterations don't perturb the App Store version stream.
"$PROJECT_DIR/scripts/bump-build.sh" release

# Read Release-only build settings AFTER the bump.
VERSION=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/MARKETING_VERSION/ { print $3; exit }')
BUILD=$(xcodebuild -project ${APP_NAME}.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
  | awk '/CURRENT_PROJECT_VERSION/ { print $3; exit }')
DMG_NAME="${APP_NAME}-${VERSION}"
DMG_PATH="/tmp/${DMG_NAME}.dmg"

echo "=== Building ${APP_NAME} v${VERSION} (${BUILD}) ==="

echo "=== Step 1: Build framework ==="
make framework

echo "=== Step 2: Archive ==="
xcodebuild archive \
  -project ${APP_NAME}.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  NE_PROVIDER_SUFFIX="-systemextension" \
  | tail -3

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

echo "=== Step 4: Notarize ==="
APP_ZIP="/tmp/${APP_NAME}-notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"

xcrun notarytool submit "$APP_ZIP" \
  --key "$ASC_KEY_P8_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait

echo "Stapling..."
xcrun stapler staple "$APP_PATH"
rm -f "$APP_ZIP"

echo "=== Step 5: Create DMG ==="
rm -rf "$DMG_DIR" "$DMG_PATH"
RW_DMG="/tmp/${DMG_NAME}-rw.dmg"
rm -f "$RW_DMG"
mkdir -p "$DMG_DIR"

cp -R "$APP_PATH" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"

# Create a read-write DMG first so we can customize the Finder window
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG"

rm -rf "$DMG_DIR"

# Mount the read-write DMG and configure Finder layout
MOUNT_POINT=$(hdiutil attach -readwrite -noverify "$RW_DMG" | grep "/Volumes/" | tail -1 | awk -F'\t' '{print $NF}')
echo "Mounted at: $MOUNT_POINT"

# Copy background image into DMG
mkdir -p "${MOUNT_POINT}/.background"
cp "${PROJECT_DIR}/scripts/dmg-background.png" "${MOUNT_POINT}/.background/dmg-background.png"

# Set Finder window appearance: icon size, background, icon positions
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 640, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set background picture of viewOptions to POSIX file "${MOUNT_POINT}/.background/dmg-background.png"
        set position of item "${APP_NAME}.app" of container window to {120, 150}
        set position of item "Applications" of container window to {420, 150}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

# Set custom volume icon from the app icon
cp "${MOUNT_POINT}/${APP_NAME}.app/Contents/Resources/AppIcon.icns" "${MOUNT_POINT}/.VolumeIcon.icns" 2>/dev/null || true
SetFile -c icnC "${MOUNT_POINT}/.VolumeIcon.icns" 2>/dev/null || true
SetFile -a C "${MOUNT_POINT}" 2>/dev/null || true

# Hide background files
chflags hidden "${MOUNT_POINT}/.VolumeIcon.icns" 2>/dev/null || true

sync
hdiutil detach "$MOUNT_POINT"

# Convert to compressed read-only DMG
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$RW_DMG"

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

echo "=== Step 6: Notarize DMG ==="
xcrun notarytool submit "$DMG_PATH" \
  --key "$ASC_KEY_P8_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait

echo "Stapling DMG..."
xcrun stapler staple "$DMG_PATH"

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "=== Done ==="
echo "DMG: ${DMG_PATH} (${DMG_SIZE})"
echo "Version: ${VERSION} (${BUILD})"
