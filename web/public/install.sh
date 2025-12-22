#!/bin/bash

# Local Whisper - Easy Installer
# This script removes macOS quarantine attributes to allow the app to run

APP_NAME="LocalWhisper"
DMG_PATH="$HOME/Downloads/LocalWhisper.dmg"
APP_PATH="/Applications/${APP_NAME}.app"
MOUNT_POINT="/Volumes/${APP_NAME} Installer"

echo "🎙️  Local Whisper Easy Installer"
echo "================================"
echo ""

# Check if the DMG exists
if [ ! -f "$DMG_PATH" ]; then
    echo "📥 Downloading Local Whisper..."
    curl -L -o "$DMG_PATH" "https://localwhisper.app/LocalWhisper.dmg"
    if [ $? -ne 0 ]; then
        echo "❌ Download failed. Please download manually from https://localwhisper.app"
        exit 1
    fi
fi

# Mount the DMG
echo "📦 Mounting disk image..."
hdiutil attach "$DMG_PATH" -nobrowse -quiet

# Check if mount was successful
if [ ! -d "$MOUNT_POINT" ]; then
    echo "❌ Could not mount the disk image."
    exit 1
fi

# Remove existing app if present
if [ -d "$APP_PATH" ]; then
    echo "🗑️  Removing old version..."
    rm -rf "$APP_PATH"
fi

# Copy app to Applications
echo "📂 Installing to Applications folder..."
cp -R "$MOUNT_POINT/${APP_NAME}.app" /Applications/

# Unmount the DMG
echo "💿 Cleaning up..."
hdiutil detach "$MOUNT_POINT" -quiet

# Remove quarantine attribute (this is the key step!)
echo "🔓 Removing security restrictions..."
xattr -cr "$APP_PATH"

echo ""
echo "✅ Installation complete!"
echo ""
echo "🚀 Launching Local Whisper..."
open "$APP_PATH"

echo ""
echo "💡 Tip: The app will ask for Microphone and Accessibility permissions."
echo "   Please grant them in System Settings when prompted."
echo ""
