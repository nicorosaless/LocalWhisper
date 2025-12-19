#!/bin/bash

# Configuration
APP_NAME="Local Whisper"
EXECUTABLE_NAME="WhisperMac"
BUILD_DIR="swift/.build/release"
OUTPUT_DIR="build"
APP_BUNDLE="${OUTPUT_DIR}/${APP_NAME}.app"

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

# 3. Copy Executable (rename to match app name for consistency)
echo "📦 Copying executable..."
cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# 4. Copy Info.plist
echo "📝 Copying Info.plist..."
cp "swift/WhisperMac/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# 5. Copy Resources (whisper-cli)
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

# 6. Copy App Icon
echo "🎨 Copying App Icon..."
if [ -f "swift/WhisperMac/AppIcon.icns" ]; then
    cp "swift/WhisperMac/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/"
else
    echo "⚠️  AppIcon.icns not found!"
fi

# 7. Ad-hoc Code Signing (Fixed for distribution without Apple Developer Program)
echo "🔐 Signing app components..."

# Step 1: Remove existing signatures and quarantine attributes
echo "🧹 Removing existing signatures and quarantine attributes..."
xattr -cr "${APP_BUNDLE}"
find "${APP_BUNDLE}" -name "*.dylib" -exec codesign --remove-signature {} \; 2>/dev/null || true
codesign --remove-signature "${APP_BUNDLE}/Contents/Resources/bin/whisper-cli" 2>/dev/null || true
codesign --remove-signature "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" 2>/dev/null || true

# Step 2: Sign dynamic libraries FIRST (without hardened runtime for compatibility)
echo "📚 Signing dynamic libraries..."
if [ -d "${APP_BUNDLE}/Contents/Resources/lib" ]; then
    find "${APP_BUNDLE}/Contents/Resources/lib" -name "*.dylib" -exec codesign --force --sign - {} \;
fi

# Step 3: Sign whisper-cli with entitlements (disable library validation)
echo "🔧 Signing whisper-cli..."
codesign --force --sign - --options runtime --entitlements "swift/WhisperMac/Entitlements.plist" "${APP_BUNDLE}/Contents/Resources/bin/whisper-cli"

# Step 4: Sign the main executable
echo "🔧 Signing main executable..."
codesign --force --sign - --options runtime --entitlements "swift/WhisperMac/Entitlements.plist" "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}"

# Step 5: Sign the main bundle LAST (seals everything together)
echo "🔐 Signing main bundle..."
codesign --force --sign - --options runtime --entitlements "swift/WhisperMac/Entitlements.plist" "${APP_BUNDLE}"

echo "✅ Build complete!"
echo "👉 App located at: ${APP_BUNDLE}"
echo "   You can move this to /Applications to install it."
