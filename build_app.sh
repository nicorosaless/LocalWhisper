#!/bin/bash

# Configuration
APP_NAME="LocalWhisper"
EXECUTABLE_NAME="LocalWhisper"
BUILD_DIR="swift/.build/release"
OUTPUT_DIR="build"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"
ICON_SOURCE="swift/Resources/AppIcon.png"

echo "🚀 Starting build process for ${APP_NAME}..."

# 1. Compile Swift project
echo "🛠️  Compiling Swift project..."
cd swift
swift build -c release
if [ $? -ne 0 ]; then
    echo "❌ Build failed"
    exit 1
fi
cd ..

# 2. Create App Bundle Structure
echo "📂 Creating App Bundle structure..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources/bin"

# 3. Copy Executable
echo "📦 Copying executable..."
cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# 4. Copy Info.plist
echo "📝 Copying Info.plist..."
cp "swift/WhisperMac/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# 5. Copy Resources (whisper-cli & libs)
echo "📦 Bundling resources..."
if [ -f "bin/whisper-cli" ]; then
    cp "bin/whisper-cli" "${APP_BUNDLE}/Contents/Resources/bin/"
    chmod +x "${APP_BUNDLE}/Contents/Resources/bin/whisper-cli"
else
    echo "⚠️  Warning: bin/whisper-cli not found! The app might not work correctly."
fi

# Copy dynamic libraries
mkdir -p "${APP_BUNDLE}/Contents/Resources/lib"
if [ -d "lib" ]; then
    echo "📚 Bundling dynamic libraries..."
    cp lib/*.dylib "${APP_BUNDLE}/Contents/Resources/lib/"
fi

# 6. Generate and Copy App Icon (from PNG)
echo "🎨 Generating App Icon from PNG..."
ICONSET_DIR="${OUTPUT_DIR}/Icon.iconset"
mkdir -p "${ICONSET_DIR}"

if [ -f "${ICON_SOURCE}" ]; then
    sips -z 16 16     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16.png" > /dev/null
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_16x16@2x.png" > /dev/null
    sips -z 32 32     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32.png" > /dev/null
    sips -z 64 64     "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_32x32@2x.png" > /dev/null
    sips -z 128 128   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128.png" > /dev/null
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_128x128@2x.png" > /dev/null
    sips -z 256 256   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256.png" > /dev/null
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_256x256@2x.png" > /dev/null
    sips -z 512 512   "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512.png" > /dev/null
    sips -z 1024 1024 "${ICON_SOURCE}" --out "${ICONSET_DIR}/icon_512x512@2x.png" > /dev/null
    
    iconutil -c icns "${ICONSET_DIR}"
    mv "${OUTPUT_DIR}/Icon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    rm -rf "${ICONSET_DIR}"
    echo "   ✅ Icon generated from ${ICON_SOURCE}"
else
    echo "⚠️  ${ICON_SOURCE} not found! Icon will not be set."
fi

# 7. Ad-hoc Code Signing
echo "🔐 Signing app components..."

# Step 1: Remove existing signatures and quarantine attributes
echo "🧹 Removing existing signatures and quarantine attributes..."
xattr -cr "${APP_BUNDLE}"
find "${APP_BUNDLE}" -name "*.dylib" -exec codesign --remove-signature {} \; 2>/dev/null || true
codesign --remove-signature "${APP_BUNDLE}/Contents/Resources/bin/whisper-cli" 2>/dev/null || true
codesign --remove-signature "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" 2>/dev/null || true

# Step 2: Sign dynamic libraries FIRST
echo "📚 Signing dynamic libraries..."
if [ -d "${APP_BUNDLE}/Contents/Resources/lib" ]; then
    find "${APP_BUNDLE}/Contents/Resources/lib" -name "*.dylib" -exec codesign --force --sign - {} \;
fi

# Step 3: Sign whisper-cli with entitlements
echo "🔧 Signing whisper-cli..."
codesign --force --sign - --options runtime --entitlements "swift/WhisperMac/Entitlements.plist" "${APP_BUNDLE}/Contents/Resources/bin/whisper-cli"

# Step 4: Sign the main executable
echo "🔧 Signing main executable..."
codesign --force --sign - --options runtime --entitlements "swift/WhisperMac/Entitlements.plist" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# Step 5: Sign the main bundle LAST
echo "🔐 Signing main bundle..."
codesign --force --sign - --options runtime --entitlements "swift/WhisperMac/Entitlements.plist" "${APP_BUNDLE}"

echo "✅ Build complete!"
echo "👉 App located at: ${APP_BUNDLE}"
echo "   You can move this to /Applications to install it."
