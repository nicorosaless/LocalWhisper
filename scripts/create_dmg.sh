#!/bin/bash
set -e

APP_NAME="LocalWhisper"
VOLNAME="LocalWhisper"
DMG_NAME="LocalWhisper.dmg"
SRC_FOLDER="build/${APP_NAME}.app"
DMG_FINAL="build/${DMG_NAME}"
STAGING_DIR="build/dmg_temp"
TEMP_DMG="build/pack.temp.dmg"

# Ensure we have a fresh build
if [ ! -d "${SRC_FOLDER}" ]; then
    echo "❌ ${SRC_FOLDER} not found! Please run ./build_app.sh first."
    exit 1
fi

echo "📦 Preparing staging area..."
rm -rf "$STAGING_DIR" "$DMG_FINAL" "$TEMP_DMG"
mkdir -p "$STAGING_DIR"

# Copy App
cp -R "build/${APP_NAME}.app" "$STAGING_DIR/"

# Create /Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Remove quarantine and extended attributes
xattr -cr "$STAGING_DIR/${APP_NAME}.app"

echo "💿 Creating temporary disk image..."
# Create a read-write DMG
hdiutil create -srcfolder "$STAGING_DIR" -volname "$VOLNAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW "$TEMP_DMG" -quiet

echo "🎨 Applying layout with AppleScript..."
# Mount the temporary DMG
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG" | grep "^/dev/" | awk 'NR==1{print $1}')
sleep 2

# AppleScript to set view options and icon positions
echo '
   tell application "Finder"
     tell disk "'${VOLNAME}'"
           open
           set current view of container window to icon view
           set toolbar visible of container window to false
           set statusbar visible of container window to false
           set the bounds of container window to {400, 100, 900, 430}
           
           set theViewOptions to the icon view options of container window
           set arrangement of theViewOptions to not arranged
           set icon size of theViewOptions to 100
           
           # Try positioning by name, then by index as fallback
           try
               set position of item "'${APP_NAME}'.app" of container window to {160, 160}
               set position of item "Applications" of container window to {400, 160}
           on error
               try
                   set position of item 1 of container window to {160, 160}
                   set position of item 2 of container window to {400, 160}
               end try
           end try
           
           close
           open
           update without registering applications
           delay 2
     end tell
   end tell
' | osascript

# Give it a moment to sync
sleep 4

# Unmount
echo "💾 Finalizing..."
hdiutil detach "$DEVICE" -force -quiet 
sleep 2

echo "📀 Compressing DMG..."
hdiutil convert "$TEMP_DMG" -format UDZO -o "$DMG_FINAL" -quiet
rm -f "$TEMP_DMG"
rm -rf "$STAGING_DIR"

echo "✅ Created $DMG_FINAL"

# Sync with Web
echo "🌐 Syncing with web folder..."
if [ -d "web/public" ]; then
    cp "$DMG_FINAL" "web/public/LocalWhisper.dmg"
    echo "✅ Web DMG updated!"
else
    echo "⚠️  web/public directory not found. Skipping sync."
fi
