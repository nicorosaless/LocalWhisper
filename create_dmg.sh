#!/bin/bash

APP_NAME="LocalWhisper"
VOL_NAME="${APP_NAME} Installer"
DMG_FINAL="build/LocalWhisper.dmg"
STAGING_DIR="build/dmg_temp"
TEMP_DMG="build/pack.temp.dmg"

# Ensure we have a fresh build
if [ ! -d "build/${APP_NAME}.app" ]; then
    echo "❌ build/${APP_NAME}.app not found! Please run ./build_app.sh first."
    exit 1
fi

echo "📦 Preparing staging area..."
rm -rf "$STAGING_DIR" "$DMG_FINAL" "$TEMP_DMG"
mkdir -p "$STAGING_DIR"

# Copy App
cp -R "build/${APP_NAME}.app" "$STAGING_DIR/"

# Remove quarantine and extended attributes to prevent Gatekeeper issues
xattr -cr "$STAGING_DIR/${APP_NAME}.app"

# Create /Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

echo "💿 Creating temporary disk image..."
hdiutil create -srcfolder "$STAGING_DIR" -volname "$VOL_NAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW "$TEMP_DMG" -quiet

echo "🎨 Applying layout (simplified)..."
# Mount the temporary DMG
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep "^/dev/" | awk 'NR==1{print $1}')
sleep 3

# Set background and icon positions using SetFile (more reliable than AppleScript)
# Just ensure the volume is opened once so macOS creates a basic .DS_Store
open "/Volumes/${VOL_NAME}" 2>/dev/null || true
sleep 2

# Close Finder windows for this volume
osascript -e 'tell application "Finder" to close every window' 2>/dev/null || true

# Unmount
echo "💾 Finalizing..."
hdiutil detach "$DEVICE" -quiet 2>/dev/null || true
sleep 2

echo "📀 Compressing DMG..."
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_FINAL" -quiet
rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"
# 5. Finalize
echo "✅ Created $DMG_FINAL"

# 6. Sync with Web (NEW)
echo "🌐 Syncing with web folder..."
if [ -d "web/public" ]; then
    cp "$DMG_FINAL" "web/public/LocalWhisper.dmg"
    echo "✅ Web DMG updated!"
else
    echo "⚠️  web/public directory not found. Skipping sync."
fi
