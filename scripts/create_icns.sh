#!/bin/bash

SOURCE="icon.png"
ICONSET="AppIcon.iconset"
DEST="swift/WhisperMac/AppIcon.icns"

if [ ! -f "$SOURCE" ]; then
    echo "❌ icon.png not found!"
    exit 1
fi

echo "🎨 Creating iconset..."
mkdir -p "$ICONSET"

# Resize images
sips -s format png -z 16 16     "$SOURCE" --out "${ICONSET}/icon_16x16.png" > /dev/null
sips -s format png -z 32 32     "$SOURCE" --out "${ICONSET}/icon_16x16@2x.png" > /dev/null
sips -s format png -z 32 32     "$SOURCE" --out "${ICONSET}/icon_32x32.png" > /dev/null
sips -s format png -z 64 64     "$SOURCE" --out "${ICONSET}/icon_32x32@2x.png" > /dev/null
sips -s format png -z 128 128   "$SOURCE" --out "${ICONSET}/icon_128x128.png" > /dev/null
sips -s format png -z 256 256   "$SOURCE" --out "${ICONSET}/icon_128x128@2x.png" > /dev/null
sips -s format png -z 256 256   "$SOURCE" --out "${ICONSET}/icon_256x256.png" > /dev/null
sips -s format png -z 512 512   "$SOURCE" --out "${ICONSET}/icon_256x256@2x.png" > /dev/null
sips -s format png -z 512 512   "$SOURCE" --out "${ICONSET}/icon_512x512.png" > /dev/null
sips -s format png -z 1024 1024 "$SOURCE" --out "${ICONSET}/icon_512x512@2x.png" > /dev/null

echo "📦 Converting to .icns..."
iconutil -c icns "$ICONSET" -o "$DEST"

echo "🧹 Cleaning up..."
rm -rf "$ICONSET"

echo "✅ Created $DEST"
